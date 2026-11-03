{{- define "agent-relay.validate" -}}
{{- if and (dig "relaycast" true (.Values.components | default dict)) (eq (dig "credentials" "authority" "" (.Values.relaycast | default dict)) "relayauth") (not (dig "relayauth" true (.Values.components | default dict))) }}
{{- fail "relaycast.credentials.authority=relayauth requires components.relayauth=true: RelayAuth is the ar_ credential authority that pushes ar_ws_ keys into Relaycast" }}
{{- end }}
{{- end }}
