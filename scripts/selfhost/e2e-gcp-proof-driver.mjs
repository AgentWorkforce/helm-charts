// In-cluster driver for e2e-gcp-proof.sh.
//
// Runs inside the relay-cloud-api pod (the only agent-relay workload whose
// NetworkPolicy reaches Relaycast, RelayHistory, and RelayAuth) with Node's
// built-in fetch. Usage:
//
//   node e2e-gcp-proof-driver.mjs <phase>   < state.json  > result.json
//
// stdin is the JSON state from the previous phase plus `secrets`, which the
// caller injects on every call and which is never written back. stdout is one
// JSON object `{ state, proofs }`. `state` holds test-workspace credentials
// and is kept by the caller in a mode-0600 file; `proofs` holds only curated,
// non-secret details. Nothing here logs a token, key, or response body.

import { createHash, createPublicKey, randomBytes, verify as cryptoVerify } from "node:crypto";
import { readFileSync } from "node:fs";

const RELAYCAST = process.env.E2E_RELAYCAST_URL ?? "http://relaycast:8787";
const HISTORY = process.env.E2E_RELAYHISTORY_URL ?? "http://relayhistory:8080";
const API = process.env.E2E_API_URL ?? "http://localhost:3000";
const RELAYAUTH = process.env.E2E_RELAYAUTH_URL ?? "http://relayauth.relayauth.svc:8787";
const BOOTSTRAP_FILE = "/var/run/agent-relay/secrets/selfhost-bootstrap-token";
const RELAYAUTH_KEY_FILE = "/var/run/agent-relay/secrets/relayauth-api-key";
const SOURCE = "claude";

const phase = process.argv[2];
const input = JSON.parse(readFileSync(0, "utf8") || "{}");
const secrets = input.secrets ?? {};
delete input.secrets;
const state = input;
const proofs = [];

function proof(result, check, detail) {
  proofs.push({ result, check, detail: String(detail) });
}
const pass = (check, detail) => proof("PASS", check, detail);
const fail = (check, detail) => proof("FAIL", check, detail);

class CheckError extends Error {}
function must(condition, message) {
  if (!condition) throw new CheckError(message);
}

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");

async function call(method, url, { token, headers = {}, body } = {}) {
  const response = await fetch(url, {
    method,
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
    headers: {
      accept: "application/json",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: response.status, json };
}

// Relaycast wraps payloads as { ok, data }.
const rcData = (response) => response.json?.data ?? response.json;

function errorCode(response) {
  const error = response.json?.error;
  if (typeof error === "string") return error;
  if (error && typeof error.code === "string") return error.code;
  return "none";
}

// ---------------------------------------------------------------- bootstrap

async function createTenant(label) {
  const bootstrap = readFileSync(BOOTSTRAP_FILE, "utf8").trim();
  const marker = state.marker;

  const rc = await call("POST", `${RELAYCAST}/internal/workspaces`, {
    token: secrets.relaycastInternalSecret,
    body: { name: `e2e-${marker}-${label}` },
  });
  must(rc.status === 201, `relaycast internal create status=${rc.status} error=${errorCode(rc)}`);
  const rcWorkspace = rcData(rc);
  const rcKey = rcWorkspace.api_key;
  must(typeof rcKey === "string" && rcKey.startsWith("rk_live_"), "relaycast returned no workspace key");

  const org = await call("POST", `${API}/api/v1/organizations`, {
    token: bootstrap,
    body: {
      name: `e2e-${marker}-${label}`,
      ownerEmail: `e2e-${marker}-${label}@gcp-proof.agentrelay.com`,
      ownerName: `E2E ${label.toUpperCase()}`,
    },
  });
  must(org.status === 201, `organization create status=${org.status} error=${errorCode(org)}`);

  const ws = await call("POST", `${API}/api/v1/organizations/${org.json.id}/workspaces`, {
    token: bootstrap,
    body: {
      name: `e2e-${marker}-${label}`,
      relaycastWorkspaceId: rcWorkspace.workspace_id,
      relaycastApiKey: rcKey,
    },
  });
  must(ws.status === 201, `workspace create status=${ws.status} error=${errorCode(ws)}`);

  // Device authorization exactly as Desktop does it, approved by the bootstrap
  // bearer on behalf of the organization owner.
  const start = await call("POST", `${API}/api/v1/auth/device/start`, {
    body: { client_name: `e2e-${marker}-${label}` },
  });
  must(start.status === 201, `device start status=${start.status}`);
  const approve = await call("POST", `${API}/api/v1/auth/device/approve`, {
    token: bootstrap,
    body: {
      action: "approve",
      user_code: start.json.user_code,
      user_id: org.json.owner.id,
      workspace_id: ws.json.id,
    },
  });
  must(approve.status === 200, `device approve status=${approve.status} error=${errorCode(approve)}`);
  const tokens = await call("POST", `${API}/api/v1/auth/device/token`, {
    body: { device_code: start.json.device_code },
  });
  must(tokens.status === 200 && tokens.json?.access_token, `device token status=${tokens.status}`);

  return {
    relaycastWorkspaceId: rcWorkspace.workspace_id,
    organizationId: org.json.id,
    ownerUserId: org.json.owner.id,
    workspaceId: ws.json.id,
    accessToken: tokens.json.access_token,
    scope: tokens.json.scope,
  };
}

async function phaseBootstrap() {
  state.marker = state.marker ?? `e2e${Date.now().toString(36)}${randomBytes(3).toString("hex")}`;
  state.startedAt = new Date().toISOString();
  for (const label of ["a", "b"]) {
    const tenant = await createTenant(label);
    state[label] = tenant;
    pass(
      `bootstrap.tenant_${label}`,
      `relaycast_ws=${tenant.relaycastWorkspaceId} org=${tenant.organizationId} workspace=${tenant.workspaceId} owner=${tenant.ownerUserId} scope=${tenant.scope.replace(/ /g, ",")}`,
    );
    const who = await call("GET", `${API}/api/v1/auth/whoami`, { token: tenant.accessToken });
    must(
      who.status === 200 && who.json?.currentWorkspace?.id === tenant.workspaceId,
      `whoami status=${who.status}`,
    );
    const resolved = await call("GET", `${API}/api/v1/workspaces/${tenant.workspaceId}/resolve`, {
      token: tenant.accessToken,
    });
    must(resolved.status === 200, `resolve status=${resolved.status}`);
    must(
      resolved.json.relaycastWorkspaceId === tenant.relaycastWorkspaceId &&
        typeof resolved.json.relaycastApiKey === "string" &&
        resolved.json.relaycastApiKey.startsWith("rk_live_"),
      "resolve returned a different Relaycast workspace or no key",
    );
    // The key Desktop actually uses is the one the control plane returns.
    tenant.relaycastKey = resolved.json.relaycastApiKey;
    pass(
      `bootstrap.resolve_${label}`,
      `whoami_workspace_matches=true relaycast_url=${resolved.json.urls?.relaycastUrl}`,
    );
  }
}

// ---------------------------------------------------------------- messaging

async function registerAgent(tenant, name) {
  const response = await call("POST", `${RELAYCAST}/v1/agents`, {
    token: tenant.relaycastKey,
    body: { name, type: "agent", metadata: { e2e: state.marker } },
  });
  must(response.status === 201 || response.status === 200, `register ${name} status=${response.status} error=${errorCode(response)}`);
  const data = rcData(response);
  must(typeof data.token === "string", `register ${name} returned no agent token`);
  return { id: data.id, name: data.name, token: data.token };
}

async function rosterNames(tenant) {
  const response = await call("GET", `${RELAYCAST}/v1/agents`, { token: tenant.relaycastKey });
  must(response.status === 200, `roster status=${response.status}`);
  const list = rcData(response);
  const agents = Array.isArray(list) ? list : list?.agents ?? list?.items ?? [];
  return agents.map((agent) => agent.name);
}

async function dmThread(agent, peerName) {
  const conversations = await call("GET", `${RELAYCAST}/v1/dm/conversations`, { token: agent.token });
  must(conversations.status === 200, `conversations status=${conversations.status}`);
  const list = rcData(conversations);
  const items = Array.isArray(list) ? list : list?.conversations ?? list?.items ?? [];
  const match = items.find((conversation) =>
    JSON.stringify(conversation.participants ?? conversation.members ?? conversation).includes(peerName),
  );
  must(match, `no DM conversation with ${peerName}`);
  const conversationId = match.id ?? match.conversation_id;
  const messages = await call("GET", `${RELAYCAST}/v1/dm/${conversationId}/messages?limit=50`, {
    token: agent.token,
  });
  must(messages.status === 200, `dm messages status=${messages.status}`);
  const body = rcData(messages);
  const list2 = Array.isArray(body) ? body : body?.messages ?? body?.items ?? [];
  return { conversationId, messages: list2 };
}

const messageText = (message) => message.text ?? message.content ?? message.body ?? "";

async function phaseMessaging() {
  const tenant = state.a;
  const names = [`e2e-${state.marker}-alpha`, `e2e-${state.marker}-beta`];
  const alpha = await registerAgent(tenant, names[0]);
  const beta = await registerAgent(tenant, names[1]);
  state.agents = { alpha, beta };
  pass("messaging.register", `agents=${alpha.id},${beta.id}`);

  const roster = await rosterNames(tenant);
  must(names.every((name) => roster.includes(name)), "roster is missing a registered agent");
  pass("messaging.roster", `roster_size=${roster.length} contains_both=true`);

  const pingText = `${state.marker} ping from alpha`;
  const ping = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: alpha.token,
    body: { to: beta.name, text: pingText },
  });
  must(ping.status === 200 || ping.status === 201, `send ping status=${ping.status} error=${errorCode(ping)}`);
  const pingId = rcData(ping)?.id ?? rcData(ping)?.message_id ?? rcData(ping)?.message?.id;

  const betaView = await dmThread(beta, alpha.name);
  must(betaView.messages.some((m) => messageText(m) === pingText), "beta did not receive the ping");
  pass("messaging.a_to_b", `conversation=${betaView.conversationId} message=${pingId ?? "n/a"}`);

  const replyText = `${state.marker} reply from beta`;
  const reply = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: beta.token,
    body: { to: alpha.name, text: replyText },
  });
  must(reply.status === 200 || reply.status === 201, `send reply status=${reply.status} error=${errorCode(reply)}`);
  const replyId = rcData(reply)?.id ?? rcData(reply)?.message_id ?? rcData(reply)?.message?.id;

  const alphaView = await dmThread(alpha, beta.name);
  must(alphaView.conversationId === betaView.conversationId, "reply landed in a different conversation");
  must(alphaView.messages.some((m) => messageText(m) === replyText), "alpha did not receive the reply");
  pass("messaging.b_to_a_same_conversation", `conversation=${alphaView.conversationId} message=${replyId ?? "n/a"}`);

  state.dm = { conversationId: alphaView.conversationId, pingText, replyText, pingId, replyId };
  await checkMessageHistory("messaging.history");
}

async function checkMessageHistory(check) {
  const { alpha, beta } = state.agents;
  for (const [agent, peer] of [[alpha, beta], [beta, alpha]]) {
    const view = await dmThread(agent, peer.name);
    must(view.conversationId === state.dm.conversationId, `${agent.name} sees another conversation`);
    const texts = view.messages.map(messageText);
    const iPing = texts.indexOf(state.dm.pingText);
    const iReply = texts.indexOf(state.dm.replyText);
    must(iPing >= 0 && iReply >= 0, `${agent.name} history is missing a message`);
  }
  pass(check, `conversation=${state.dm.conversationId} both_agents_see_ping_and_reply=true`);
}

// ---------------------------------------------------------------- history

async function historySession(tenant, mode) {
  const response = await call("POST", `${API}/api/v1/workspaces/${tenant.workspaceId}/relayhistory/session`, {
    token: tenant.accessToken,
    body: { mode, label: `e2e-${state.marker}` },
  });
  must(
    response.status === 200 && typeof response.json?.accessToken === "string",
    `relayhistory/session(${mode}) status=${response.status} error=${errorCode(response)} stage=${response.json?.stage ?? "none"} upstream=${response.json?.upstreamStatus ?? "none"}`,
  );
  return response.json;
}

function accountId(tenant) {
  return `relayhistory:${sha256(JSON.stringify([tenant.organizationId, tenant.workspaceId]))}`;
}

function buildBatch() {
  const marker = state.marker;
  const sessionId = state.session.sessionId;
  const origin = state.session.originId;
  const now = Date.parse(state.startedAt);
  const project = "/e2e/gcp-proof";
  const base = { git_branch: null, project, session_id: sessionId, source: SOURCE };
  const sessionEvent = (id, role, text, ts) => ({
    ...base,
    agent_id: null, agent_version: null, call_index: null, cwd: project, error_signal: null,
    event_index: id, event_source: "provider", event_uid: `${sessionId}-message-${id}:0`, id,
    is_meta: 0, is_sidechain: 0, kind: "text", message_id: `${sessionId}-message-${id}`, model: null,
    parent_id: null, payload_bytes: null, payload_hash: null, payload_truncated: 0,
    project_key: null, project_key_method: null, provider: "anthropic", provider_message_id: null,
    raw_facts_version: 2, raw_kind: role, request_id: null, request_span: null,
    result_status: "completed", role, stop_reason: null, subagent_session_id: null, text,
    token_json: null, tool_use_id: null, ts_ms: ts, turn_id: `turn-${id}`,
  });
  const payloads = [
    ["session", {
      agent_version: null, cwd: project, discovery_state: "full", first_activity_ms: now,
      first_prompt: `${marker} first prompt`, git_branch: null, initial_commit: null,
      last_activity_ms: now + 2000, last_assistant_text: `${marker} assistant answer`,
      models_json: null, originator: null, parser_version: 1, project_key: null,
      project_key_method: null, repo_url: null, session_id: sessionId, source: SOURCE,
      source_stamp: null, workspace_roots_json: null,
    }],
    ["history", { ...base, id: 1, prompt: `${marker} first prompt`, prompt_hash: sha256(marker).slice(0, 16), timestamp_ms: now }],
    ["session_event", sessionEvent(1, "user", `${marker} first prompt`, now)],
    ["session_event", sessionEvent(2, "assistant", `${marker} assistant answer`, now + 1000)],
    ["tool_call", {
      args_json: JSON.stringify({ path: `${project}/README.md` }), id: 1, is_error: 0,
      message_id: `${sessionId}-message-2`, name: "Read", session_id: sessionId, source: SOURCE,
      target: "README.md", tool_use_id: `${sessionId}-tool-1`, ts_ms: now + 1500,
    }],
  ];
  const records = payloads.map(([kind, payload], index) => {
    const recordId = sha256(`${origin}:${kind}:${sessionId}:${index}`);
    const revisionId = sha256(`${recordId}:1:${JSON.stringify(payload)}`);
    return {
      kind, operation: "upsert", origin_id: origin, payload, record_id: recordId,
      revision: 1, revision_id: revisionId, schema_version: 1, session_id: sessionId, source: SOURCE,
    };
  });
  return {
    protocolVersion: 1,
    batch: {
      account_id: accountId(state.a),
      batch_id: sha256(`${origin}:batch:1`).slice(0, 32),
      destination_id: "relayhistory",
      generation: 1,
      instance_id: `e2e-${marker}`,
      job_id: sha256(`${origin}:job:1`).slice(0, 32),
      mapping_version: "relayhistory-delivery-v1",
      origin_id: origin,
      records,
      schema_version: 1,
    },
  };
}

async function eventsDirect(token, tenant, sessionId) {
  const params = new URLSearchParams({ workspace: tenant.workspaceId, source: SOURCE, order: "asc", limit: "1000" });
  return call("GET", `${HISTORY}/v1/sessions/${encodeURIComponent(sessionId)}/events?${params}`, { token });
}

function markerEvents(events) {
  return (events ?? []).filter((event) => JSON.stringify(event).includes(state.marker));
}

async function phaseDelivery() {
  state.session = {
    sessionId: `e2e-${state.marker}-session`,
    originId: sha256(`origin:${state.marker}`).slice(0, 32),
  };
  const sync = await historySession(state.a, "sync");
  pass("delivery.session_token", `base_url=${sync.baseUrl} scopes=${(sync.scopes ?? []).join(",")}`);
  const request = buildBatch();

  const limits = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: sync.accessToken });
  must(limits.status === 200, `delivery limits status=${limits.status}`);

  const first = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: request });
  must(first.status === 200, `first delivery status=${first.status} error=${errorCode(first)}`);
  const receipt = first.json;
  const submitted = request.batch.records.map((record) => record.revision_id);
  must(receipt.acceptanceLevel === "durable", `acceptanceLevel=${receipt.acceptanceLevel}`);
  must(
    JSON.stringify(receipt.acceptedRevisionIds) === JSON.stringify(submitted),
    "receipt does not list every submitted revision in order",
  );
  must(typeof receipt.receiptId === "string", "receipt has no receiptId");
  state.session.batchId = request.batch.batch_id;
  state.session.receiptId = receipt.receiptId;
  state.session.records = submitted.length;
  pass(
    "delivery.first",
    `batch=${receipt.batchId} receipt=${receipt.receiptId} accepted=${receipt.acceptedRevisionIds.length} level=${receipt.acceptanceLevel}`,
  );

  // Retry the identical batch as Desktop does after losing the first response.
  const retry = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: request });
  must(retry.status === 200, `retry delivery status=${retry.status} error=${errorCode(retry)}`);
  must(retry.json.receiptId === receipt.receiptId, "retry returned a different receipt");
  must(
    JSON.stringify(retry.json.acceptedRevisionIds) === JSON.stringify(submitted),
    "retry accepted a different revision set",
  );
  pass("delivery.retry_same_receipt", `receipt=${retry.json.receiptId}`);

  const records = await call(
    "GET",
    `${HISTORY}/v1/delivery/records?${new URLSearchParams({ session_id: state.session.sessionId, source: SOURCE })}`,
    { token: sync.accessToken, headers: { "X-RelayHistory-Expected-Account": accountId(state.a) } },
  );
  const recordCount = Array.isArray(records.json?.records) ? records.json.records.length : null;

  must(records.status === 200, `delivery records status=${records.status} error=${errorCode(records)}`);
  must(recordCount === submitted.length, `retained delivery records=${recordCount} expected=${submitted.length}`);
  const events = await eventsDirect(sync.accessToken, state.a, state.session.sessionId);
  must(events.status === 200, `events status=${events.status}`);
  const projected = markerEvents(events.json.events);
  const ids = projected.map((event) => event.eventId);
  must(new Set(ids).size === ids.length, "duplicate projected events after retry");
  must(projected.length > 0, "no projected events for the session");
  state.session.projectedEvents = projected.length;
  pass(
    "delivery.single_projection",
    `projected_events=${projected.length} unique=${new Set(ids).size} retained_records=${recordCount}`,
  );
}

// ---------------------------------------------------------------- reads

async function dashboardList(tenant, workspaceId, query) {
  const params = new URLSearchParams(query ? { q: query } : {});
  return call("GET", `${API}/cloud/api/v1/workspaces/${workspaceId}/sessions${query ? `?${params}` : ""}`, {
    token: tenant.accessToken,
  });
}

async function dashboardEvents(tenant, workspaceId, sessionId) {
  return call(
    "GET",
    `${API}/cloud/api/v1/workspaces/${workspaceId}/sessions/${encodeURIComponent(sessionId)}/events?source=${SOURCE}`,
    { token: tenant.accessToken },
  );
}

async function readsPresent(prefix) {
  const { sessionId } = state.session;
  const list = await dashboardList(state.a, state.a.workspaceId);
  must(list.status === 200, `dashboard list status=${list.status} error=${errorCode(list)}`);
  must(list.json.items.some((item) => item.sessionId === sessionId), "dashboard list does not include the session");
  pass(`${prefix}.dashboard_list`, `items=${list.json.items.length} contains_session=true`);

  const replay = await dashboardEvents(state.a, state.a.workspaceId, sessionId);
  must(replay.status === 200, `dashboard replay status=${replay.status} error=${errorCode(replay)}`);
  const replayed = markerEvents(replay.json.events);
  must(replayed.length === state.session.projectedEvents, `dashboard replay events=${replayed.length} expected=${state.session.projectedEvents}`);
  pass(`${prefix}.dashboard_replay`, `events=${replayed.length}`);

  const search = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(search.status === 200, `dashboard search status=${search.status}`);
  must(search.json.items.some((item) => item.sessionId === sessionId), "dashboard search does not find the marker");
  pass(`${prefix}.dashboard_search`, `matches=${search.json.items.length}`);

  const read = await historySession(state.a, "read");
  const direct = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker, limit: "50" })}`,
    { token: read.accessToken },
  );
  must(direct.status === 200, `relayhistory search status=${direct.status}`);
  must(direct.json.sessions.some((item) => item.sessionId === sessionId), "relayhistory search does not find the marker");
  const directEvents = await eventsDirect(read.accessToken, state.a, sessionId);
  must(directEvents.status === 200 && markerEvents(directEvents.json.events).length === state.session.projectedEvents,
    `relayhistory replay status=${directEvents.status}`);
  pass(`${prefix}.relayhistory_direct`, `search_matches=${direct.json.sessions.length} replay_events=${state.session.projectedEvents}`);
}

async function phaseReads() {
  await readsPresent("reads");
}

// ---------------------------------------------------------------- isolation

async function phaseIsolation() {
  const { sessionId } = state.session;
  const crossList = await dashboardList(state.b, state.a.workspaceId);
  must(crossList.status === 404, `B listing A's workspace status=${crossList.status}`);
  const crossReplay = await dashboardEvents(state.b, state.a.workspaceId, sessionId);
  must(crossReplay.status === 404, `B replaying A's session status=${crossReplay.status}`);
  pass("isolation.control_plane", `b_list_a=${crossList.status} b_replay_a=${crossReplay.status}`);

  const ownSearch = await dashboardList(state.b, state.b.workspaceId, state.marker);
  must(ownSearch.status === 200, `B own search status=${ownSearch.status}`);
  must(!ownSearch.json.items.some((item) => item.sessionId === sessionId), "B's own workspace search returned A's session");
  const ownReplay = await dashboardEvents(state.b, state.b.workspaceId, sessionId);
  const leaked = ownReplay.status === 200 ? markerEvents(ownReplay.json.events).length : 0;
  must(leaked === 0, "B's own workspace replay returned A's events");
  pass("isolation.b_workspace_views", `search_matches=${ownSearch.json.items.length} replay_status=${ownReplay.status} leaked_events=0`);

  const bRead = await historySession(state.b, "sync");
  const forged = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker })}`,
    { token: bRead.accessToken },
  );
  const forgedLeak = forged.status === 200 && (forged.json.sessions ?? []).some((item) => item.sessionId === sessionId);
  must(!forgedLeak, "B's RelayHistory token listed A's session by naming A's workspace");
  const forgedEvents = await eventsDirect(bRead.accessToken, state.a, sessionId);
  const forgedEventLeak = forgedEvents.status === 200 && markerEvents(forgedEvents.json.events).length > 0;
  must(!forgedEventLeak, "B's RelayHistory token replayed A's session");
  const forgedDelivery = await call("POST", `${HISTORY}/v1/delivery/batches`, {
    token: bRead.accessToken,
    body: buildBatch(),
  });
  must(forgedDelivery.status === 403, `B delivering with A's account_id status=${forgedDelivery.status}`);
  pass(
    "isolation.relayhistory_direct",
    `b_list_with_a_workspace=${forged.status} b_events_with_a_workspace=${forgedEvents.status} b_deliver_as_a=${forgedDelivery.status}`,
  );

  // Relaycast tenant isolation: B's workspace key sees none of A's agents and
  // cannot read A's DM conversation.
  const bRoster = await rosterNames(state.b);
  must(!bRoster.some((name) => name.includes(state.marker)), "B's roster contains A's agents");
  const bAgent = await registerAgent(state.b, `e2e-${state.marker}-gamma`);
  const crossDm = await call("GET", `${RELAYCAST}/v1/dm/${state.dm.conversationId}/messages`, { token: bAgent.token });
  const crossDmLeak = crossDm.status === 200 && JSON.stringify(crossDm.json).includes(state.marker);
  must(!crossDmLeak, "B's agent read A's DM conversation");
  const crossSend = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: bAgent.token,
    body: { to: state.agents.alpha.name, text: `${state.marker} cross-tenant` },
  });
  must(crossSend.status >= 400, `B's agent DMed A's agent status=${crossSend.status}`);
  pass("isolation.relaycast", `b_roster_size=${bRoster.length} b_read_a_dm=${crossDm.status} b_dm_a_agent=${crossSend.status}`);
}

// ---------------------------------------------------------------- durability

async function phaseDurabilityHistory() {
  await readsPresent("durability.history");
}

async function phaseDurabilityRelaycast() {
  const roster = await rosterNames(state.a);
  must(
    [state.agents.alpha.name, state.agents.beta.name].every((name) => roster.includes(name)),
    "roster lost an agent across restart",
  );
  pass("durability.relaycast_roster", `roster_size=${roster.length} contains_both=true`);
  await checkMessageHistory("durability.relaycast_messages");
  // Agent tokens issued before the restart still authenticate.
  const me = await call("GET", `${RELAYCAST}/v1/agent`, { token: state.agents.alpha.token });
  must(me.status === 200, `agent token after restart status=${me.status}`);
  pass("durability.relaycast_agent_token", `status=${me.status}`);
}

// ---------------------------------------------------------------- auth

function jwtParts(token) {
  const raw = token.replace(/^relay_(ag|pa|ws|id)_/, "");
  const [header, payload] = raw.split(".");
  return {
    header: JSON.parse(Buffer.from(header, "base64url").toString("utf8")),
    payload: JSON.parse(Buffer.from(payload, "base64url").toString("utf8")),
  };
}

async function phaseAuth() {
  const jwks = await call("GET", `${RELAYAUTH}/.well-known/jwks.json`);
  must(jwks.status === 200 && Array.isArray(jwks.json?.keys) && jwks.json.keys.length > 0, `jwks status=${jwks.status}`);
  const kids = jwks.json.keys.map((key) => key.kid);
  pass("auth.jwks", `keys=${kids.length} algs=${[...new Set(jwks.json.keys.map((k) => k.alg))].join(",")}`);

  // A control-plane-issued RelayHistory session must authenticate at
  // RelayHistory; a tampered one must not.
  const session = await historySession(state.a, "sync");
  const ok = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: session.accessToken });
  must(ok.status === 200, `issued RelayHistory token status=${ok.status}`);
  const bogus = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: `${session.accessToken.slice(0, -4)}AAAA` });
  must(bogus.status === 401, `tampered RelayHistory token status=${bogus.status}`);
  const none = await call("GET", `${HISTORY}/v1/delivery/limits`);
  must(none.status === 401, `anonymous RelayHistory status=${none.status}`);
  let kidDetail = "opaque_token";
  try {
    const parts = jwtParts(session.accessToken);
    kidDetail = `jwt_kid_in_jwks=${kids.includes(parts.header.kid)} aud=${parts.payload.aud}`;
  } catch {
    // RelayHistory session tokens may be opaque; the assertion check below
    // covers the RelayAuth signature path.
  }
  pass("auth.relayhistory_token", `issued=${ok.status} tampered=${bogus.status} anonymous=${none.status} ${kidDetail}`);

  // Mint the same RelayAuth assertion the control plane mints, verify its
  // RS256 signature against the served JWKS here, then exchange it at
  // RelayHistory. The RelayAuth API key is read from the pod's own mount.
  const relayauthKey = readFileSync(RELAYAUTH_KEY_FILE, "utf8").trim();
  const historyOrigin = session.baseUrl;
  const minted = await call("POST", `${RELAYAUTH}/v1/tokens/relayhistory-assertion`, {
    headers: { "x-api-key": relayauthKey },
    body: {
      orgId: state.a.organizationId,
      workspaceId: state.a.workspaceId,
      sponsorId: state.a.ownerUserId,
      scopes: ["rth:read"],
      expiresIn: 60,
      historyOrigin,
      metadata: { productId: "selfhost-control-plane", purpose: "relayhistory-login", requestedMode: "read", grantedMode: "read", label: `e2e-${state.marker}` },
    },
  });
  must(minted.status === 200 || minted.status === 201, `relayauth assertion status=${minted.status}`);
  const assertion = minted.json.accessToken;
  const raw = assertion.replace(/^relay_(ag|pa|ws|id)_/, "");
  const [h64, p64, s64] = raw.split(".");
  const header = JSON.parse(Buffer.from(h64, "base64url").toString("utf8"));
  const claims = JSON.parse(Buffer.from(p64, "base64url").toString("utf8"));
  const jwk = jwks.json.keys.find((key) => key.kid === header.kid);
  must(jwk, "assertion kid is not in the JWKS");
  const signatureOk = cryptoVerify(
    "RSA-SHA256",
    Buffer.from(`${h64}.${p64}`),
    createPublicKey({ key: jwk, format: "jwk" }),
    Buffer.from(s64, "base64url"),
  );
  must(signatureOk, "assertion signature does not verify against the JWKS");
  must(
    claims.org === state.a.organizationId && claims.wks === state.a.workspaceId &&
      (claims.aud === historyOrigin || (Array.isArray(claims.aud) && claims.aud[0] === historyOrigin)),
    "assertion claims do not match the tenant",
  );
  const exchanged = await call("POST", `${HISTORY}/v1/cli/login`, { body: { agentRelayToken: assertion } });
  must(exchanged.status === 200 && typeof exchanged.json?.accessToken === "string", `assertion exchange status=${exchanged.status}`);
  const tamperedSig = `${assertion.slice(0, assertion.lastIndexOf(".") + 1)}${Buffer.from(randomBytes(256)).toString("base64url")}`;
  const tamperedExchange = await call("POST", `${HISTORY}/v1/cli/login`, { body: { agentRelayToken: tamperedSig } });
  must(tamperedExchange.status === 401 || tamperedExchange.status === 403, `tampered assertion status=${tamperedExchange.status}`);
  pass(
    "auth.relayauth_assertion",
    `alg=${header.alg} kid_in_jwks=true signature_valid=true aud=${historyOrigin} exchange=${exchanged.status} tampered_exchange=${tamperedExchange.status}`,
  );

  // A structurally valid but unsigned/forged assertion must also fail.
  const forged = await call("POST", `${HISTORY}/v1/cli/login`, {
    body: { agentRelayToken: "eyJhbGciOiJSUzI1NiIsImtpZCI6ImZvcmdlZCJ9.eyJzdWIiOiJ4In0.c2ln" },
  });
  must(forged.status >= 400 && forged.status < 500, `forged assertion status=${forged.status}`);
  pass("auth.relayhistory_rejects_forged_assertion", `status=${forged.status}`);

  // Control-plane access tokens: valid works, revoked/garbage fails.
  const who = await call("GET", `${API}/api/v1/auth/whoami`, { token: state.a.accessToken });
  const garbage = await call("GET", `${API}/api/v1/auth/whoami`, { token: "sh_at_invalid" });
  must(who.status === 200 && garbage.status === 401, `whoami=${who.status} garbage=${garbage.status}`);
  pass("auth.control_plane_token", `valid=${who.status} invalid=${garbage.status}`);

  // The Relaycast workspace key the control plane resolves authenticates at
  // Relaycast; a wrong key does not.
  const rcOk = await call("GET", `${RELAYCAST}/v1/agents`, { token: state.a.relaycastKey });
  const rcBad = await call("GET", `${RELAYCAST}/v1/agents`, { token: `rk_live_${"0".repeat(32)}` });
  must(rcOk.status === 200 && rcBad.status === 401, `relaycast resolved=${rcOk.status} wrong=${rcBad.status}`);
  pass("auth.relaycast_key", `resolved_key=${rcOk.status} wrong_key=${rcBad.status}`);
}

// ---------------------------------------------------------------- erasure

async function phaseErasure() {
  const { sessionId, originId } = state.session;
  const sync = await historySession(state.a, "sync");
  const erase = await call("POST", `${HISTORY}/v1/delivery/sessions/selection`, {
    token: sync.accessToken,
    body: {
      account_id: accountId(state.a),
      origin_id: originId,
      sessions: [{ source: SOURCE, session_id: sessionId }],
      enabled: false,
    },
  });
  must(erase.status === 200, `erase status=${erase.status} error=${errorCode(erase)}`);
  pass("erasure.request", `status=${erase.status} session=${sessionId}`);

  const list = await dashboardList(state.a, state.a.workspaceId);
  must(list.status === 200 && !list.json.items.some((item) => item.sessionId === sessionId), "list still returns the erased session");
  const search = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(search.status === 200 && !search.json.items.some((item) => item.sessionId === sessionId), "search still returns the erased session");
  const replay = await dashboardEvents(state.a, state.a.workspaceId, sessionId);
  const remaining = replay.status === 200 ? markerEvents(replay.json.events).length : 0;
  must(remaining === 0, `replay still returns ${remaining} events`);
  const read = await historySession(state.a, "read");
  const direct = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker })}`,
    { token: read.accessToken },
  );
  must(direct.status === 200 && !direct.json.sessions.some((item) => item.sessionId === sessionId), "relayhistory search still returns it");
  pass("erasure.verified", `list_absent=true search_absent=true replay_status=${replay.status} replay_events=0 relayhistory_absent=true`);

  // The receipt survives erasure, so a stale client retry of the original
  // batch must replay that receipt without resurrecting the session.
  const stale = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: buildBatch() });
  must(stale.status === 200 && stale.json?.receiptId === state.session.receiptId,
    `stale retry status=${stale.status} same_receipt=${stale.json?.receiptId === state.session.receiptId}`);
  const after = await eventsDirect(read.accessToken, state.a, sessionId);
  const resurrected = after.status === 200 ? markerEvents(after.json.events).length : 0;
  const afterList = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(resurrected === 0 && !afterList.json.items.some((item) => item.sessionId === sessionId),
    `stale retry resurrected ${resurrected} events`);
  pass("erasure.stale_retry_no_resurrection", `receipt=${stale.json.receiptId} events_after=0 search_absent=true`);
  state.session.erased = true;
}

// ---------------------------------------------------------------- public

async function phaseIssuePublic() {
  // Hands the caller a short-lived read session so it can repeat an
  // authenticated call through the public ingress from outside the cluster.
  const read = await historySession(state.a, "read");
  state.publicHistoryToken = read.accessToken;
  pass("public.issue_history_session", `base_url=${read.baseUrl}`);
}

async function phaseMint96bulls() {
  // The 96bulls courier's RelayAuth mode only accepts an HTTPS or loopback
  // RelayAuth URL, so mint the same origin-bound, machine-bound assertion here
  // (RelayAuth is reachable from this pod) and hand it to a fixed-token pass.
  // RelayAuth caps assertions at 60 seconds; the caller uses it immediately.
  const bulls = state.bulls;
  must(bulls?.orgId && bulls?.workspaceId && bulls?.origin && bulls?.machineId, "missing 96bulls tenant parameters");
  const relayauthKey = readFileSync(RELAYAUTH_KEY_FILE, "utf8").trim();
  const minted = await call("POST", `${RELAYAUTH}/v1/tokens/relayhistory-assertion`, {
    headers: { "x-api-key": relayauthKey },
    body: {
      orgId: bulls.orgId,
      workspaceId: bulls.workspaceId,
      machineId: bulls.machineId,
      sponsorId: `e2e-${state.marker}`,
      scopes: ["rth:sync", "rth:read"],
      expiresIn: 60,
      historyOrigin: bulls.origin,
    },
  });
  must(minted.status === 201 && typeof minted.json?.accessToken === "string", `96bulls assertion mint status=${minted.status}`);
  state.bullsAssertion = minted.json.accessToken;
  pass("pipeline.mint_assertion", `org=${bulls.orgId} workspace=${bulls.workspaceId} machine=${bulls.machineId} aud=${bulls.origin} ttl=60s`);
}

async function phaseCleanup() {
  for (const label of ["a", "b"]) {
    const tenant = state[label];
    if (!tenant?.relaycastWorkspaceId) continue;
    const response = await call("DELETE", `${RELAYCAST}/internal/workspaces/${tenant.relaycastWorkspaceId}`, {
      token: secrets.relaycastInternalSecret,
    });
    must(response.status === 204, `delete relaycast workspace ${label} status=${response.status}`);
    pass(`cleanup.relaycast_${label}`, `deleted=${tenant.relaycastWorkspaceId}`);
  }
}

const phases = {
  bootstrap: phaseBootstrap,
  messaging: phaseMessaging,
  delivery: phaseDelivery,
  reads: phaseReads,
  isolation: phaseIsolation,
  "durability-history": phaseDurabilityHistory,
  "durability-relaycast": phaseDurabilityRelaycast,
  auth: phaseAuth,
  erasure: phaseErasure,
  "issue-public": phaseIssuePublic,
  "mint-96bulls": phaseMint96bulls,
  cleanup: phaseCleanup,
};

try {
  const run = phases[phase];
  if (!run) throw new CheckError(`unknown phase ${phase}`);
  await run();
} catch (error) {
  fail(`${phase}.error`, error instanceof CheckError ? error.message : `unexpected: ${error?.message ?? error}`);
}
process.stdout.write(JSON.stringify({ state, proofs }));
