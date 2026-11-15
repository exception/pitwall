import Foundation
import CryptoKit
import Security

/// Pitwall Remote, Mac side: identity, paired devices and the server half of
/// pairing and the handshake. Shared protocol pieces live in
/// Shared/RemoteProtocol.swift.

/// The Mac's long-lived identity, kept in the Keychain.
final class RemoteIdentity {
    static let shared = RemoteIdentity()

    let signKey: Curve25519.Signing.PrivateKey
    let dhKey: Curve25519.KeyAgreement.PrivateKey
    var id: String { RemoteCrypto.deviceID(signPublic: signKey.publicKey.rawRepresentation) }
    var name: String { Host.current().localizedName ?? "Mac" }

    private init() {
        // An isolated test instance (PITWALL_HOME) gets its own identity.
        let account = "identity-" + RemoteCrypto.b64(Data(SHA256.hash(data: Data(PitwallPaths.support.path.utf8)))).prefix(12)
        if let raw = Keychain.read(account: String(account)), raw.count == 64,
           let s = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw.prefix(32)),
           let d = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw.suffix(32)) {
            signKey = s; dhKey = d
        } else {
            signKey = Curve25519.Signing.PrivateKey()
            dhKey = Curve25519.KeyAgreement.PrivateKey()
            Keychain.write(account: String(account), data: signKey.rawRepresentation + dhKey.rawRepresentation)
        }
    }

    var publicInfo: [String: String] {
        ["id": id, "name": name,
         "sign": RemoteCrypto.b64(signKey.publicKey.rawRepresentation),
         "dh": RemoteCrypto.b64(dhKey.publicKey.rawRepresentation)]
    }
}

enum Keychain {
    static let service = "dev.pitwall.remote"

    static func read(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(account: String, data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A paired phone (public keys only).
struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var sign: String
    var dh: String
    var addedAt = Date()
    var lastSeen: Date?

    var signKey: Curve25519.Signing.PublicKey? {
        RemoteCrypto.unb64(sign).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
}

/// Paired devices and the current pairing offer.
final class RemoteDevices: ObservableObject {
    static let shared = RemoteDevices()
    @Published private(set) var devices: [PairedDevice] = []
    /// The active one-time pairing secret and when it expires.
    @Published private(set) var offer: (secret: Data, expires: Date)?

    private var file: URL { PitwallPaths.support.appendingPathComponent("remote-devices.json") }

    private init() {
        if let d = try? Data(contentsOf: file), let list = try? Wire.decoder.decode([PairedDevice].self, from: d) { devices = list }
    }

    private func save() {
        if let d = try? Wire.encoder.encode(devices) { try? d.write(to: file, options: [.atomic, .completeFileProtection]) }
    }

    func newOffer() -> Data {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        offer = (bytes, Date().addingTimeInterval(600))
        return bytes
    }

    func cancelOffer() { offer = nil }

    func device(_ id: String) -> PairedDevice? { devices.first { $0.id == id } }

    func add(_ d: PairedDevice) {
        devices.removeAll { $0.id == d.id }
        devices.append(d)
        offer = nil // one-time
        save()
    }

    func revoke(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
        RemoteServer.shared.disconnect(deviceID: id)
    }

    func touch(_ id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].lastSeen = Date()
        save()
    }
}

/// Handshake and pairing logic (transport-independent, so the relay can reuse it).
enum RemoteHandshake {
    /// Handles `{type: pair}`. Returns the reply and the new device.
    static func pair(_ msg: [String: Any]) throws -> ([String: Any], PairedDevice) {
        guard let offer = RemoteDevices.shared.offer, offer.expires > Date() else { throw RemoteError.noOffer }
        guard let ephS = msg["eph"] as? String, let eph = RemoteCrypto.unb64(ephS),
              let boxS = msg["box"] as? String, let box = RemoteCrypto.unb64(boxS), box.count > 16,
              let ephKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph) else { throw RemoteError.badPair }
        let shared = try RemoteIdentity.shared.dhKey.sharedSecretFromKeyAgreement(with: ephKey)
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: offer.secret, sharedInfo: Data("pitwall-pair-v1".utf8), outputByteCount: 32)
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)), ciphertext: box.dropLast(16), tag: box.suffix(16))
        let pt = try ChaChaPoly.open(sealed, using: k, authenticating: Data("pitwall-pair-v1".utf8))
        guard let obj = try JSONSerialization.jsonObject(with: pt) as? [String: Any],
              let d = obj["device"] as? [String: Any],
              let sign = d["sign"] as? String, let dh = d["dh"] as? String,
              let signRaw = RemoteCrypto.unb64(sign), let dhRaw = RemoteCrypto.unb64(dh),
              signRaw.count == 32, dhRaw.count == 32 else { throw RemoteError.badPair }
        let id = RemoteCrypto.deviceID(signPublic: signRaw)
        let device = PairedDevice(id: id, name: (d["name"] as? String).map { String($0.prefix(60)) } ?? "Phone", sign: sign, dh: dh)
        let sig = try RemoteIdentity.shared.signKey.signature(for: Data("pitwall-paired-v1".utf8) + signRaw + dhRaw)
        return (["type": "paired", "sig": RemoteCrypto.b64(sig), "mac": RemoteIdentity.shared.publicInfo], device)
    }

    /// Handles `{type: hello}`. Returns the welcome reply and session.
    static func hello(_ msg: [String: Any]) throws -> ([String: Any], RemoteSession, PairedDevice) {
        guard let did = msg["device"] as? String, let device = RemoteDevices.shared.device(did),
              let pub = device.signKey else { throw RemoteError.unknownDevice }
        guard let ephS = msg["eph"] as? String, let eph = RemoteCrypto.unb64(ephS), eph.count == 32,
              let ts = (msg["ts"] as? NSNumber)?.uint64Value,
              let sigS = msg["sig"] as? String, let sig = RemoteCrypto.unb64(sigS) else { throw RemoteError.badPair }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        guard (now > ts ? now - ts : ts - now) < 5 * 60 * 1000 else { throw RemoteError.stale }
        let signed = Data("pitwall-hello-v1".utf8) + Data(RemoteIdentity.shared.id.utf8) + eph + RemoteCrypto.u64be(ts)
        guard pub.isValidSignature(sig, for: signed) else { throw RemoteError.badSignature }

        let macEph = Curve25519.KeyAgreement.PrivateKey()
        let macEphPub = macEph.publicKey.rawRepresentation
        let shared = try macEph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph))
        let ikm = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let okm = RemoteCrypto.hkdf(ikm, salt: Data(SHA256.hash(data: eph + macEphPub)), info: "pitwall-session-v1", count: 64)
        let session = RemoteSession(sendKey: okm.suffix(32), recvKey: okm.prefix(32), isPhone: false)
        let welcomeSig = try RemoteIdentity.shared.signKey.signature(
            for: Data("pitwall-welcome-v1".utf8) + Data(device.id.utf8) + eph + macEphPub)
        return (["type": "welcome", "eph": RemoteCrypto.b64(macEphPub), "sig": RemoteCrypto.b64(welcomeSig)], session, device)
    }

    /// Verifies a signed approval decision; returns (approvalID, decision).
    static func verifyDecision(json: String, sig: String, device: PairedDevice) -> (String, String)? {
        guard let pub = device.signKey, let s = RemoteCrypto.unb64(sig),
              pub.isValidSignature(s, for: Data("pitwall-decision-v1".utf8) + Data(json.utf8)),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let a = obj["approval"] as? String, let d = obj["decision"] as? String,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue,
              abs(Date().timeIntervalSince1970 * 1000 - ts) < 10 * 60 * 1000 else { return nil }
        return (a, d)
    }
}
