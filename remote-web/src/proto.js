// Pitwall Remote protocol v1 (see docs/remote-protocol.md).
import { ed25519, x25519 } from '@noble/curves/ed25519.js';
import { chacha20poly1305 } from '@noble/ciphers/chacha.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { randomBytes } from '@noble/hashes/utils.js';

const te = new TextEncoder();
const td = new TextDecoder();

export const b64 = (bytes) => {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
export const unb64 = (str) => {
  const s = atob(str.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((str.length + 3) % 4));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
};
const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const str = (s) => te.encode(s);
const u64be = (n) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(n)); return b; };

export function deviceId(signPub) { return b64(sha256(signPub)).slice(0, 16); }

/** Creates a new device identity. */
export function newIdentity(name) {
  const signPriv = ed25519.utils.randomSecretKey();
  const dhPriv = x25519.utils.randomSecretKey();
  const signPub = ed25519.getPublicKey(signPriv);
  return {
    name, id: deviceId(signPub),
    signPriv: b64(signPriv), signPub: b64(signPub),
    dhPriv: b64(dhPriv), dhPub: b64(x25519.getPublicKey(dhPriv)),
  };
}

export function sign(identity, message) { return ed25519.sign(message, unb64(identity.signPriv)); }

/** Builds the encrypted pairing request for a QR payload. */
export function pairRequest(identity, qr) {
  const eph = x25519.utils.randomSecretKey();
  const shared = x25519.getSharedSecret(eph, unb64(qr.mac.dh));
  const k = hkdf(sha256, shared, unb64(qr.secret), str('pitwall-pair-v1'), 32);
  const device = { id: identity.id, name: identity.name, sign: identity.signPub, dh: identity.dhPub };
  const box = chacha20poly1305(k, new Uint8Array(12), str('pitwall-pair-v1'))
    .encrypt(te.encode(JSON.stringify({ device, ts: Date.now() })));
  return { type: 'pair', eph: b64(x25519.getPublicKey(eph)), box: b64(box) };
}

export function verifyPaired(identity, qr, msg) {
  const m = cat(str('pitwall-paired-v1'), unb64(identity.signPub), unb64(identity.dhPub));
  return ed25519.verify(unb64(msg.sig), m, unb64(qr.mac.sign));
}

/** Starts a session: returns the hello message and a function to finish it. */
export function hello(identity, mac) {
  const eph = x25519.utils.randomSecretKey();
  const ephPub = x25519.getPublicKey(eph);
  const ts = Date.now();
  const sig = sign(identity, cat(str('pitwall-hello-v1'), str(mac.id), ephPub, u64be(ts)));
  const msg = { type: 'hello', device: identity.id, eph: b64(ephPub), ts, sig: b64(sig) };
  const finish = (welcome) => {
    const macEph = unb64(welcome.eph);
    const ok = ed25519.verify(unb64(welcome.sig),
      cat(str('pitwall-welcome-v1'), str(identity.id), ephPub, macEph), unb64(mac.sign));
    if (!ok) throw new Error('Mac signature did not verify');
    const shared = x25519.getSharedSecret(eph, macEph);
    const okm = hkdf(sha256, shared, sha256(cat(ephPub, macEph)), str('pitwall-session-v1'), 64);
    return new Session(okm.slice(0, 32), okm.slice(32, 64));
  };
  return { msg, finish };
}

/** An established, encrypted session (phone side). */
export class Session {
  constructor(sendKey, recvKey) {
    this.sendKey = sendKey; this.recvKey = recvKey;
    this.sendCounter = 0n; this.recvCounter = 0n;
  }
  seal(obj) {
    this.sendCounter += 1n;
    const nonce = cat(new Uint8Array(4), u64be(this.sendCounter));
    const ct = chacha20poly1305(this.sendKey, nonce, Uint8Array.of(1)).encrypt(te.encode(JSON.stringify(obj)));
    return cat(u64be(this.sendCounter), ct);
  }
  open(frame) {
    const counter = new DataView(frame.buffer, frame.byteOffset, 8).getBigUint64(0);
    if (counter <= this.recvCounter) throw new Error('replayed frame');
    const nonce = cat(new Uint8Array(4), frame.slice(0, 8));
    const pt = chacha20poly1305(this.recvKey, nonce, Uint8Array.of(2)).decrypt(frame.slice(8));
    this.recvCounter = counter;
    return JSON.parse(td.decode(pt));
  }
}

/** Signs an approval decision so the Mac can attribute and verify it. */
export function signedDecision(identity, approval, decision) {
  const d = { approval, decision, ts: Date.now() };
  const json = JSON.stringify(d);
  return { decision: d, json, sig: b64(sign(identity, cat(str('pitwall-decision-v1'), te.encode(json)))) };
}

export { randomBytes };
