// Integration test against a running Pitwall: pair, handshake, call the API.
// usage: node test/live.mjs <pairing-url>
import { newIdentity, pairRequest, verifyPaired, hello, signedDecision, unb64 } from '../src/proto.js';

const url = new URL(process.argv[2].replace('pitwall://pair#', 'http://x/#pair='));
const qr = JSON.parse(new TextDecoder().decode(unb64(url.hash.replace('#pair=', ''))));
const wsURL = `ws://${qr.addrs[0]}`;
const me = newIdentity('Node test phone');

const once = (ws) => new Promise((res, rej) => { ws.onmessage = (e) => res(e.data); ws.onerror = rej; });

// 1. Pair
let ws = new WebSocket(wsURL);
await new Promise((r) => (ws.onopen = r));
ws.send(JSON.stringify(pairRequest(me, qr)));
const paired = JSON.parse(await once(ws));
if (paired.type !== 'paired' || !verifyPaired(me, qr, paired)) throw new Error('pairing failed: ' + JSON.stringify(paired));
console.log('✓ paired; Mac signature verified');
ws.close();

// 2. Handshake
ws = new WebSocket(wsURL);
ws.binaryType = 'arraybuffer';
await new Promise((r) => (ws.onopen = r));
const h = hello(me, qr.mac);
ws.send(JSON.stringify(h.msg));
const session = h.finish(JSON.parse(await once(ws)));
console.log('✓ session established; welcome signature verified');

// 3. Encrypted RPC
let nextId = 1;
const pending = new Map();
const events = [];
ws.onmessage = (e) => {
  const msg = session.open(new Uint8Array(e.data));
  if (msg.event) { events.push(msg); return; }
  pending.get(msg.id)?.(msg); pending.delete(msg.id);
};
const call = (method, params = {}) => new Promise((res) => {
  const id = nextId++; pending.set(id, res); ws.send(session.seal({ id, method, params }));
});
const state = await call('state.get');
console.log('✓ state.get:', state.result.boards.map((b) => `${b.name}(${b.tiles.length} tiles)`).join(', '), '| inbox:', state.result.inbox.length);

if (process.argv[3] === 'decide' && state.result.inbox[0]) {
  const d = signedDecision(me, state.result.inbox[0].id, 'allow');
  const r = await call('inbox.decide', { decision: d.json, sig: d.sig });
  console.log('✓ inbox.decide:', JSON.stringify(r.result ?? r.error));
  const bad = signedDecision(me, 'nope', 'allow');
  const r2 = await call('inbox.decide', { decision: bad.json, sig: bad.sig.replace(/^./, 'A') });
  console.log('✓ tampered decision rejected:', r2.error);
}

const term = state.result.boards.flatMap((b) => b.tiles).find((t) => t.terminal);
if (term) {
  const sub = await call('terminal.subscribe', { tile: term.id });
  await new Promise((r) => setTimeout(r, 800));
  const snap = events.find((e) => e.event === 'terminal' && e.data.snapshot);
  console.log('✓ terminal.subscribe:', JSON.stringify(sub.result), '| snapshot bytes:', snap ? unb64(snap.data.data).length : 0);
}
ws.close();
console.log('All remote protocol checks passed.');
