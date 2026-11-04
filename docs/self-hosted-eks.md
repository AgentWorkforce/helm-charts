# Self-hosted Agent Relay on AWS EKS

Status: proven once, end to end, on EKS Auto Mode inside a Pippen sandbox
(2026-11-04, chart `oci://ghcr.io/agentworkforce/charts/agent-relay` 0.3.4,
released images). Results: [What was proven](#what-was-proven). This is a
proof profile, not a production reference architecture.

Files:

| File | What it is |
| --- | --- |
| [`charts/agent-relay/values-eks.yaml`](../charts/agent-relay/values-eks.yaml) | Customer-neutral EKS values (the core suite without durable-actors). Replace every `REQUIRED OVERRIDE`. |
| [`scripts/selfhost/eks-alb-ingress.sh`](../scripts/selfhost/eks-alb-ingress.sh) | Prints the ALB Ingresses (the chart ships only the GKE edge). |
| [`scripts/selfhost/eks-proof-sandbox.sh`](../scripts/selfhost/eks-proof-sandbox.sh) | The proof substrate: VPC, EKS Auto Mode cluster, IAM roles, S3 bucket, Pod Identity, NodePool/StorageClass/IngressClass. Pippen conventions. |
| [`scripts/selfhost/eks-proof-install.sh`](../scripts/selfhost/eks-proof-install.sh) | CNPG operator, the control-API Postgres, generated Secret, Helm install, Ingresses, uninstall. |
| [`scripts/selfhost/e2e-eks-proof.sh`](../scripts/selfhost/e2e-eks-proof.sh) | The e2e: the GKE proof's cases through the ALB edge (`e2e-gcp-proof.sh --edge alb`) plus EKS checks. |
| [`scripts/selfhost/e2e-eks-proof-s3.ts`](../scripts/selfhost/e2e-eks-proof-s3.ts) | The Pod Identity to S3 round trip the e2e runs in the alleyoop pod. |

## Mapping from the GKE profile

| GKE (`values-gcp.yaml`) | EKS (`values-eks.yaml`) |
| --- | --- |
| `gkeIngress` (GCE Ingress, ManagedCertificate, FrontendConfig, static IP) | `gkeIngress.enabled=false`; ALB Ingresses from `eks-alb-ingress.sh` (EKS Auto Mode's built-in ALB controller, IngressClass `alb`; the AWS Load Balancer Controller takes the same annotations). Edge denials (`/internal`, Relaycast workspace create) are ALB fixed-response 404 actions. |
| NEG annotations, BackendConfig | `alb.ingress.kubernetes.io/healthcheck-path` on each Service; ALB idle timeout 3600 s for WebSocket/SSE |
| GKE Workload Identity | EKS Pod Identity associations for `<release>-worker` and `<release>-alleyoop` (one IAM role with S3 access to the bucket). No IRSA/OIDC provider needed. |
| GCS Locker bucket (`locker.provider: gcs`) | S3 bucket (`locker.provider: s3`, empty endpoint, `credentials.mode: podIdentity`) |
| Cloud SQL (HoopDb, control API) | HoopDb: the chart's in-cluster CloudNativePG cluster (`sessions-pipeline.hoopdb.enabled=true`, selfhosted mode with the runtime-role and function-default Jobs). Control API: any PostgreSQL; the proof used a second CNPG cluster. Production: RDS/Aurora PostgreSQL. |
| Memorystore, Pub/Sub (GCS data-path env) | Not used: the services' S3 data path needs neither |
| GCE load-balancer ranges in NetworkPolicy `ingressFrom` | The VPC CIDR (ALB in IP target mode reaches pods from inside the VPC) |
| Artifact Registry mirrors | Public GHCR release images; the private services image from ECR (node role pulls; no pull secret) |

## Images used

| Component | Image | Source |
| --- | --- | --- |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca…` | public GHCR (chart pin) |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | public GHCR (chart pin) |
| relay-cloud-api | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` (relaycontrol 8e989a1) | GHCR, now anonymously pullable (no pull secret needed) |
| relay-dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | public GHCR (chart pin) |
| worker, alleyoop, privileged SQL | `500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5bb60752…` (sessions-pipeline 7d7229b) | **ECR in sessions-dev**, whose repository policy grants the sandbox account pull. The GHCR copy is private; no read:packages token was used. |
| CNPG Postgres | `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9…` | public (chart pin) |

## GKE-only, or not on EKS yet

- **durable-actors** and everything that runs on it (Relaycast and Relayfile
  actor backends): needs GKE Sandbox (gVisor) and GCS. Off in `values-eks.yaml`.
- **Relaycast S3 fileStore**: the S3/GCS file store exists only in the
  durable-actors backend. The SQLite backend keeps files on its EBS PVC
  (one replica).
- **Relayfile**: on GKE it runs on durable-actors; the standalone
  `ghcr.io/agentworkforce/relayfile` server image is not published. Off.
- **RelayHistory**: no release image is published (the chart default digest is
  empty and `values-gcp.yaml` marks it PENDING; the GKE proof runs a private
  Artifact Registry build). Off, so every history-backed feature is missing:
  see the e2e results.
- **TLS and custom domains**: the proof used the plain ALB hostnames over
  HTTP (gap 3 below). Production needs an ACM certificate, DNS names,
  `listen-ports` HTTP+HTTPS and `ssl-redirect`; with those, the hosts can
  share one ALB through `group.name`.
- **Flow artifacts**: `relay-cloud-api.flows.storage` is `postgres` (inline in
  PostgreSQL); the only object-store option is GCS, there is no S3 option.

## What was proven

Environment: EKS Auto Mode 1.34 (`pippen-sbx-eks-proof`, us-west-2), in the
Pippen sandbox of agent `aws-proof` (account 361835732085), public subnets,
built-in `general-purpose` node pool (one node ran everything). Helm release
`agent-relay` revision 4, chart 0.3.4 from GHCR, `values-eks.yaml` plus the
generated proof overlay. All Deployments Ready, the four migration Jobs
(control API, HoopDb migrate, runtime role, function default) Complete, both
CNPG clusters healthy. Edge: three internet-facing ALBs.

`scripts/selfhost/e2e-eks-proof.sh --edge-wait 60` (runs 4 and 5 gave the same
case results; run 1 failed only because the installation organization did not
exist yet, see `bootstrap-org`):

| Case | Result | Why |
| --- | --- | --- |
| 1 bootstrap (single org, two workspaces, device auth, membership gate) | **PASS** | |
| 2 messaging (register, roster, A to B, reply, history) | **PASS** | Relaycast SQLite on EBS |
| 3 session delivery | FAIL | RelayHistory not installed (no image): `relayhistory/session(sync) status=502` |
| 4 reads, 11 sessions API, 5 isolation, 6 durability, 9 erasure | FAIL (blocked) | need a delivered session (case 3) |
| 7 auth | FAIL | `auth.jwks` PASS (RS256); the token check calls RelayHistory |
| 8 Sessions Pipeline | FAIL | assertion mint PASS; the courier push gets 401 `auth_not_configured`: this services build presents the assertion as a bearer token, which the ingest accepts only with `ALLOW_INTERIM_RELAYAUTH_BEARER` (chart: `environment=local` only). The GKE live proof ran with it on; not EKS-specific |
| 10 public edge | FAIL (partly) | api whoami/resolve 200, anonymous 401, cast roster/agent 200, anonymous 401, cast workspace-create and `/internal` denied at the ALB (404). Fails on the dashboard sessions read (502, RelayHistory) and the history host (none) |
| 12 admin | FAIL (partly) | env var create/list masked/update/delete/audit PASS, `/internal` needs the service credential PASS; edge denial PASS for every variant except `//internal/...` (see gaps) |
| 13 flows (enrollment token, worker Pod, deterministic run, steps/logs) | **PASS** | flow artifacts in PostgreSQL |
| 14 dashboard (SPA, runtime-config, deep links) | **PASS** | |
| 15 cleanup | **PASS** | |

EKS checks (`e2e-eks-proof.sh`, all PASS):

```
EKS|PASS|eks.pod_identity|associations=agent-relay-worker relaycast agent-relay-alleyoop
EKS|PASS|eks.s3_locker_roundtrip|credentials=pod-identity bucket=pippen-sbx-eks-proof-361835732085 key=e2e-eks-proof/1793764145822.txt head=found listed=2 read_back=true
EKS|PASS|eks.s3_locker_delete|key=e2e-eks-proof/1793764145822.txt
EKS|PASS|eks.alb_targets|healthy_target_groups=4
EKS|PASS|eks.cnpg|control-api-pg=Cluster in healthy state;hoopdb=Cluster in healthy state
```

The S3 round trip runs through the services image's own Locker adapter in the
alleyoop pod, so it proves Pod Identity and the S3 data path; no session
reached S3 through the pipeline because of the case 8 gap.

In short: the control plane, device auth, workspace admin, Relaycast
messaging, Relayflows on a worker, the dashboard, RelayAuth, HoopDb migrations
on CNPG, Pod Identity to S3 and the ALB edge work on EKS. Everything that needs
RelayHistory, and the courier push, does not yet.

Teardown (2026-11-04 03:50-04:05Z): `eks-proof-install.sh uninstall` (Ingresses
and ALBs, release, CNPG clusters, PVCs/EBS, operator, namespaces), then
`eks-proof-sandbox.sh down` (cluster, bucket, VPC, roles), then
`pippen sandbox down aws-proof`: `"clean": true`, no failures (it deleted only
the session role). Direct checks before the sweep found no instances, volumes,
load balancers, target groups, ENIs, non-default security groups, clusters,
workload roles or proof buckets.

## Reproduce

Inside a Pippen sandbox lease (`pippen sandbox up <agent>`), from this repo:

```sh
export EKS_PROOF_API_CIDR=<operator egress>/32
pippen sandbox exec <agent> --static-credentials -- scripts/selfhost/eks-proof-sandbox.sh up
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh prereqs
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh install
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh bootstrap-org
pippen sandbox exec <agent> -- scripts/selfhost/e2e-eks-proof.sh
# teardown
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh uninstall
pippen sandbox exec <agent> --static-credentials -- scripts/selfhost/eks-proof-sandbox.sh down
pippen sandbox down <agent>          # must report clean: true
```

Outside Pippen, run the same scripts with your own AWS credentials and drop
the conventions you do not need (the `pippen:sandbox` tags, the
`/pippen/workload/` role path and the permissions boundary).

## Gaps and follow-ups

1. **RelayHistory has no release image.** It blocks cases 3 to 7, 9 and 11
   and the history host. Publish the image (relayhistory-cloud #280), add it to
   `values-eks.yaml` and rerun.
2. **Courier push needs `ALLOW_INTERIM_RELAYAUTH_BEARER`.** The 7d7229b services
   build sends the origin-bound assertion as a bearer token. The customer
   profile keeps that flag off, so the push is refused. GKE has the same gap,
   hidden because the live proof turned the flag on. Fix it in sessions-pipeline
   (an assertion path that does not need the interim flag) or document the
   flag.
3. **The charts accept only HTTPS public origins.** `relay-cloud-api.publicUrl`,
   `services.relaycastPublicUrl`/`relayhistoryPublicUrl` and
   `relay-dashboard.runtime.publicUrl` must be `https://`, and reserved TLDs
   are refused. A bare ALB hostname cannot get an ACM certificate. The proof
   named the origins `https://<ALB hostname>` to pass validation while the ALBs
   served HTTP, and the clients used `http://`. That is not a working browser
   setup. A real install needs DNS names and an ACM certificate (Route 53 or
   any DNS; with `ExternalDNS`, a single ALB through `group.name`).
4. **`//internal/...` is not denied at the ALB.** The ALB does not collapse a
   leading `//` and Kubernetes refuses `//` in an Ingress path, so the request
   reaches the API. The API answers its own 404 `Route not found`, so nothing
   is exposed, but the edge-denial check fails. Options: an ALB
   `conditions.*` rule with a `//internal*` path pattern, or AWS WAF.
5. **The chart has no EKS edge.** `gkeIngress` is GKE-only. The ALB Ingresses
   live in `scripts/selfhost/eks-alb-ingress.sh`. An `albIngress` block in
   the umbrella (a chart change and a version bump) would make it one install.
6. **One-time organization bootstrap.** A fresh control plane has no
   installation organization. `eks-proof-install.sh bootstrap-org` creates it
   (`POST /api/v1/organizations` with the bootstrap token, from inside the API
   pod). The GKE proof's organization was created by hand once. Customers need
   this step documented in the chart README.
7. **`values-gcp.yaml` also lacks the alleyoop `historyOrigin`,** and
   `allowInClusterHttp` plus an FQDN JWKS URL. The release drill found the
   same; `values-eks.yaml` sets them.
8. **EKS Auto Mode with IAM paths.** A custom NodeClass refused a node role
   under `/pippen/workload/` ("unauthorized to join nodes to the cluster", even
   with the EC2 access entry and `AmazonEKSAutoNodePolicy`). The built-in
   pools accept it. Custom tags on ALBs (IngressClassParams `tags`) break
   `CreateRule`, because `AmazonEKSLoadBalancingPolicy` allows only its own
   tag keys. Removing them later left security groups the controller could
   not untag, which had to be deleted by hand. Do not tag Auto Mode ALBs.
9. **Not yet proven on EKS:** RDS/Aurora instead of CNPG, private subnets
   with NAT, NetworkPolicy enforcement (the policies render with the VPC CIDR,
   but Auto Mode's network policy controller was not enabled in the proof),
   backup/restore and upgrade drills, and HA (relaycast and relayauth are
   single-replica SQLite on EBS).
