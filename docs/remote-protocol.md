# Pitwall Remote protocol (v1)

Pitwall Remote lets a paired phone see and answer a Mac's agents. The Mac is
the source of truth. Every message between a phone and a Mac is end-to-end
encrypted; a relay (later) only forwards opaque frames and can neither read nor
forge them. Approvals are additionally signed by the phone.

All byte strings in JSON are base64url without padding (`b64`).

## Identities

Every device (Mac or phone) has:

- `sign`: an Ed25519 key pair (identity, signatures)
- `dh`: an X25519 key pair (key agreement during pairing)
- `id`: `b64(SHA-256(sign.public))[0..16]`

The Mac keeps its private keys in the Keychain. Paired devices are stored on
the Mac as `{id, name, sign, dh, addedAt, lastSeen}` (public keys only).

## Pairing (out-of-band secret in a QR code)

The Mac shows a QR code with a one-time pairing payload, valid 10 minutes:

```json
{ "v": 1,
  "mac": { "id": "...", "name": "Erik's MacBook Pro", "sign": "<b64>", "dh": "<b64>" },
  "secret": "<b64 32 bytes>",
  "addrs": ["192.168.1.20:7458"] }
```

encoded as `http://<host>:7457/#pair=<b64(json)>` so the phone's camera opens
the web app directly.

The phone generates its identity, then sends over the WebSocket:

```json
{ "type": "pair", "eph": "<X25519 ephemeral public>", "box": "<b64 ciphertext>" }
```

- `k = HKDF-SHA256(ikm = X25519(eph, mac.dh), salt = secret, info = "pitwall-pair-v1", 32 bytes)`
- `box = ChaCha20-Poly1305(k, nonce = 12 zero bytes, aad = "pitwall-pair-v1", plaintext = JSON{device: {id, name, sign, dh}, ts})`

The key is single-use, so a zero nonce is safe. Only someone who saw the QR
code knows `secret`, so the Mac knows the request is genuine; only the Mac can
decrypt it. The Mac stores the device and replies:

```json
{ "type": "paired", "sig": "<Ed25519(mac.sign, "pitwall-paired-v1" || device.sign || device.dh)>" }
```

The phone verifies `sig` with `mac.sign` from the QR code. The secret is then
burned.

## Session handshake (every connection)

```
phone → mac  { "type": "hello", "device": id, "eph": <X25519 pub>, "ts": <unix ms>,
               "sig": Ed25519(device.sign, "pitwall-hello-v1" || mac.id || eph || ts) }
mac → phone  { "type": "welcome", "eph": <X25519 pub>,
               "sig": Ed25519(mac.sign, "pitwall-welcome-v1" || device.id || phoneEph || macEph) }
```

The Mac rejects unknown devices, bad signatures and `ts` more than 5 minutes
off. Both sides derive (ephemeral-ephemeral, so every session has fresh keys):

```
shared = X25519(myEph, theirEph)
okm    = HKDF-SHA256(ikm = shared, salt = SHA-256(phoneEph || macEph), info = "pitwall-session-v1", 64 bytes)
phone→mac key = okm[0..32], mac→phone key = okm[32..64]
```

## Frames

After the handshake every WebSocket message is binary:

```
counter (8 bytes, big-endian) || ChaCha20-Poly1305(key, nonce = 0x00000000 || counter, aad = direction, plaintext)
```

`direction` is the single byte `0x01` (phone→mac) or `0x02` (mac→phone).
Counters start at 1 and must strictly increase; anything else closes the
session. The plaintext is UTF-8 JSON:

- request: `{ "id": 7, "method": "inbox.decide", "params": {...} }`
- response: `{ "id": 7, "result": {...} }` or `{ "id": 7, "error": "..." }`
- event: `{ "event": "state", "data": {...} }`

## Methods

| method | params | result |
|---|---|---|
| `state.get` | – | boards, agents, inbox |
| `timeline.get` | `tile` | timeline events |
| `inbox.decide` | `decision`, `sig` | ok |
| `agent.message` | `tile`, `text` | ok |
| `agent.new` | `board`, `task`, `worktree` | tile id |
| `terminal.subscribe` | `tile` | ok; then `terminal` events |
| `terminal.unsubscribe` | `tile` | ok |

`inbox.decide.decision` is `{ "approval": id, "decision": "allow"|"always"|"deny", "ts": ms }`
and `sig = Ed25519(device.sign, "pitwall-decision-v1" || JSON(decision))`. The
Mac verifies it even inside the encrypted session, so decisions are attributable
and a compromised relay cannot approve anything.

## Events

- `state` – full state snapshot (boards, agents, inbox), sent on change (debounced).
- `terminal` – `{ tile, data: <b64 bytes>, snapshot: bool }`. The first event after
  `terminal.subscribe` is a VT snapshot of the screen and scrollback.
