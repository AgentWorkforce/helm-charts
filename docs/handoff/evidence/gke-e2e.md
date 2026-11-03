# GKE end-to-end evidence: control plane, sessions, admin, flows, dashboard

Summary of the internal end-to-end run on the Agent Relay GKE reference
deployment, 2026-11-03. Internal identifiers (project, cluster, workspace and
pod IDs, addresses, keys) are removed. The harness is
`scripts/selfhost/e2e-gcp-proof.sh` (with `e2e-gcp-proof-driver.mjs` and
`e2e-gcp-proof-96bulls.ts`) in this archive. It needs a kube context for the install (it execs into the control-plane and Sessions pods)
and the install's public origins.

## Topology under test
- GKE (regional), Cloud SQL for PostgreSQL 17 (private IP), GCS, Memorystore,
  Pub/Sub, a global external Application Load Balancer with Google-managed
  certificates on four hosts (dashboard, api, cast, history).
- Components: relaycontrol (self-host control-plane API), Relay Dashboard,
  Relaycast, RelayAuth, RelayHistory, 96Bulls Sessions, plus an in-namespace
  relayflows worker for the flows case.

## Result
The final run used `--require-public` and no allowed gaps. All 15 cases passed
(`E2E_RESULT=PASS`). Two earlier runs on later revisions also passed.

| # | Case | Result |
|---|---|---|
| 1-8 | Single-org control plane: the organization is reused, two workspaces are created, a second org is refused with 409, the membership gate returns not_member, and a token for workspace A cannot approve for workspace B (404) | PASS |
| — | Isolation: 28 workspace-scoped routes (sessions, flows, env vars, settings, runtime, audit, API tokens, enrollment) return 404 for workspace B on A's resources, plus RelayHistory and Relaycast isolation checks | PASS |
| 9 | Session erasure: list, search, replay and conversation turns are all purged (`erasure.turns_purged`) | PASS (after the RelayHistory 0074 fix) |
| 10 | Relaycast messaging through the public edge | PASS |
| 11 | Sessions API through the public origin | PASS |
| 12 | Admin: env vars are masked and never returned in plaintext; audit entries are written; `/internal` is denied at the edge | PASS |
| 13 | Flows: an in-namespace worker (`agent-relay@12.4.1`) registers, runs one flow to COMPLETED, and receives its workspace env | PASS |
| 14 | Dashboard SPA served at `/` with `/runtime-config.js` | PASS |
| 15 | Cleanup (on by default) | PASS |

## Known gaps (not failures)
- relaycontrol has no workspace or user delete API, so each run leaves two
  workspaces and one user with no membership.
- The v1 worker runtime uploads no runner log, so run logs show
  `available=false`.
