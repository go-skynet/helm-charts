{{- define "local-ai.sidecars" }}
{{- range .Values.sidecarContainers }}
# Sidecar container from values.yaml
- name: {{ .name }}
  image: {{ .image }}
  imagePullPolicy: {{ .imagePullPolicy }}
  {{- if .command }}
  command:
    {{- toYaml .command | nindent 12 }}
  {{- end }}
  {{- if .args }}
  args:
    {{- toYaml .args | nindent 12 }}
  {{- end }}
  {{- if .env }}
  env:
    {{- toYaml .env | nindent 12 }}
  {{- end }}
  {{- if .ports }}
  ports:
    {{- toYaml .ports | nindent 12 }}
  {{- end }}
  {{- if .resources }}
  resources:
    {{- toYaml .resources | nindent 12 }}
  {{- end }}
  {{- if or .volumeMounts .Values.persistence }}
  volumeMounts:
  {{- if .volumeMounts }}
    {{- toYaml .volumeMounts | nindent 12 }}
  {{- end }}
  {{- range $key, $pvc := .Values.persistence }}
  {{- if $pvc.enabled }}
    - name: {{ $key }}
      mountPath: {{ $pvc.globalMount | default (print "/" $key) }}
  {{- end }}
  {{- end }}
  {{- end }}
  {{- if .livenessProbe }}
  livenessProbe:
    {{- toYaml .livenessProbe | nindent 12 }}
  {{- end }}
  {{- if .readinessProbe }}
  readinessProbe:
    {{- toYaml .readinessProbe | nindent 12 }}
  {{- end }}
  {{- if .securityContext }}
  securityContext:
    {{- toYaml .securityContext | nindent 12 }}
  {{- end }}
{{- end }}
{{ if .Values.enableModelSyncronizationSidecar }}
# Built in sidecar for model syncronization
- name: model-loader
  image: quay.io/kiwigrid/k8s-sidecar:1.26.1
  imagePullPolicy: IfNotPresent
  env:
    - name: LABEL
      value: io.localai/model_source
    - name: LABEL_VALUE
      value: "1"
    - name: METHOD
      value: WATCH
    - name: FOLDER
      value: {{ .Values.deployment.modelsPath }}
    - name: FOLDER_ANNOTATION
      value: "io.localai/target-directory"
  securityContext:
    runAsGroup: 1000
  volumeMounts:
    - mountPath: {{ .Values.deployment.modelsPath }}
      name: models
{{- end }}
{{- end }}