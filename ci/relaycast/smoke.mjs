// Relaycast live smoke client used by ci/relaycast/smoke.sh.
//   seed-anon  chart 0.1.0 (image 8.0.0): anonymous create, agents, a message
//   full       anonymous create refused; workspace key from the first-run
//              bootstrap (WORKSPACE_KEY_FILE); register -> node transport ->
//              DM -> RECEIVE + ack; observer stream; search
//   <label>    anything else: state survived (key, history, fresh receive)
// B is the base URL, STATE the file holding tokens between runs. Secrets and
// tokens are never printed.
import fs from 'node:fs';
const B = process.env.B || 'http://127.0.0.1:18787';
const mode = process.argv[2] || 'full';
const stateF = process.env.STATE;
if (!stateF) throw new Error('set STATE to a private file path');
let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : fail++; console.log((c ? 'PASS ' : 'FAIL ') + m); };
async function j(method, path, tok, body) {
  const r = await fetch(B + path, { method, headers: { 'content-type': 'application/json', ...(tok ? { authorization: 'Bearer ' + tok } : {}) }, body: body ? JSON.stringify(body) : undefined });
  let d; try { d = await r.json(); } catch { d = null; }
  return { s: r.status, d };
}
const wsUrl = (p) => B.replace(/^http/, 'ws') + p;
// Resolve once the socket opens; reject (and close it) on error or after 10s.
function opened(sock, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { sock.close(); reject(new Error(`${label}: WebSocket did not open within 10s`)); }, 10000);
    sock.onopen = () => { clearTimeout(timer); resolve(); };
    sock.onerror = () => { clearTimeout(timer); reject(new Error(`${label}: WebSocket error`)); };
  });
}

async function nodeReceive(agentTok, agentName, marker, send) {
  const nt = await j('POST', '/v1/agent/node-token', agentTok, {});
  ok(nt.s === 200 && nt.d?.data?.token?.startsWith('nt_live_'), `${agentName} node-token minted status=${nt.s}`);
  const { node_id, node_name, token } = nt.d.data;
  const sock = new WebSocket(wsUrl('/v1/node/ws?token=' + token));
  const frames = [];
  let registered;
  const reg = new Promise((r) => (registered = r));
  let got;
  const recv = new Promise((r) => (got = r));
  sock.onmessage = (e) => {
    const f = JSON.parse(String(e.data));
    frames.push(f.type);
    if (f.type === 'reply' && f.id === 'r1') registered(f.ok === true);
    if (f.type === 'deliver' && JSON.stringify(f.payload).includes(marker)) {
      sock.send(JSON.stringify({ v: 1, type: 'delivery.ack', agent: f.agent, up_to_seq: f.seq }));
      got(f);
    }
  };
  await opened(sock, 'node transport');
  sock.send(JSON.stringify({ v: 1, id: 'r1', type: 'node.register', node_id, name: node_name, capabilities: [], max_agents: 1, tags: ['implicit', 'direct'], version: 'kind-smoke/1' }));
  const regOk = await Promise.race([reg, new Promise((r) => setTimeout(() => r(false), 5000))]);
  ok(regOk, `${agentName} node.register acknowledged on /v1/node/ws`);
  await send();
  const f = await Promise.race([recv, new Promise((r) => setTimeout(() => r(null), 10000))]);
  ok(!!f, `${agentName} RECEIVED ${f ? f.payload.type : 'nothing'} deliver frame seq=${f?.seq} (frames seen: ${[...new Set(frames)].join(',')})`);
  sock.close();
  return f;
}

async function observerReceive(key, marker, send) {
  const ot = await j('POST', '/v1/observer-tokens', key, { name: 'tap', scopes: ['stream:read', 'messages:read', 'dms:read'], filters: { include_dms: true } });
  ok(ot.s === 201, 'observer token minted status=' + ot.s);
  const sock = new WebSocket(wsUrl('/v1/ws?token=' + ot.d.data.token));
  let got; const recv = new Promise((r) => (got = r));
  sock.onmessage = (e) => { const m = String(e.data); if (m.includes(marker)) got(JSON.parse(m)); };
  await opened(sock, 'observer stream');
  await new Promise((r) => setTimeout(r, 500));
  await send();
  const f = await Promise.race([recv, new Promise((r) => setTimeout(() => r(null), 10000))]);
  ok(!!f, 'observer stream RECEIVED ' + (f ? f.type : 'nothing'));
  sock.close();
}

if (mode === 'seed-anon') {
  // Chart 0.1.0 / image 8.0.0: anonymous create is the only way in.
  const ws = await j('POST', '/v1/workspaces', null, { name: 'v010' });
  ok(ws.s === 201, '0.1.0 anonymous create status=' + ws.s);
  const key = ws.d.data.api_key;
  const a = await j('POST', '/v1/agents', key, { name: 'alice' });
  const b = await j('POST', '/v1/agents', key, { name: 'bob' });
  ok(a.s === 201 && b.s === 201, `register alice=${a.s} bob=${b.s}`);
  const ch = await j('POST', '/v1/channels/general/messages', a.d.data.token, { text: 'pre-upgrade searchable-zebra-token' });
  ok(ch.s < 300, 'channel post on 0.1.0 status=' + ch.s);
  fs.writeFileSync(stateF, JSON.stringify({ key, at: a.d.data.token, bt: b.d.data.token }), { mode: 0o600 });
} else if (mode === 'readonly') {
  // Rollback target (8.0.0 image): data readable, writes still work.
  const st = JSON.parse(fs.readFileSync(stateF));
  const me = await j('GET', '/v1/workspace', st.key);
  ok(me.s === 200, 'workspace key valid after rollback status=' + me.s);
  const se = await j('GET', '/v1/search?q=zebra', st.key);
  ok(se.s === 200 && JSON.stringify(se.d).includes('zebra'), 'history readable after rollback status=' + se.s);
  const ch = await j('POST', '/v1/channels/general/messages', st.at, { text: 'during-rollback-zebra' });
  ok(ch.s < 300, 'write after rollback status=' + ch.s);
} else if (mode === 'full') {
  const internal = process.env.INTERNAL_SECRET_FILE ? fs.readFileSync(process.env.INTERNAL_SECRET_FILE, 'utf8').trim() : null;
  ok((await fetch(B + '/health')).status === 200, 'health 200');
  const anon = await j('POST', '/v1/workspaces', null, { name: 'anon' });
  ok(anon.s === 404, 'anonymous POST /v1/workspaces refused status=' + anon.s);
  let key;
  if (process.env.WORKSPACE_KEY_FILE) {
    key = fs.readFileSync(process.env.WORKSPACE_KEY_FILE, 'utf8').trim();
    ok(key.startsWith('rk_live_'), 'workspace key from first-run bootstrap');
  } else {
    const ws = await j('POST', '/internal/workspaces', internal, { name: 'kind-smoke' });
    ok(ws.s === 201, 'internal admin create status=' + ws.s);
    key = ws.d.data.api_key;
  }
  const a = await j('POST', '/v1/agents', key, { name: 'alice' });
  const b = await j('POST', '/v1/agents', key, { name: 'bob' });
  ok(a.s === 201 && b.s === 201, `register alice=${a.s} bob=${b.s}`);
  const at = a.d.data.token, bt = b.d.data.token;
  const legacy = await new Promise((r) => {
    const s = new WebSocket(wsUrl('/v1/ws?token=' + bt));
    const timer = setTimeout(() => { s.close(); r('timeout'); }, 10000);
    s.onopen = () => { clearTimeout(timer); s.close(); r('open'); };
    s.onerror = () => { clearTimeout(timer); r('refused'); };
  });
  ok(legacy === 'refused', 'agent token on /v1/ws refused (documented: use /v1/node/ws)');
  await nodeReceive(bt, 'bob', 'hello-bob-kind', async () => {
    const dm = await j('POST', '/v1/dm', at, { to: 'bob', text: 'hello-bob-kind' });
    ok(dm.s < 300, 'alice DM bob status=' + dm.s);
  });
  await observerReceive(key, 'observer-zebra', async () => {
    const ch = await j('POST', '/v1/channels/general/messages', at, { text: 'observer-zebra searchable-zebra-token' });
    ok(ch.s < 300, 'channel post status=' + ch.s);
  });
  const se = await j('GET', '/v1/search?q=zebra', key);
  ok(se.s === 200 && JSON.stringify(se.d).includes('zebra'), 'search finds the channel message status=' + se.s);
  fs.writeFileSync(stateF, JSON.stringify({ key, at, bt }), { mode: 0o600 });
} else {
  const st = JSON.parse(fs.readFileSync(stateF));
  ok((await fetch(B + '/health')).status === 200, `health 200 after ${mode}`);
  const me = await j('GET', '/v1/workspace', st.key);
  ok(me.s === 200, `workspace key valid after ${mode} status=${me.s}`);
  const se = await j('GET', '/v1/search?q=zebra', st.key);
  ok(se.s === 200 && JSON.stringify(se.d).includes('zebra'), `message history survives ${mode}`);
  const marker = 'post-' + mode + '-' + Date.now();
  await nodeReceive(st.bt, 'bob', marker, async () => {
    const dm = await j('POST', '/v1/dm', st.at, { to: 'bob', text: marker });
    ok(dm.s < 300, `agent token valid, DM after ${mode} status=${dm.s}`);
  });
}
console.log(`RESULT ${pass} pass / ${fail} fail`);
process.exit(fail ? 1 : 0);
