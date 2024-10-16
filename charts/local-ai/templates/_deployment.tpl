{{- define "local-ai.deployment" -}}
{{- $rootContext := .rootContext -}}
{{- $deploymentObject := .object -}}
{{- $componentPersistence := get $rootContext.Values.persistence $deploymentObject.component -}}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "local-ai.name" $rootContext }}-{{ $deploymentObject.component}}
  namespace: {{ $rootContext.Release.Namespace | quote }}
  labels:
    {{- include "local-ai.labels" $rootContext | nindent 4 }}
    app.kubernetes.io/component: {{ $deploymentObject.component }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "local-ai.name" $rootContext }}
      app.kubernetes.io/instance: {{ $rootContext.Release.Name }}
      app.kubernetes.io/component: {{ $deploymentObject.component }}
  replicas: {{ $deploymentObject.replicaCount }}
  template:
    metadata:
      name: {{ $deploymentObject.name }}
      labels:
        app.kubernetes.io/name: {{ include "local-ai.name" $rootContext }}
        app.kubernetes.io/instance: {{ $rootContext.Release.Name }}
        app.kubernetes.io/component: {{ $deploymentObject.component }}
      annotations:
        {{- if $rootContext.Values.promptTemplates }}
        checksum/config-prompt-templates: {{ include (print $rootContext.Template.BasePath "/configmap-prompt-templates.yaml") $rootContext | sha256sum }}
        {{- end }}
    spec:
      {{- with $rootContext.Values.deployment.runtimeClassName }}
      runtimeClassName: {{ . }}
      {{- end }}
      {{- with $rootContext.Values.deployment.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if or $rootContext.Values.initContainers $rootContext.Values.promptTemplates $rootContext.Values.modelsConfigs }}
      initContainers:
        {{- with $rootContext.Values.initContainers }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- if $rootContext.Values.promptTemplates }}
        - name: prompt-templates
          image: {{ $rootContext.Values.deployment.prompt_templates.image }}
          imagePullPolicy: {{ $rootContext.Values.deployment.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - |
              cp -fL /prompt-templates/* /models
          volumeMounts:
            - mountPath: /prompt-templates
              name: prompt-templates
            {{- range $key, $pvc := $componentPersistence }}
              {{- if $pvc.enabled }}
            - name: {{ $key }}
              mountPath: {{ $pvc.globalMount | default (printf "/%s" $key) }}
              {{- end }}
            {{- end }}
        {{- end }}
        {{- if $rootContext.Values.modelsConfigs }}
        - name: models-configs
          image: {{ $rootContext.Values.deployment.prompt_templates.image }}
          imagePullPolicy: {{ $rootContext.Values.deployment.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - |
              for file in /models-configs/*; do
                filename=$(basename "$file")
                if [[ $filename != *.yaml ]]; then
                  cp -fL "$file" "/models/$filename.yaml"
                else
                  cp -fL "$file" "/models/$filename"
                fi
              done
          volumeMounts:
            - mountPath: /models-configs
              name: models-configs
            {{- range $key, $pvc := $componentPersistence }}
              {{- if $pvc.enabled }}
            - name: {{ $key }}
              mountPath: {{ $pvc.globalMount | default (printf "/%s" $key) }}
              {{- end }}
            {{- end }}
        {{- end }}
      {{- end }}
      containers:
        - name: app
          image: "{{ $rootContext.Values.deployment.image.repository }}:{{ $rootContext.Values.deployment.image.tag }}"
          imagePullPolicy: {{ $rootContext.Values.deployment.pullPolicy }}
          resources:
            {{- toYaml $rootContext.Values.resources | nindent 12 }}
          {{- if or $deploymentObject.command $deploymentObject.args}}
          command:
            {{- if $deploymentObject.command }}
            {{- toYaml $deploymentObject.command | nindent 12 }}
            {{- else }}
            - /build/entrypoint.sh
            {{- end }}
            {{- if $deploymentObject.args }}
            {{- toYaml $deploymentObject.args | nindent 12 }}
            {{- end }}
          {{- end }}
          env:
            {{- range $key, $value := $deploymentObject.env }}
            - name: {{ $key | upper }}
              value: {{ quote $value }}
            {{- end }}
            - name: MODELS_PATH
              value: {{ $rootContext.Values.deployment.modelsPath }}
          {{- if $rootContext.Values.deployment.secretEnv }}
            {{- toYaml $rootContext.Values.deployment.secretEnv | nindent 12 }}
          {{- end}}
          volumeMounts:
            {{- range $key, $pvc := $componentPersistence }}
            {{- if $pvc.enabled }}
            - name: {{ $key }}
              mountPath: {{ $pvc.globalMount | default (printf "/%s" $key) }}
            {{- end }}
            {{- end }}
        {{- with $rootContext.Values.sidecarContainers }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      volumes:
        {{- range $key, $pvc := $componentPersistence }}
        {{- if $pvc.enabled }}
        - name: {{ $key }}
          persistentVolumeClaim:
            claimName: {{ printf "%s-%s-%s" (include "local-ai.fullname" $rootContext) $deploymentObject.component $key }}
        {{- end }}
        {{- end }}
        {{- if $rootContext.Values.promptTemplates }}
        - name: prompt-templates
          configMap:
            name: {{ template "local-ai.fullname" $rootContext }}-prompt-templates
        {{- end }}
        {{- if $rootContext.Values.modelsConfigs }}
        - name: models-configs
          configMap:
            name: {{ template "local-ai.fullname" $rootContext }}-models-configs
        {{- end }}
      {{- with $rootContext.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $rootContext.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $rootContext.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
