{{/*
Full image reference for the engine container.
<global.imageRegistry>/<image.repository>@<digest> when image.digest is set,
otherwise :<image.tag | Chart.AppVersion>.
*/}}
{{- define "relaycast-cloud.images.server" -}}
{{- $registry := .Values.global.imageRegistry -}}
{{- $repo := .Values.image.repository -}}
{{- if $registry }}{{- $repo = printf "%s/%s" (trimSuffix "/" $registry) $repo -}}{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (.Values.image.tag | default .Chart.AppVersion | toString) -}}
{{- end -}}
{{- end }}

{{/*
imagePullSecrets block, rendered on every workload and Job.
*/}}
{{- define "relaycast-cloud.images.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
