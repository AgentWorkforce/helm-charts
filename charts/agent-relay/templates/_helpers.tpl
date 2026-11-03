{{- define "agent-relay.validate" -}}
{{- if and (dig "relaycast" true (.Values.components | default dict)) (eq (dig "credentials" "authority" "" (.Values.relaycast | default dict)) "relayauth") (not (dig "relayauth" true (.Values.components | default dict))) }}
{{- fail "relaycast.credentials.authority=relayauth requires components.relayauth=true: RelayAuth is the ar_ credential authority that pushes ar_ws_ keys into Relaycast" }}
{{- end }}
{{- include "agent-relay.validateDurableActors" . }}
{{- end }}

{{/*
durable-actors wiring between the umbrella, the vendored control-plane chart
and its actor-mode consumers (relaycast, relayfile).
*/}}
{{- define "agent-relay.validateDurableActors" -}}
{{- $components := .Values.components | default dict -}}
{{- $actorsOn := dig "durableActors" false $components -}}
{{- $da := index .Values "durable-actors" | default dict -}}
{{- $consumers := list -}}
{{- range $name, $component := dict "relaycast" "relaycast" "relayfile" "relayfile" }}
{{- $child := index $.Values $name | default dict -}}
{{- if and (dig $component false $components) (eq (dig "runtime" "backend" "" $child) "durable-actors") }}
{{- $cfg := dig "runtime" "durableActors" (dict) $child -}}
{{- if not (dig "devRuntime" "enabled" false $cfg) }}
{{- $consumers = append $consumers $name -}}
{{- if and (not (dig "controlPlaneUrl" "" $cfg)) (not $actorsOn) }}
{{- fail (printf "%s.runtime.backend=durable-actors requires components.durableActors=true (or %s.runtime.durableActors.controlPlaneUrl for an external control plane)" $name $name) }}
{{- end }}
{{- if and $actorsOn (not (dig "controlPlaneUrl" "" $cfg)) }}
{{- $adminSecret := dig "adminKeySecret" "name" "actors-credentials" $cfg -}}
{{- $credentials := dig "credentialsSecret" "actors-credentials" $da -}}
{{- if ne $adminSecret $credentials }}
{{- fail (printf "%s.runtime.durableActors.adminKeySecret.name (%s) must be durable-actors.credentialsSecret (%s): the admin api-key lives in the control plane's credentials Secret" $name $adminSecret $credentials) }}
{{- end }}
{{- $bucket := dig "storage" "bucket" "" $da -}}
{{- $artifact := dig "deployer" "artifactBucket" "" $cfg -}}
{{- if and (dig "deployer" "enabled" true $cfg) $artifact (ne $artifact $bucket) }}
{{- fail (printf "%s.runtime.durableActors.deployer.artifactBucket (%s) must be durable-actors.storage.bucket (%s): the control plane reads compiled code only from its own bucket" $name $artifact $bucket) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $actorsOn (not $consumers) }}
{{- fail "components.durableActors=true has no consumer: set relaycast.runtime.backend or relayfile.runtime.backend to durable-actors (devRuntime consumers bring their own runtime)" }}
{{- end }}
{{- end }}
