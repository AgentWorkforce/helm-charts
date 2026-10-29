{{/*
Full image reference. A digest wins over the tag; the tag defaults to
.Chart.AppVersion. global.imageRegistry is prefixed when set.
*/}}
{{- define "alleyoop.image" -}}
{{- $repo := .Values.image.repository -}}
{{- with .Values.global.imageRegistry }}{{ $repo = printf "%s/%s" (trimSuffix "/" .) $repo }}{{ end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{- define "alleyoop.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
