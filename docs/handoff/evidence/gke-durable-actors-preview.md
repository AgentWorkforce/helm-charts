# GKE evidence: Relaycast on durable actors (PREVIEW, not part of this release)

The durable-actors profile (Relaycast gateway plus a durable-actors control
plane, actor hosts on gVisor, state in GCS) was proven on the GKE reference
deployment on 2026-11-03. It is **not** in this release's chart or image
matrix. It depends on an unmerged chart change and a patched control plane that
isn't upstream yet. It is shown here so reviewers can see where the
architecture is going.

Final round (three rounds; all checks pass in round 3):

| Check | Result |
|---|---|
| Cold workspace create through the internal route | 201 in 2.9-4.0 s (round 1 took about 98 s; fixed) |
| Agent registration, roster, DMs over the public edge and across gateway replicas | PASS (DM latency about 0.5-1.3 s) |
| Observer socket sees `message.created` for a post through the other replica | PASS |
| Signed-URL file upload stored in GCS and read through the other replica | PASS (bytes identical) |
| Gateway pod deletion: SDK clients reconnect by themselves | PASS (16.8 s including replacement-pod readiness) |
| Control-plane rolling restart | PASS (clients back in 1.9 s; data persists) |
| Public-edge WebSockets idle for 5 minutes | PASS (no drops) |
| Actor sleep and wake with a connected observer | PASS (socket survives the wake on a new host) |
| Forced SDK reconnect, then an action invoke within 5 s | PASS 6/6 through one gateway pod, 4/4 through the edge |
| The gateway's invoke-only key is refused on admin routes | PASS (401) |
| Relaycast end-to-end suite against the public cast origin | 104 passed / 4 known failures |

Five defects (F1-F5: create timeout, idle sleep, edge WebSocket timeout,
handler loss after reconnect, stale-close race) were found and fixed during
the proof.
