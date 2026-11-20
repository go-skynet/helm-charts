{{/*
Pod-level fields shared by every LocalAI workload. (dict "root" $ "comp" .Values.frontend "gracePeriod" 60)
gracePeriod: terminationGracePeriodSeconds when the component doesn't set it (none: Kubernetes' 30s).
*/}}
{{- define "local-ai.podCommon" -}}
{{- $root := .root -}}
{{- with $root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "local-ai.serviceAccountName" $root }}
automountServiceAccountToken: {{ $root.Values.serviceAccount.automountServiceAccountToken }}
{{- with $root.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .comp.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- /* Lets the pause container reap child processes (LocalAI runs as PID 1; nvidia-smi needs a reaper). */}}
{{- if .comp.shareProcessNamespace }}
shareProcessNamespace: true
{{- end }}
{{- with .comp.runtimeClassName }}
runtimeClassName: {{ . }}
{{- end }}
{{- if .comp.hostNetwork }}
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
{{- end }}
{{- if hasKey .comp "terminationGracePeriodSeconds" }}
terminationGracePeriodSeconds: {{ .comp.terminationGracePeriodSeconds }}
{{- else if .gracePeriod }}
terminationGracePeriodSeconds: {{ .gracePeriod }}
{{- end }}
{{- with .comp.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .comp.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .comp.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .comp.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Pod template metadata. (dict "root" $ "comp" ... "component" "frontend" "annotations" dict) */}}
{{- define "local-ai.podMetadata" -}}
metadata:
  labels:
    {{- include "local-ai.selectorLabels" (dict "root" .root "component" .component) | nindent 4 }}
    {{- with .comp.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- $ann := merge (deepCopy (.annotations | default dict)) (deepCopy (.comp.podAnnotations | default dict)) }}
  {{- with $ann }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Probes of a component: its defaults (.defaults), each replaced whole by a non-empty probe set in
the component's values (.comp). An empty probe ({}) keeps the default. Returns YAML.
*/}}
{{- define "local-ai.resolveProbes" -}}
{{- $out := deepCopy (.defaults | default dict) -}}
{{- range $k := list "startupProbe" "readinessProbe" "livenessProbe" -}}
{{- with index $.comp $k }}{{ $_ := set $out $k . }}{{ end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/* Probes of a `local-ai run` server: frontend, chat worker, add-on owner. (dict "comp" ...) */}}
{{- define "local-ai.serverProbes" -}}
{{- $d := dict
      "startupProbe" (dict "httpGet" (dict "path" "/healthz" "port" "http") "periodSeconds" 10 "timeoutSeconds" 5 "failureThreshold" 360)
      "readinessProbe" (dict "httpGet" (dict "path" "/readyz" "port" "http") "periodSeconds" 10 "timeoutSeconds" 5 "failureThreshold" 3)
      "livenessProbe" (dict "httpGet" (dict "path" "/healthz" "port" "http") "periodSeconds" 30 "timeoutSeconds" 5 "failureThreshold" 5) -}}
{{- include "local-ai.resolveProbes" (dict "defaults" $d "comp" .comp) -}}
{{- end }}

{{/* Probes of the federated server and the explorer: TCP on the HTTP port. (dict "comp" ...) */}}
{{- define "local-ai.tcpProbes" -}}
{{- $d := dict
      "readinessProbe" (dict "tcpSocket" (dict "port" "http") "periodSeconds" 10)
      "livenessProbe" (dict "tcpSocket" (dict "port" "http") "periodSeconds" 30) -}}
{{- include "local-ai.resolveProbes" (dict "defaults" $d "comp" .comp) -}}
{{- end }}

{{/* Pod annotation that restarts the servers when the add-on host policy changes (subPath mounts never refresh). */}}
{{- define "local-ai.policyChecksum" -}}
{{- with .Values.addonHostPolicy.content }}
checksum/addon-host-policy: {{ sha256sum . | quote }}
{{- end }}
{{- end }}

{{- define "local-ai.probes" -}}
{{- with .startupProbe }}
startupProbe:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .readinessProbe }}
readinessProbe:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .livenessProbe }}
livenessProbe:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* ------------------------------------------------------------- frontend volumes */}}

{{/* Claim name of a frontend persistence volume. (dict "root" $ "name" "models") */}}
{{- define "local-ai.claimName" -}}
{{- $p := index .root.Values.persistence .name -}}
{{- $p.existingClaim | default (include "local-ai.componentName" (dict "root" .root "name" .name)) -}}
{{- end }}

{{/*
Volumes for the frontend persistence keys listed in .names. A key whose persistence is off (or
not in .shared) becomes an emptyDir. (dict "root" $ "names" (list ...) "shared" (list ...))
*/}}
{{- define "local-ai.frontendVolumes" -}}
{{- $root := .root -}}
{{- $shared := .shared | default list -}}
{{- range $name := .names }}
{{- $p := index $root.Values.persistence $name }}
- name: {{ $name }}
{{- if and $p.enabled (has $name $shared) }}
  persistentVolumeClaim:
    claimName: {{ include "local-ai.claimName" (dict "root" $root "name" $name) }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end }}
{{- end }}

{{/* Mount path map for the frontend persistence keys listed in .names. */}}
{{- define "local-ai.frontendPaths" -}}
{{- $root := .root -}}
{{- $paths := dict -}}
{{- range $name := .names -}}
{{- $_ := set $paths $name (index $root.Values.persistence $name).mountPath -}}
{{- end -}}
{{- toYaml $paths -}}
{{- end }}

{{- define "local-ai.mountsFromPaths" -}}
{{- range $name, $path := . }}
- name: {{ $name }}
  mountPath: {{ $path }}
{{- end }}
{{- end }}

{{/* ------------------------------------------------------------- files from Secrets/ConfigMaps */}}

{{/* Volumes for the credentials file, NATS TLS, host policy and carrier keys. (dict "root" $ "carrierRole" "frontend|owner|") */}}
{{- define "local-ai.fileVolumes" -}}
{{- $v := .root.Values -}}
{{- if $v.credentialsFile.existingSecret }}
- name: credentials
  secret:
    secretName: {{ $v.credentialsFile.existingSecret }}
{{- end }}
{{- if and (eq $v.mode "distributed") $v.distributed.nats.tls.existingSecret }}
- name: nats-tls
  secret:
    secretName: {{ $v.distributed.nats.tls.existingSecret }}
{{- end }}
{{- if $v.addonHostPolicy.content }}
- name: addon-host-policy
  configMap:
    name: {{ include "local-ai.componentName" (dict "root" .root "name" "addon-host-policy") }}
{{- end }}
{{- if .carrierRole }}
- name: carrier-src
  secret:
    secretName: {{ include "local-ai.carrierSecret" (dict "root" .root "role" .carrierRole) }}
- name: carrier
  emptyDir:
    medium: Memory
{{- end }}
{{- end }}

{{- define "local-ai.fileMounts" -}}
{{- $v := .root.Values -}}
{{- if $v.credentialsFile.existingSecret }}
- name: credentials
  mountPath: /etc/localai/credentials
  readOnly: true
{{- end }}
{{- if and (eq $v.mode "distributed") $v.distributed.nats.tls.existingSecret }}
- name: nats-tls
  mountPath: /etc/localai/nats-tls
  readOnly: true
{{- end }}
{{- if $v.addonHostPolicy.content }}
- name: addon-host-policy
  mountPath: /etc/localai/addons-custom/host-policy.json
  subPath: host-policy.json
  readOnly: true
{{- end }}
{{- if .carrierRole }}
- name: carrier
  mountPath: /run/localai/carrier
  readOnly: true
{{- end }}
{{- end }}

{{/*
LocalAI reads carrier keys only from files of mode 0600 that its user can open: Secret volumes
can't give that, so an init container (as the LocalAI user) copies them into a memory emptyDir.
Runs in the component's own image. (dict "root" $ "image" <component image>)
*/}}
{{- define "local-ai.carrierInit" -}}
- name: carrier-keys
  image: {{ include "local-ai.image" (dict "root" .root "image" .image) }}
  imagePullPolicy: {{ include "local-ai.imagePullPolicy" (dict "root" .root "image" .image) }}
  securityContext:
    {{- include "local-ai.helperSecurityContext" . | nindent 4 }}
  command:
    - sh
    - -c
    - |
      set -e
      cp /carrier-src/* /carrier/
      chmod 0600 /carrier/*
  volumeMounts:
    - name: carrier-src
      mountPath: /carrier-src
      readOnly: true
    - name: carrier
      mountPath: /carrier
{{- end }}

{{/* Security context of helper containers that run as the LocalAI user. */}}
{{- define "local-ai.helperSecurityContext" -}}
runAsUser: 10001
runAsGroup: 10001
runAsNonRoot: true
allowPrivilegeEscalation: false
seccompProfile:
  type: RuntimeDefault
capabilities:
  drop:
    - ALL
{{- end }}

{{/*
Waits until the services a component needs answer, so pods don't crash-loop while the release
starts. (dict "root" $ "image" <component image> "postgres" true "nats" true "frontend" true "owner" true)
postgres/nats: the built-in services (when enabled); frontend / owner: their /healthz.
Runs in the component's own LocalAI image (bash, curl), so no extra image is pulled.
*/}}
{{- define "local-ai.waitInit" -}}
{{- $v := .root.Values -}}
{{- $checks := list -}}
{{- if and .postgres $v.postgresql.enabled }}{{ $checks = append $checks (printf "wait_tcp %s 5432" (include "local-ai.postgresqlHost" .root | squote)) }}{{ end -}}
{{- if and .nats $v.nats.enabled }}{{ $checks = append $checks (printf "wait_tcp %s 4222" (include "local-ai.natsHost" .root | squote)) }}{{ end -}}
{{- if .frontend }}{{ $checks = append $checks (printf "wait_http %s" (printf "%s/healthz" (include "local-ai.registerUrl" .root) | squote)) }}{{ end -}}
{{- if .owner }}{{ $checks = append $checks (printf "wait_http %s" (printf "http://%s:8080/healthz" (include "local-ai.addonOwnerHost" .root) | squote)) }}{{ end -}}
{{- if $checks }}
- name: wait-for-dependencies
  image: {{ include "local-ai.image" (dict "root" .root "image" .image) }}
  imagePullPolicy: {{ include "local-ai.imagePullPolicy" (dict "root" .root "image" .image) }}
  securityContext:
    {{- include "local-ai.helperSecurityContext" . | nindent 4 }}
  command:
    - /bin/bash
    - -c
  args:
    - |
      wait_tcp() { until timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; do echo "waiting for $1:$2"; sleep 2; done; }
      wait_http() { until curl -fsS -o /dev/null --max-time 5 "$1"; do echo "waiting for $1"; sleep 3; done; }
      {{- range $checks }}
      {{ . }}
      {{- end }}
{{- end }}
{{- end }}

{{/*
Copies modelsConfigs and promptTemplates into the models directory, in the frontend's image.
(dict "root" $ "image" <component image> "modelsPath" "/models")
Root, like the image's entrypoint: it runs before the entrypoint hands the volume to the LocalAI
user, the volume may hold root-owned files (chart 3.x), and NFS ignores fsGroup. Each copied
file is given to the LocalAI user.
*/}}
{{- define "local-ai.modelFilesInit" -}}
{{- if or .root.Values.modelsConfigs .root.Values.promptTemplates }}
- name: model-files
  image: {{ include "local-ai.image" (dict "root" .root "image" .image) }}
  imagePullPolicy: {{ include "local-ai.imagePullPolicy" (dict "root" .root "image" .image) }}
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
  env:
    - name: MODELS_DIR
      value: {{ .modelsPath | quote }}
  command:
    - sh
    - -c
    - |
      set -e
      for f in /model-files/*; do
        t="$MODELS_DIR/$(basename "$f")"
        rm -f "$t"
        cp -L "$f" "$t"
        chown -h 10001:10001 "$t"
      done
  volumeMounts:
    - name: model-files
      mountPath: /model-files
      readOnly: true
    - name: models
      mountPath: {{ .modelsPath }}
{{- end }}
{{- end }}

{{/*
Volumes of a worker pod: the frontends' models claim (sharedModels), emptyDirs for volumes
without a claim, files, extras. (dict "root" $ "pool" $pool "sharedModels" bool "scratch" bool)
*/}}
{{- define "local-ai.workerVolumes" -}}
{{- range $name := .pool.volumes }}
{{- if and (eq $name "models") $.sharedModels }}
- name: models
  persistentVolumeClaim:
    claimName: {{ include "local-ai.claimName" (dict "root" $.root "name" "models") }}
{{- else if not (index $.pool.persistence $name).enabled }}
- name: {{ $name }}
  emptyDir: {}
{{- end }}
{{- end }}
{{- if .scratch }}
- name: staging
  emptyDir: {}
- name: cache
  emptyDir: {}
{{- end }}
{{- include "local-ai.fileVolumes" (dict "root" .root) }}
{{- with .pool.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}
