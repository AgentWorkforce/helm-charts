# GKE evidence: Relaycast on durable actors (PREVIEW, opt-in)

The durable-actors profile (Relaycast gateway plus a durable-actors control
plane, actor hosts on gVisor, state in GCS) was proven on the GKE reference
deployment on 2026-11-03. The 0.3.1 chart includes the optional
`durable-actors` dependency (`components.durableActors`, off by default) and
`relaycast.runtime.backend=durable-actors`. It is an opt-in preview profile,
disabled in this release's default customer values; its images and profile are
not part of the gated customer image matrix (`self-hosted/customer-images.yaml`).
The proof used a control-plane image with the invoke-only key patch, which is
not upstream yet.

Final round (three rounds). The functional checks below pass in round 3; the
Relaycast end-to-end suite is not green: it still has 4 known failures (listed
under the table).

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
| Relaycast end-to-end suite against the public cast origin | **Not green**: 104 passed / 4 failed (the 4 known failures below) |

The 4 suite failures also appeared in a local run of the suite (104 passed /
4 failed): the agent card requested by query parameter returns 401; the
action-wait observer that uses an `ot_live_` key; and two "observer socket is
not connected" failures that cascade from it.

Five defects (F1-F5: create timeout, idle sleep, edge WebSocket timeout,
handler loss after reconnect, stale-close race) were found and fixed during
the proof.
