#!/usr/bin/env bash
#
# Prints the ALB Ingresses for an agent-relay release on EKS (Auto Mode's
# built-in ALB controller, IngressClass "alb", or the AWS Load Balancer
# Controller with the same annotations). The chart ships only the GKE edge
# (gkeIngress), so on EKS the edge is applied next to the release:
#
#   scripts/selfhost/eks-alb-ingress.sh agent-relay | kubectl apply -f -
#
# One internet-facing ALB per public origin, because the proof has no custom
# domain: dashboard (with /cloud/api and /login routed to the control API, as
# the GKE root host does), api, and cast. Each ALB's DNS name is its origin.
# Health-check paths come from each Service's
# alb.ingress.kubernetes.io/healthcheck-path annotation (values-eks.yaml), so
# an ALB with several target groups checks each backend on its own path.
# The same edge denials as the GKE Ingress answer at the ALB with a fixed 404:
# /internal on api and cast, and Relaycast's workspace-create paths.
# Known gap: the ALB does not collapse a leading "//", and an Ingress path may
# not contain "//", so //internal/... reaches the API (which answers its own
# 404 "Route not found"; nothing under /internal is served on that path).
#
# With a domain and an ACM certificate, put the hosts on one ALB instead
# (alb.ingress.kubernetes.io/group.name, host rules, certificate-arn,
# listen-ports HTTP+HTTPS and ssl-redirect).

set -euo pipefail
NS="${1:-agent-relay}"
CLASS="${EKS_INGRESS_CLASS:-alb}"

common() {
  printf '%s\n' \
    "  annotations:" \
    "    alb.ingress.kubernetes.io/scheme: internet-facing" \
    "    alb.ingress.kubernetes.io/target-type: ip" \
    "    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600" \
    "    alb.ingress.kubernetes.io/actions.edge-deny: >-" \
    "      {\"type\":\"fixed-response\",\"fixedResponseConfig\":{\"contentType\":\"text/plain\",\"statusCode\":\"404\",\"messageBody\":\"not found\"}}"
}

deny() {
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: $2" \
    "            backend: { service: { name: edge-deny, port: { name: use-annotation } } }"
}

route() {
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: Prefix" \
    "            backend: { service: { name: $2, port: { number: $3 } } }"
}

header() {
  printf '%s\n' "---" "apiVersion: networking.k8s.io/v1" "kind: Ingress" "metadata:" \
    "  name: $1" "  namespace: ${NS}"
  common
  printf '%s\n' "spec:" "  ingressClassName: ${CLASS}" "  rules:" "    - http:" "        paths:"
}

header agent-relay-dashboard
route /cloud/api relay-cloud-api 80
route /login relay-cloud-api 80
route / relay-dashboard 8080

header agent-relay-api
deny /internal Prefix
route / relay-cloud-api 80

header agent-relay-cast
deny /internal Prefix
deny /v1/workspaces Exact
deny /v1/workspaces/ Exact
route / relaycast 8787
