# Self-hosted Agent Relay architecture

```mermaid
flowchart TB
  subgraph Clients["Customer devices and agents"]
    Desktop["Agent Relay Desktop\ntrusted API origin"]
    Agents["Relay-enabled agents"]
    Browser["Web browser"]
  end

  subgraph GCP["Customer GCP project"]
    LB["Global HTTPS Load Balancer\nDNS + managed TLS"]

    subgraph GKE["GKE · agent-relay namespace"]
      Dashboard["Relay Dashboard\nstatic SPA"]
      API["Headless Control API\ndevice auth · tenancy · credential exchange"]
      Cast["Relaycast\nmessaging · roster · delivery"]
      History["RelayHistory\nsession ingest · search · replay"]
      Auth["RelayAuth\nsigned scoped assertions"]
      Pipeline["96Bulls Sessions pipeline\nworkers · AlleyOop"]
      Secrets["Kubernetes Secrets\nor external secret delivery"]
      CastPVC[("Relaycast RWO PVC")]
    end

    subgraph Data["Managed data services"]
      ControlDB[("PostgreSQL\ncontrol-plane tables")]
      HistoryDB[("Dedicated PostgreSQL\nRelayHistory ledger")]
      SessionsDB[("PostgreSQL hoopdb\n96Bulls")]
      GCS[("GCS session objects")]
      Registry["Artifact Registry\nimmutable image digests"]
    end
  end

  Browser -->|HTTPS| LB
  Desktop -->|device login · workspace resolution| LB
  Agents -->|WebSocket/HTTPS messaging| LB

  LB -->|/| Dashboard
  LB -->|/cloud/api · api host| API
  LB -->|cast host| Cast
  LB -->|history host| History

  Dashboard -->|same-origin API| API
  API -->|mint assertion| Auth
  API -->|workspace key resolution| Cast
  API -->|scoped History session| History
  Desktop -->|durable delivery batches| History

  API --> ControlDB
  History --> HistoryDB
  Pipeline --> SessionsDB
  Pipeline --> GCS
  Cast --> CastPVC
  Secrets -.credentials.-> API
  Secrets -.credentials.-> Auth
  Secrets -.credentials.-> History
  Secrets -.credentials.-> Pipeline
  Registry -.digest-pinned images.-> GKE
```

## Trust and data boundaries

- The Desktop persists one public HTTPS control-plane origin. It does not store
  a deployment-wide workspace key in `deployment.json`.
- The control API binds users to an organization and workspace, then returns
  scoped Relaycast and RelayHistory credentials.
- RelayHistory uses a dedicated database and migration ledger. It must not
  share the 96Bulls `hoopdb` database.
- Public traffic enters through one GKE Ingress. Services remain `ClusterIP`;
  sensitive Relaycast administration paths are denied at the edge.
- Runtime and migration-owner database credentials are separate.
- Relaycast, RelayAuth, and the proof profile are single-writer components.
  This architecture is `portable-single`, not HA.

## Included and excluded

Included: messaging, agent roster and replies, session upload, durable retry,
search, replay, Dashboard, device login, and custom Desktop origin.

Excluded: Relayflows, Relayfile, billing, provider integrations, hosted fleet,
and hosted MCP.
