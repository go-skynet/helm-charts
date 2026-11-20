{{/*
Environment helpers. Each emits a list of EnvVar items (no leading indentation). Workloads join
them and pass the result through local-ai.env.dedupe.
*/}}

{{/*
One entry per variable name: its last occurrence, at that position. User settings (env, extraEnv)
come last, so they replace the chart's own value instead of adding a duplicate entry (which
server-side apply rejects), and a $(VAR) reference in them can use any variable defined before.
*/}}
{{- define "local-ai.env.dedupe" -}}
{{- $seen := dict -}}
{{- $out := list -}}
{{- range (. | fromYamlArray | reverse) -}}
{{- if not (hasKey $seen .name) -}}
{{- $_ := set $seen .name true -}}
{{- $out = prepend $out . -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{- define "local-ai.env.pod" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- end }}

{{/* Storage paths from a map of volume name -> mount path. */}}
{{- define "local-ai.env.paths" -}}
{{- $vars := dict "models" "LOCALAI_MODELS_PATH" "backends" "LOCALAI_BACKENDS_PATH" "data" "LOCALAI_DATA_PATH" "configuration" "LOCALAI_CONFIG_DIR" "generated" "LOCALAI_GENERATED_CONTENT_PATH" -}}
{{- range $name, $path := . }}
{{- if hasKey $vars $name }}
- name: {{ index $vars $name }}
  value: {{ $path | quote }}
{{- end }}
{{- if eq $name "data" }}
- name: LOCALAI_DOWNLOAD_STAGING_PATH
  value: {{ printf "%s/downloading" $path | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
User-supplied env, last so it wins over the chart's: the EnvVar lists (global, then component),
then the global + component env maps, so an env value can reference an extraEnv variable as $(NAME).
*/}}
{{- define "local-ai.env.user" -}}
{{- with .root.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- with .comp.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- $merged := merge (deepCopy (.comp.env | default dict)) (deepCopy (.root.Values.env | default dict)) -}}
{{- range $k, $v := $merged }}
{{- /* YAML numbers arrive as floats: print whole numbers as integers, not 1e+06. */}}
{{- if and (kindIs "float64" $v) (eq $v (floor $v)) }}{{ $v = int64 $v }}{{ end }}
- name: {{ $k }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end }}

{{- define "local-ai.envFrom" -}}
{{- $list := concat (.root.Values.envFrom | default list) (.comp.envFrom | default list) -}}
{{- with $list }}
envFrom:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Files LocalAI reads from Secrets, for every process that downloads models or backends. */}}
{{- define "local-ai.env.credentials" -}}
{{- if .Values.credentialsFile.existingSecret }}
- name: LOCALAI_CREDENTIALS_FILE
  value: /etc/localai/credentials/{{ .Values.credentialsFile.secretKey }}
{{- end }}
{{- end }}

{{/* PostgreSQL connection strings (account DB and collections DB). */}}
{{- define "local-ai.env.databases" -}}
{{- $pg := .Values.postgresql -}}
{{- $pgHost := include "local-ai.postgresqlHost" . -}}
{{- if $pg.enabled }}
- name: CHART_POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.postgresqlSecret" . }}
      key: {{ include "local-ai.postgresqlKey" . }}
{{- end }}
{{- with .Values.auth.database }}
{{- if .existingSecret }}
- name: LOCALAI_AUTH_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKey }}
{{- else if .url }}
- name: LOCALAI_AUTH_DATABASE_URL
  value: {{ .url | quote }}
{{- else if $pg.enabled }}
- name: LOCALAI_AUTH_DATABASE_URL
  value: {{ printf "postgresql://localai:$(CHART_POSTGRES_PASSWORD)@%s:5432/localai?sslmode=disable" $pgHost | quote }}
{{- end }}
{{- end }}
{{- $engine := include "local-ai.collectionsEngine" . }}
{{- if $engine }}
- name: LOCALAI_COLLECTIONS_VECTOR_ENGINE
  value: {{ $engine | quote }}
{{- end }}
{{- if eq $engine "postgres" }}
{{- with .Values.collections.database }}
{{- if .existingSecret }}
- name: LOCALAI_COLLECTIONS_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKey }}
{{- else if .url }}
- name: LOCALAI_COLLECTIONS_DATABASE_URL
  value: {{ .url | quote }}
{{- else if $pg.enabled }}
- name: LOCALAI_COLLECTIONS_DATABASE_URL
  value: {{ printf "postgresql://localai:$(CHART_POSTGRES_PASSWORD)@%s:5432/localai_collections?sslmode=disable" $pgHost | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Distributed-mode client settings shared by frontends, workers and agent workers:
NATS, the registration token and the auth requirement. (dict "root" $ "role" "...")
*/}}
{{- define "local-ai.env.distributedClient" -}}
{{- $d := .root.Values.distributed -}}
{{- if $d.nats.existingSecret }}
- name: LOCALAI_NATS_URL
  valueFrom:
    secretKeyRef:
      name: {{ $d.nats.existingSecret }}
      key: {{ $d.nats.secretKey }}
{{- else if $d.nats.url }}
- name: LOCALAI_NATS_URL
  value: {{ $d.nats.url | quote }}
{{- else }}
- name: CHART_NATS_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.natsSecret" .root }}
      key: {{ include "local-ai.natsKey" .root }}
- name: LOCALAI_NATS_URL
  value: {{ printf "nats://$(CHART_NATS_TOKEN)@%s:4222" (include "local-ai.natsHost" .root) | quote }}
{{- end }}
{{- /*
Servers (frontend, chat worker, add-on owner) mint per-node NATS credentials from the account
seed. Generic workers receive theirs from the frontend at registration and never read the service
credentials, so they don't get them (their backend processes would inherit them).
*/}}
{{- with $d.nats.auth.existingSecret }}
{{- if eq $.role "frontend" }}
- name: LOCALAI_NATS_ACCOUNT_SEED
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: account-seed
      optional: true
{{- end }}
{{- if ne $.role "worker" }}
- name: LOCALAI_NATS_SERVICE_JWT
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: service-jwt
      optional: true
- name: LOCALAI_NATS_SERVICE_SEED
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: service-seed
      optional: true
{{- end }}
{{- end }}
{{- if $d.nats.tls.existingSecret }}
- name: LOCALAI_NATS_TLS_CA
  value: /etc/localai/nats-tls/ca.crt
{{- if $d.nats.tls.clientAuth }}
- name: LOCALAI_NATS_TLS_CERT
  value: /etc/localai/nats-tls/tls.crt
- name: LOCALAI_NATS_TLS_KEY
  value: /etc/localai/nats-tls/tls.key
{{- end }}
{{- end }}
- name: LOCALAI_REGISTRATION_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.registrationTokenSecret" .root }}
      key: {{ include "local-ai.registrationTokenKey" .root }}
{{- /* The chart always sets a registration token, so the worker file-transfer server never fails open. */}}
{{- if ne .role "agent-worker" }}
- name: LOCALAI_REGISTRATION_REQUIRE_AUTH
  value: "true"
{{- end }}
{{- $natsAuth := ternary $d.nats.requireAuth (ne $d.nats.auth.existingSecret "") (kindIs "bool" $d.nats.requireAuth) }}
- name: LOCALAI_NATS_REQUIRE_AUTH
  value: {{ $natsAuth | quote }}
{{- end }}

{{/* S3 storage settings (frontends, chat workers, add-on owner, workers). */}}
{{- define "local-ai.env.storage" -}}
{{- with .Values.distributed.storage }}
{{- if .url }}
- name: LOCALAI_STORAGE_URL
  value: {{ .url | quote }}
- name: LOCALAI_STORAGE_BUCKET
  value: {{ .bucket | quote }}
- name: LOCALAI_STORAGE_REGION
  value: {{ .region | quote }}
{{- if .existingSecret }}
- name: LOCALAI_STORAGE_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .accessKeyKey }}
- name: LOCALAI_STORAGE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .secretKeyKey }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* The P2P network token of every P2P node. (dict "root" $ "name" "LOCALAI_P2P_TOKEN") */}}
{{- define "local-ai.env.p2pToken" }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.p2pTokenSecret" .root }}
      key: {{ include "local-ai.p2pTokenKey" .root }}
{{- end }}

{{/*
Settings of every `local-ai run` process: frontend, chat worker, add-on owner.
(dict "root" $ "role" "frontend|chat-worker|addon-owner")
*/}}
{{- define "local-ai.env.server" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $distributed := eq $v.mode "distributed" -}}
- name: LOCALAI_ADDRESS
  value: ":8080"
{{- /* A set instance ID keys a per-instance header cache file: only for the owner, whose pod name is
stable. Deployment pods would leave a new file on the shared data volume after every rollout. */}}
{{- if and $distributed (eq .role "addon-owner") }}
- name: LOCALAI_INSTANCE_ID
  value: $(POD_NAME)
{{- end }}
{{- if $v.apiKey.existingSecret }}
- name: LOCALAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $v.apiKey.existingSecret }}
      key: {{ $v.apiKey.secretKey }}
{{- end }}
{{- if include "local-ai.authEnabled" $root }}
- name: LOCALAI_AUTH
  value: "true"
{{- /* Signs sessions and API keys: every server must use the same one. */}}
- name: LOCALAI_AUTH_HMAC_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.hmacSecret" $root }}
      key: {{ include "local-ai.hmacSecretKey" $root }}
{{- end }}
{{- include "local-ai.env.databases" $root }}
{{- with $v.auth.registrationMode }}
- name: LOCALAI_REGISTRATION_MODE
  value: {{ . | quote }}
{{- end }}
{{- with $v.auth.adminEmail }}
- name: LOCALAI_ADMIN_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- if $v.auth.disableLocalAuth }}
- name: LOCALAI_DISABLE_LOCAL_AUTH
  value: "true"
{{- end }}
{{- with $v.auth.baseUrl }}
- name: LOCALAI_BASE_URL
  value: {{ . | quote }}
{{- end }}
{{- with $v.auth.oidc }}
{{- if .clientId }}
- name: LOCALAI_OIDC_ISSUER
  value: {{ .issuer | quote }}
- name: LOCALAI_OIDC_CLIENT_ID
  value: {{ .clientId | quote }}
{{- if .existingSecret }}
- name: LOCALAI_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .clientSecretKey }}
{{- end }}
{{- end }}
{{- end }}
{{- with $v.auth.github }}
{{- if .clientId }}
- name: GITHUB_CLIENT_ID
  value: {{ .clientId | quote }}
{{- if .existingSecret }}
- name: GITHUB_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: {{ .clientSecretKey }}
{{- end }}
{{- end }}
{{- end }}
{{- if $v.hfToken.existingSecret }}
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $v.hfToken.existingSecret }}
      key: {{ $v.hfToken.secretKey }}
{{- end }}
{{- include "local-ai.env.credentials" $root }}
{{- if $v.addonHostPolicy.content }}
- name: LOCALAI_ADDON_HOST_POLICY
  value: /etc/localai/addons-custom/host-policy.json
{{- end }}
{{- if $distributed }}
- name: LOCALAI_DISTRIBUTED
  value: "true"
{{- include "local-ai.env.distributedClient" (dict "root" $root "role" "frontend") }}
- name: LOCALAI_AUTO_APPROVE_NODES
  value: {{ $v.distributed.autoApproveNodes | quote }}
{{- if $v.distributed.sharedModels }}
- name: LOCALAI_DISTRIBUTED_SHARED_MODELS
  value: "true"
{{- end }}
{{- include "local-ai.env.storage" $root }}
{{- if and $v.chatWorker.enabled (eq .role "frontend") }}
- name: LOCALAI_DISTRIBUTED_CHAT_WORKERS
  value: "true"
{{- end }}
{{- if eq .role "chat-worker" }}
- name: LOCALAI_CHAT_WORKER
  value: "true"
{{- end }}
{{- if $v.addonOwner.enabled }}
- name: LOCALAI_ADDONS_ROLE
  value: {{ ternary "owner" "frontend" (eq .role "addon-owner") }}
- name: LOCALAI_ADDONS_OWNER_ADDRESS
  value: {{ include "local-ai.addonOwnerAddress" $root | quote }}
- name: LOCALAI_ADDONS_CARRIER_DIR
  value: /run/localai/carrier
{{- else if or (eq .role "chat-worker") (gt (int $v.frontend.replicaCount) 1) }}
{{/* Several processes would each be their own add-on owner: turn add-ons off instead. */}}
- name: LOCALAI_ADDONS_ENABLED
  value: "false"
{{- end }}
{{- end }}
{{- if eq $v.mode "p2p" }}
- name: LOCALAI_P2P
  value: "true"
{{- include "local-ai.env.p2pToken" (dict "root" $root "name" "LOCALAI_P2P_TOKEN") }}
{{- if $v.p2p.federated }}
- name: LOCALAI_FEDERATED
  value: "true"
{{- end }}
{{- end }}
{{- if eq .role "frontend" }}
{{- with include "local-ai.llamaCppRpcServers" $root }}
- name: LLAMACPP_GRPC_SERVERS
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}


{{/*
Settings of a worker pool. (dict "root" $ "pool" $pool "paths" (dict name -> mount path))
*/}}
{{- define "local-ai.env.workerPool" -}}
{{- $root := .root -}}
{{- $pool := .pool -}}
{{- $grpc := int $pool.grpcPort -}}
{{- $svcDomain := printf "%s.%s.svc.%s" $pool.fullname $root.Release.Namespace $root.Values.clusterDomain -}}
{{- include "local-ai.env.pod" $root }}
{{- /* Workers read only the models and backends paths (data, staging and cache sit next to models). */}}
{{- include "local-ai.env.paths" (pick .paths "models" "backends") }}
{{- include "local-ai.env.credentials" $root }}
{{- if eq $pool.type "generic" }}
{{- /* Backend downloads go through the OS temp dir: keep them on the data volume, not the node's disk. */}}
- name: TMPDIR
  value: {{ .paths.data | quote }}
- name: LOCALAI_SERVE_ADDR
  value: {{ printf "0.0.0.0:%d" $grpc | quote }}
- name: LOCALAI_GRPC_MAX_PORT
  value: {{ $pool.grpcMaxPort | quote }}
- name: LOCALAI_ADVERTISE_ADDR
  value: {{ printf "$(POD_NAME).%s:%d" $svcDomain $grpc | quote }}
- name: LOCALAI_ADVERTISE_HTTP_ADDR
  value: {{ printf "$(POD_NAME).%s:%d" $svcDomain (sub $grpc 1) | quote }}
- name: LOCALAI_NODE_NAME
  value: $(POD_NAME)
- name: LOCALAI_REGISTER_TO
  value: {{ include "local-ai.registerUrl" $root | quote }}
{{- include "local-ai.env.distributedClient" (dict "root" $root "role" "worker") }}
{{- include "local-ai.env.storage" $root }}
{{- with include "local-ai.llamaCppRpcServers" $root }}
- name: LLAMACPP_GRPC_SERVERS
  value: {{ . | quote }}
{{- end }}
{{- else if eq $pool.type "p2p-llama-cpp-rpc" }}
{{- /* Same name as the other P2P nodes, so a user override of the token reaches the workers too. */}}
{{- include "local-ai.env.p2pToken" (dict "root" $root "name" "LOCALAI_P2P_TOKEN") }}
{{- else if eq $pool.type "vllm" }}
{{- /* vllm serve downloads the model itself; keep the cache on the models volume. */}}
- name: HF_HOME
  value: {{ printf "%s/huggingface" .paths.models | quote }}
{{- if $root.Values.hfToken.existingSecret }}
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $root.Values.hfToken.existingSecret }}
      key: {{ $root.Values.hfToken.secretKey }}
{{- end }}
{{- if eq $root.Values.mode "distributed" }}
- name: LOCALAI_REGISTER_TO
  value: {{ include "local-ai.registerUrl" $root | quote }}
- name: LOCALAI_NODE_NAME
  value: $(POD_NAME)
- name: LOCALAI_REGISTRATION_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ include "local-ai.registrationTokenSecret" $root }}
      key: {{ include "local-ai.registrationTokenKey" $root }}
{{- end }}
{{- end }}
{{- include "local-ai.env.user" (dict "root" $root "comp" $pool) }}
{{- end }}
