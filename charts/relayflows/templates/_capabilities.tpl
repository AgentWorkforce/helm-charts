{{/* Return the supported PodDisruptionBudget apiVersion. */}}
{{- define "relayflows.capabilities.pdb.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "policy/v1" -}}
policy/v1
{{- else -}}
policy/v1beta1
{{- end -}}
{{- end }}

{{/* Return the installed VerticalPodAutoscaler apiVersion. */}}
{{- define "relayflows.capabilities.vpa.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "autoscaling.k8s.io/v1" -}}
autoscaling.k8s.io/v1
{{- else -}}
autoscaling.k8s.io/v1beta2
{{- end -}}
{{- end }}
