{{/* ---------------------------------------------------------------- names and labels */}}

{{- define "local-ai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "local-ai.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Name of a component resource: <fullname>-<suffix>. Lengths are checked in local-ai.validateNames. */}}
{{- define "local-ai.componentName" -}}
{{- printf "%s-%s" (include "local-ai.fullname" .root) .name }}
{{- end }}

{{- define "local-ai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Selector labels. Call with (dict "root" $ "component" "frontend"). */}}
{{- define "local-ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "local-ai.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* commonLabels may replace the chart's labels, except the selector labels. */}}
{{- define "local-ai.labels" -}}
{{- $l := dict "helm.sh/chart" (include "local-ai.chart" .root) "app.kubernetes.io/version" .root.Chart.AppVersion "app.kubernetes.io/managed-by" .root.Release.Service "app.kubernetes.io/part-of" "local-ai" -}}
{{- $l = mergeOverwrite $l (deepCopy (.root.Values.commonLabels | default dict)) -}}
{{- $l = mergeOverwrite $l (include "local-ai.selectorLabels" . | fromYaml) -}}
{{- toYaml $l -}}
{{- end }}

{{/* Labels shared by every pod of the release (used by network policies). */}}
{{- define "local-ai.releaseSelector" -}}
app.kubernetes.io/name: {{ include "local-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
metadata.annotations of a top-level resource: commonAnnotations merged with its own (dict "root" $
"extra" map; its keys win). Renders the whole indented `annotations:` key on a new line, or nothing:
call it right after metadata's labels as {{- include "local-ai.metaAnnotations" (dict "root" $) }}.
*/}}
{{- define "local-ai.metaAnnotations" -}}
{{- $a := mergeOverwrite (deepCopy (.root.Values.commonAnnotations | default dict)) (deepCopy (.extra | default dict)) -}}
{{- with $a }}
  annotations:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end }}

{{- define "local-ai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "local-ai.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------- images */}}

{{/*
LocalAI image of a component: (dict "root" $ "image" .Values.frontend.image).
repository, tag and variant each fall back to the global image; an explicit empty variant picks the
CPU image. The global digest pins the global image, so only a component without an image of its own
(nothing but pullPolicy) inherits it; the others use their own digest, if any.
*/}}
{{- define "local-ai.image" -}}
{{- $g := .root.Values.image -}}
{{- $o := .image | default dict -}}
{{- $repo := $o.repository | default $g.repository -}}
{{- $tag := $o.tag | default $g.tag | default .root.Chart.AppVersion -}}
{{- $variant := ternary $o.variant $g.variant (hasKey $o "variant") -}}
{{- $digest := $o.digest | default (ternary $g.digest "" (empty (omit $o "pullPolicy"))) -}}
{{- printf "%s:%s" $repo $tag }}{{ with $variant }}-{{ . }}{{ end }}{{ with $digest }}@{{ . }}{{ end -}}
{{- end }}

{{/* repository:tag[@digest] of a plain image block. */}}
{{- define "local-ai.plainImage" -}}
{{- printf "%s:%s%s" .repository .tag (ternary (printf "@%s" (.digest | default "")) "" (ne (.digest | default "") "")) -}}
{{- end }}

{{- define "local-ai.imagePullPolicy" -}}
{{- (.image | default dict).pullPolicy | default .root.Values.image.pullPolicy -}}
{{- end }}

{{/* Security context of a LocalAI container: the component's over the global one. (dict "root" $ "comp" $comp) */}}
{{- define "local-ai.securityContext" -}}
{{- with (merge (deepCopy (.comp.securityContext | default dict)) (deepCopy (.root.Values.securityContext | default dict))) }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------- modes */}}

{{- define "local-ai.authEnabled" -}}
{{- if or .Values.auth.enabled (eq .Values.mode "distributed") .Values.auth.oidc.clientId .Values.auth.github.clientId }}true{{ end -}}
{{- end }}

{{/* ---------------------------------------------------------------- secrets and endpoints */}}

{{- define "local-ai.frontendUrl" -}}
{{- printf "http://%s.%s.svc.%s:%v" (include "local-ai.fullname" .) .Release.Namespace .Values.clusterDomain .Values.service.port -}}
{{- end }}

{{/*
URL workers register to: a Service that also routes to frontends that are not ready yet. A
distributed frontend reports not ready until a worker is healthy (it waits for one before
starting collections), so registering through the user-facing Service would deadlock.
*/}}
{{- define "local-ai.registerUrl" -}}
{{- printf "http://%s.%s.svc.%s:8080" (include "local-ai.componentName" (dict "root" . "name" "nodes")) .Release.Namespace .Values.clusterDomain -}}
{{- end }}

{{- define "local-ai.registrationTokenSecret" -}}
{{- .Values.distributed.registrationToken.existingSecret | default (include "local-ai.componentName" (dict "root" . "name" "registration")) -}}
{{- end }}
{{- define "local-ai.registrationTokenKey" -}}
{{- ternary .Values.distributed.registrationToken.secretKey "token" (ne .Values.distributed.registrationToken.existingSecret "") -}}
{{- end }}

{{- define "local-ai.p2pTokenSecret" -}}
{{- .Values.p2p.token.existingSecret | default (include "local-ai.componentName" (dict "root" . "name" "p2p")) -}}
{{- end }}
{{- define "local-ai.p2pTokenKey" -}}
{{- ternary .Values.p2p.token.secretKey "token" (ne .Values.p2p.token.existingSecret "") -}}
{{- end }}

{{- define "local-ai.hmacSecret" -}}
{{- .Values.auth.hmacSecret.existingSecret | default (include "local-ai.componentName" (dict "root" . "name" "auth")) -}}
{{- end }}
{{- define "local-ai.hmacSecretKey" -}}
{{- ternary .Values.auth.hmacSecret.secretKey "hmac-secret" (ne .Values.auth.hmacSecret.existingSecret "") -}}
{{- end }}

{{- define "local-ai.postgresqlHost" -}}
{{- include "local-ai.componentName" (dict "root" . "name" "postgresql") -}}
{{- end }}
{{- define "local-ai.postgresqlSecret" -}}
{{- .Values.postgresql.existingSecret | default (include "local-ai.postgresqlHost" .) -}}
{{- end }}
{{- define "local-ai.postgresqlKey" -}}
{{- ternary .Values.postgresql.secretKey "password" (ne .Values.postgresql.existingSecret "") -}}
{{- end }}

{{- define "local-ai.natsHost" -}}
{{- include "local-ai.componentName" (dict "root" . "name" "nats") -}}
{{- end }}
{{- define "local-ai.natsSecret" -}}
{{- .Values.nats.existingSecret | default (include "local-ai.natsHost" .) -}}
{{- end }}
{{- define "local-ai.natsKey" -}}
{{- ternary .Values.nats.secretKey "token" (ne .Values.nats.existingSecret "") -}}
{{- end }}

{{/* "true" when the frontend has an API key or user accounts (also when set through env/extraEnv). */}}
{{- define "local-ai.apiProtected" -}}
{{- $v := .Values -}}
{{- $names := concat (keys ($v.env | default dict)) (keys ($v.frontend.env | default dict)) -}}
{{- range concat ($v.extraEnv | default list) ($v.frontend.extraEnv | default list) }}{{ $names = append $names .name }}{{ end -}}
{{- if or $v.apiKey.existingSecret (include "local-ai.authEnabled" .) (has "LOCALAI_API_KEY" $names) (has "API_KEY" $names) (has "LOCALAI_AUTH" $names) }}true{{ end -}}
{{- end }}

{{- define "local-ai.hasAuthDatabase" -}}
{{- if or .Values.auth.database.url .Values.auth.database.existingSecret .Values.postgresql.enabled }}true{{ end -}}
{{- end }}

{{- define "local-ai.hasCollectionsDatabase" -}}
{{- if or .Values.collections.database.url .Values.collections.database.existingSecret .Values.postgresql.enabled }}true{{ end -}}
{{- end }}

{{- define "local-ai.hasNats" -}}
{{- if or .Values.distributed.nats.url .Values.distributed.nats.existingSecret .Values.nats.enabled }}true{{ end -}}
{{- end }}

{{/* Collections engine: the explicit setting, or postgres when a collections database is set. */}}
{{- define "local-ai.collectionsEngine" -}}
{{- .Values.collections.vectorEngine | default (ternary "postgres" "" (eq (include "local-ai.hasCollectionsDatabase" .) "true")) -}}
{{- end }}

{{/* ---------------------------------------------------------------- add-on owner */}}

{{- define "local-ai.addonOwnerName" -}}
{{- include "local-ai.componentName" (dict "root" . "name" "addon-owner") -}}
{{- end }}

{{- define "local-ai.addonOwnerHost" -}}
{{- printf "%s.%s.svc.%s" (include "local-ai.addonOwnerName" .) .Release.Namespace .Values.clusterDomain -}}
{{- end }}

{{- define "local-ai.addonOwnerAddress" -}}
{{- printf "https://%s:8443" (include "local-ai.addonOwnerHost" .) -}}
{{- end }}

{{- define "local-ai.carrierSecret" -}}
{{- $key := printf "%sSecret" .role -}}
{{- index .root.Values.addonOwner.carrierKeys $key | default (include "local-ai.componentName" (dict "root" .root "name" (printf "carrier-%s" .role))) -}}
{{- end }}

{{/* ---------------------------------------------------------------- worker pools */}}

{{/* Worker pools merged with workerDefaults, as a list (returned as YAML). */}}
{{- define "local-ai.workerPools" -}}
{{- $pools := list -}}
{{- range .Values.workers -}}
{{- $pool := mergeOverwrite (deepCopy $.Values.workerDefaults) (deepCopy .) -}}
{{- $_ := set $pool "type" ($pool.type | default "generic") -}}
{{- $_ := set $pool "fullname" (include "local-ai.componentName" (dict "root" $ "name" (printf "worker-%s" $pool.name))) -}}
{{- /* Volumes each worker type uses: rpc servers only need backends; vllm and ds4 also read model files. */}}
{{- $vols := dict "generic" (list "models" "backends" "data") "llama-cpp-rpc" (list "backends") "p2p-llama-cpp-rpc" (list "backends") "vllm" (list "models" "backends") "ds4-distributed" (list "models" "backends") -}}
{{- $_ := set $pool "volumes" (index $vols $pool.type | default (list "backends")) -}}
{{- $pools = append $pools $pool -}}
{{- end -}}
{{- toYaml (dict "pools" $pools) -}}
{{- end }}

{{/* LLAMACPP_GRPC_SERVERS value built from every llama-cpp-rpc pool. */}}
{{- define "local-ai.llamaCppRpcServers" -}}
{{- $servers := list -}}
{{- range (include "local-ai.workerPools" . | fromYaml).pools -}}
{{- if eq .type "llama-cpp-rpc" -}}
{{- $pool := . -}}
{{- range $i := until (int $pool.replicaCount) -}}
{{- $servers = append $servers (printf "%s-%d.%s.%s.svc.%s:%v" $pool.fullname $i $pool.fullname $.Release.Namespace $.Values.clusterDomain $pool.rpcPort) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join "," $servers -}}
{{- end }}

{{/* ---------------------------------------------------------------- validation */}}

{{- define "local-ai.validate" -}}
{{- $v := .Values -}}
{{- include "local-ai.validateLegacy" . -}}
{{- if not (has $v.mode (list "standalone" "distributed" "p2p")) -}}
{{- fail (printf "mode must be standalone, distributed or p2p (got %q)" $v.mode) -}}
{{- end -}}
{{- if and (ne $v.mode "distributed") (gt (int $v.frontend.replicaCount) 1) -}}
{{- fail (printf "%s mode keeps state in local files and runs exactly one frontend: use mode=distributed to scale" $v.mode) -}}
{{- end -}}
{{- with $v.frontend.strategy -}}
{{- if and .rollingUpdate (ne (toString .type) "RollingUpdate") -}}
{{- fail "frontend.strategy.rollingUpdate needs frontend.strategy.type=RollingUpdate (the default type, Recreate, takes no rollingUpdate parameters)" -}}
{{- end -}}
{{- end -}}
{{- include "local-ai.validateNames" . -}}
{{- if and (not $v.allowUnauthenticated) (not (include "local-ai.apiProtected" .)) -}}
{{- if and (eq $v.mode "p2p") $v.p2p.federated -}}
{{- fail "p2p.federated publishes the API to every holder of the P2P token, and without an API key or user accounts every client is an administrator (which includes running code in the pod): set apiKey.existingSecret or auth.enabled=true, or allowUnauthenticated=true" -}}
{{- end -}}
{{- if $v.frontend.hostNetwork -}}
{{- fail "frontend.hostNetwork serves the API on every address of its node, and without an API key or user accounts every client is an administrator (which includes running code in the pod): set apiKey.existingSecret or auth.enabled=true, or allowUnauthenticated=true" -}}
{{- end -}}
{{- end -}}
{{- /*
With a PostgreSQL account database and Files on the filesystem, LocalAI checks at every start that
<data>/chats/blobs is the folder the database knows: an emptyDir is a new folder after each restart.
*/}}
{{- $pgAuth := or $v.postgresql.enabled $v.auth.database.existingSecret (hasPrefix "postgres" $v.auth.database.url) -}}
{{- $s3 := and (eq $v.mode "distributed") $v.distributed.storage.url -}}
{{- if and $pgAuth (not $s3) (not $v.persistence.data.enabled) -}}
{{- fail (printf "with a PostgreSQL account database, chat Files live in the data volume and LocalAI checks on every start that it is the one the database knows: enable persistence.data (an emptyDir is new after each restart)%s" (ternary ", or use S3 (distributed.storage)" "" (eq $v.mode "distributed"))) -}}
{{- end -}}
{{- $engine := include "local-ai.collectionsEngine" . -}}
{{- if and (eq $engine "postgres") (not (include "local-ai.hasCollectionsDatabase" .)) -}}
{{- fail "collections.vectorEngine=postgres needs collections.database.url / existingSecret, or postgresql.enabled=true" -}}
{{- end -}}
{{- if eq $v.mode "distributed" -}}
{{- if not (include "local-ai.hasAuthDatabase" .) -}}
{{- fail "distributed mode needs PostgreSQL: set auth.database.url / auth.database.existingSecret, or postgresql.enabled=true" -}}
{{- end -}}
{{- if not (include "local-ai.hasNats" .) -}}
{{- fail "distributed mode needs NATS: set distributed.nats.url / distributed.nats.existingSecret, or nats.enabled=true" -}}
{{- end -}}
{{- if and $v.nats.enabled (not $v.distributed.nats.url) (not $v.distributed.nats.existingSecret) -}}
{{- if $v.distributed.nats.tls.existingSecret -}}
{{- fail "distributed.nats.tls is for an external NATS server: the built-in one (nats.enabled) has no TLS, and LocalAI forces TLS once TLS files are set. Set distributed.nats.url to your server, or remove distributed.nats.tls.existingSecret" -}}
{{- end -}}
{{- if $v.distributed.nats.auth.existingSecret -}}
{{- fail "distributed.nats.auth is for an external NATS server with JWT auth: the built-in one (nats.enabled) has none. Set distributed.nats.url to your server, or remove distributed.nats.auth.existingSecret" -}}
{{- end -}}
{{- end -}}
{{- if and (or (gt (int $v.frontend.replicaCount) 1) $v.chatWorker.enabled) (ne $engine "postgres") -}}
{{- fail "several LocalAI servers (frontends, chat workers) need the postgres collections engine: set collections.database.url / existingSecret, or postgresql.enabled=true" -}}
{{- end -}}
{{- if $v.distributed.sharedModels -}}
{{- $m := $v.persistence.models -}}
{{- if not (and $m.enabled (or $m.existingClaim (has "ReadWriteMany" $m.accessModes))) -}}
{{- fail "distributed.sharedModels mounts the frontends' models volume on every generic worker: it needs persistence.models with ReadWriteMany storage or an existingClaim" -}}
{{- end -}}
{{- end -}}
{{- if $v.addonOwner.enabled -}}
{{- $ck := $v.addonOwner.carrierKeys -}}
{{- if and (or $ck.ownerSecret $ck.frontendSecret) (not (and $ck.ownerSecret $ck.frontendSecret)) -}}
{{- fail "addonOwner.carrierKeys: set both ownerSecret and frontendSecret (one key set), or neither to have them generated" -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- range $c := list "chatWorker" "agentWorker" "addonOwner" -}}
{{- if (index $v $c).enabled -}}
{{- fail (printf "%s.enabled needs mode=distributed" $c) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (ne $v.mode "p2p") (or $v.federatedServer.enabled $v.explorer.enabled) -}}
{{- fail "federatedServer and explorer need mode=p2p" -}}
{{- end -}}
{{- $names := dict -}}
{{- range $v.workers -}}
{{- if not .name -}}{{- fail "every worker pool needs a name" -}}{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .name) -}}
{{- fail (printf "worker pool name %q must be a DNS label" .name) -}}
{{- end -}}
{{- if hasKey $names .name -}}{{- fail (printf "worker pool name %q is used twice" .name) -}}{{- end -}}
{{- $_ := set $names .name true -}}
{{- $type := .type | default "generic" -}}
{{- if not (has $type (list "generic" "llama-cpp-rpc" "p2p-llama-cpp-rpc" "vllm" "ds4-distributed")) -}}
{{- fail (printf "worker pool %q: unknown type %q" .name $type) -}}
{{- end -}}
{{- if and (eq $type "generic") (ne $v.mode "distributed") -}}
{{- fail (printf "worker pool %q: type generic needs mode=distributed" .name) -}}
{{- end -}}
{{- if and (eq $type "p2p-llama-cpp-rpc") (ne $v.mode "p2p") -}}
{{- fail (printf "worker pool %q: type p2p-llama-cpp-rpc needs mode=p2p" .name) -}}
{{- end -}}
{{- end -}}
{{- $types := list -}}
{{- range (include "local-ai.workerPools" . | fromYaml).pools -}}
{{- $types = append $types .type -}}
{{- if and (eq .type "vllm") (gt (int .replicaCount) 1) -}}
{{- fail (printf "worker pool %q: every vLLM follower needs its own VLLM_DATA_PARALLEL_START_RANK, so use one pool (replicaCount: 1) per rank" .name) -}}
{{- end -}}
{{- if and (eq .type "generic") .grpcMaxPort (lt (int .grpcMaxPort) (int .grpcPort)) -}}
{{- fail (printf "worker pool %q: grpcMaxPort (%v) is below grpcPort (%v); LocalAI would then use every port up to 65535" .name .grpcMaxPort .grpcPort) -}}
{{- end -}}
{{- end -}}
{{- if and (eq $v.mode "p2p") (has "llama-cpp-rpc" $types) (has "p2p-llama-cpp-rpc" $types) -}}
{{- fail "p2p mode: llama-cpp-rpc and p2p-llama-cpp-rpc pools can't be mixed (P2P discovery replaces the static LLAMACPP_GRPC_SERVERS list): use one kind" -}}
{{- end -}}
{{- end }}

{{/*
Names that must be DNS labels fit Kubernetes limits: 63 characters for Services and Jobs (the
job-name label), and 52 for StatefulSets (their pods get a controller-revision-hash label of the
name plus 11 characters). Other resources (Deployments, Secrets, ConfigMaps, claims) allow 253.
Names are never truncated, so two resources can't end up with the same name.
*/}}
{{- define "local-ai.validateNames" -}}
{{- $v := .Values -}}
{{- $full := include "local-ai.fullname" . -}}
{{- $names := dict "" 63 -}}
{{- if eq $v.mode "distributed" }}{{ $_ := set $names "nodes" 63 }}{{ end -}}
{{- if $v.postgresql.enabled }}{{ $_ := set $names "postgresql" 52 }}{{ end -}}
{{- if $v.nats.enabled }}{{ $_ := set $names "nats" 52 }}{{ end -}}
{{- if $v.addonOwner.enabled }}{{ $_ := set $names "carrier-keys" 63 }}{{ $_ := set $names "addon-owner" 52 }}{{ end -}}
{{- if $v.federatedServer.enabled }}{{ $_ := set $names "federated" 63 }}{{ end -}}
{{- if $v.explorer.enabled }}{{ $_ := set $names "explorer" 63 }}{{ end -}}
{{- range $v.workers }}{{ $_ := set $names (printf "worker-%s" .name) 52 }}{{ end -}}
{{- range $suffix, $max := $names -}}
{{- $n := ternary $full (printf "%s-%s" $full $suffix) (eq $suffix "") -}}
{{- if gt (len $n) (int $max) -}}
{{- fail (printf "resource name %q has %d characters, over the Kubernetes limit of %d: shorten the release name, set fullnameOverride%s" $n (len $n) (int $max) (ternary " or shorten the worker pool name" "" (hasPrefix "worker-" $suffix))) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Values of chart 3.x that 4.0 replaced. The schema accepts them only so this can say what to do.
*/}}
{{- define "local-ai.validateLegacy" -}}
{{- $v := .Values -}}
{{- $found := list -}}
{{- $moved := dict "replicaCount" "frontend.replicaCount" "deployment" "image / env / frontend.*" "resources" "frontend.resources" "initContainers" "frontend.initContainers" "sidecarContainers" "frontend.sidecars" "nodeSelector" "frontend.nodeSelector" "tolerations" "frontend.tolerations" "affinity" "frontend.affinity" -}}
{{- range $k := keys $moved | sortAlpha -}}
{{- if hasKey $v $k }}{{ $found = append $found (printf "%s -> %s" $k (index $moved $k)) }}{{ end -}}
{{- end -}}
{{- if hasKey $v.persistence "output" }}{{ $found = append $found "persistence.output -> persistence.generated" }}{{ end -}}
{{- range $n, $p := $v.persistence -}}
{{- if and (kindIs "map" $p) (hasKey $p "globalMount") }}{{ $found = append $found (printf "persistence.%s.globalMount -> persistence.%s.mountPath" $n $n) }}{{ end -}}
{{- end -}}
{{- if $found -}}
{{- fail (printf "these chart 3.x values were replaced in chart 4.0: %s. See \"Upgrading from 3.x\" in the chart README (start from the 4.x values; don't use --reuse-values)" (join ", " $found)) -}}
{{- end -}}
{{- end }}
