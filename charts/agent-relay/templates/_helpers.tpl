{{- define "agent-relay.validate" -}}
{{- if and (dig "relaycast" true (.Values.components | default dict)) (eq (dig "credentials" "authority" "" (.Values.relaycast | default dict)) "relayauth") (not (dig "relayauth" true (.Values.components | default dict))) }}
{{- fail "relaycast.credentials.authority=relayauth requires components.relayauth=true: RelayAuth is the ar_ credential authority that pushes ar_ws_ keys into Relaycast" }}
{{- end }}
{{- include "agent-relay.validateHistoryOrigin" . }}
{{- include "agent-relay.validateDurableActors" . }}
{{- end }}

{{/*
Session ingest (alleyoop) verifies courier History assertions against the same
audience RelayHistory issues them for, so the two origins must be byte-equal.
*/}}
{{- define "agent-relay.validateHistoryOrigin" -}}
{{- $components := .Values.components | default dict -}}
{{- if and (dig "sessionsPipeline" true $components) (dig "relayhistory" true $components) }}
{{- $ingest := dig "alleyoop" "auth" "historyOrigin" "" (index .Values "sessions-pipeline" | default dict) -}}
{{- $history := dig "relayauth" "historyOrigin" "" (.Values.relayhistory | default dict) -}}
{{- if and $ingest $history (ne $ingest $history) }}
{{- fail (printf "sessions-pipeline.alleyoop.auth.historyOrigin (%s) must equal relayhistory.relayauth.historyOrigin (%s): session ingest verifies courier History assertions against that audience" $ingest $history) }}
{{- end }}
{{- end }}
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
{{- if not (dig "controlPlaneUrl" "" $cfg) }}{{- $consumers = append $consumers $name -}}{{- end }}
{{- if and (not (dig "controlPlaneUrl" "" $cfg)) (not $actorsOn) }}
{{- fail (printf "%s.runtime.backend=durable-actors requires components.durableActors=true (or %s.runtime.durableActors.controlPlaneUrl for an external control plane)" $name $name) }}
{{- end }}
{{- if and $actorsOn (not (dig "controlPlaneUrl" "" $cfg)) }}
{{- $adminSecret := dig "adminKeySecret" "name" "actors-credentials" $cfg -}}
{{- $credentials := dig "credentialsSecret" "actors-credentials" $da -}}
{{- if ne $adminSecret $credentials }}
{{- fail (printf "%s.runtime.durableActors.adminKeySecret.name (%s) must be durable-actors.credentialsSecret (%s): the admin api-key lives in the control plane's credentials Secret" $name $adminSecret $credentials) }}
{{- end }}
{{- $adminKey := dig "adminKeySecret" "key" "api-key" $cfg -}}
{{- if ne $adminKey "api-key" }}
{{- fail (printf "%s.runtime.durableActors.adminKeySecret.key (%s) must be api-key: the control plane reads its admin api-key from credentialsSecret[api-key]" $name $adminKey) }}
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
{{- fail "components.durableActors=true has no consumer: set relaycast.runtime.backend or relayfile.runtime.backend to durable-actors without controlPlaneUrl (devRuntime consumers and consumers with an external controlPlaneUrl do not use the in-umbrella control plane)" }}
{{- end }}
{{- end }}
