{{/*
Full image reference for the engine container.
<global.imageRegistry>/<image.repository>@<digest> when image.digest is set
(the registry is prefixed only to relative repositories),
otherwise :<image.tag | Chart.AppVersion>.
*/}}
{{- define "relaycast-cloud.images.server" -}}
{{- $repo := .Values.image.repository -}}
{{- /* A repository whose first segment looks like a host (has "." or ":",
or is "localhost") is already fully qualified: never prefix it. */ -}}
{{- $first := first (splitList "/" $repo) -}}
{{- $qualified := and (gt (len (splitList "/" $repo)) 1) (or (contains "." $first) (contains ":" $first) (eq "localhost" $first)) -}}
{{- if and .Values.global.imageRegistry (not $qualified) }}{{ $repo = printf "%s/%s" (trimSuffix "/" .Values.global.imageRegistry) $repo }}{{ end -}}
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
