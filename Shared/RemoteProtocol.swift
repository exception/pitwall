import Foundation
import CryptoKit

/// Pitwall Remote protocol v1, shared by the Mac app and the iOS app
/// (see docs/remote-protocol.md).
enum RemoteCrypto {
    static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func deviceID(signPublic: Data) -> String {
        String(b64(Data(SHA256.hash(data: signPublic))).prefix(16))
    }

    static func u64be(_ n: UInt64) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }

    static func hkdf(_ ikm: SymmetricKey, salt: Data, info: String, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }
}

/// An established, encrypted session. `phone→mac` frames use direction 1,
/// `mac→phone` frames use direction 2.
final class RemoteSession {
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private let sendDir: UInt8
    private let recvDir: UInt8
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(sendKey: Data, recvKey: Data, isPhone: Bool) {
        self.sendKey = SymmetricKey(data: sendKey)
        self.recvKey = SymmetricKey(data: recvKey)
        sendDir = isPhone ? 1 : 2
        recvDir = isPhone ? 2 : 1
    }

    func seal(_ json: Data) throws -> Data {
        sendCounter += 1
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 4) + RemoteCrypto.u64be(sendCounter))
        let box = try ChaChaPoly.seal(json, using: sendKey, nonce: nonce, authenticating: Data([sendDir]))
        return RemoteCrypto.u64be(sendCounter) + box.ciphertext + box.tag
    }

    func open(_ frame: Data) throws -> Data {
        let frame = Data(frame)
        guard frame.count > 8 + 16 else { throw RemoteError.badFrame }
        let counter = frame.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter > recvCounter else { throw RemoteError.replay }
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 4) + frame.prefix(8))
        let body = frame.dropFirst(8)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16))
        let pt = try ChaChaPoly.open(box, using: recvKey, authenticating: Data([recvDir]))
        recvCounter = counter
        return pt
    }
}

enum RemoteError: Error, LocalizedError {
    case badFrame, replay, unknownDevice, badSignature, stale, noOffer, badPair, badQR, macSignature

    var errorDescription: String? {
        switch self {
        case .unknownDevice: return "This phone isn't paired with that Mac anymore."
        case .noOffer: return "The pairing code expired. Show a new one in Pitwall › Settings › Pitwall Remote."
        case .badQR: return "That isn't a Pitwall pairing code."
        case .macSignature: return "Couldn't verify the Mac's identity."
        case .stale: return "Your phone's clock is too far off."
        default: return "Secure connection failed (\(self))."
        }
    }
}

/// What a QR code carries.
struct PairingOffer: Codable, Equatable {
    struct Mac: Codable, Equatable { var id: String; var name: String; var sign: String; var dh: String }
    var v: Int
    var mac: Mac
    var secret: String
    var addrs: [String]

    /// Parses `pitwall://pair#<b64>` or `http(s)://…/#pair=<b64>`.
    static func parse(_ url: URL) -> PairingOffer? {
        guard var frag = url.fragment else { return nil }
        if frag.hasPrefix("pair=") { frag.removeFirst(5) }
        guard let d = RemoteCrypto.unb64(frag) else { return nil }
        return try? JSONDecoder().decode(PairingOffer.self, from: d)
    }
}

/// Client (phone) side of pairing and the session handshake.
enum RemoteClientHandshake {
    struct Identity {
        let sign: Curve25519.Signing.PrivateKey
        let dh: Curve25519.KeyAgreement.PrivateKey
        var id: String { RemoteCrypto.deviceID(signPublic: sign.publicKey.rawRepresentation) }
    }

    static func pairRequest(_ me: Identity, name: String, offer: PairingOffer) throws -> [String: Any] {
        guard let macDH = RemoteCrypto.unb64(offer.mac.dh), let secret = RemoteCrypto.unb64(offer.secret) else { throw RemoteError.badQR }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: macDH))
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret, sharedInfo: Data("pitwall-pair-v1".utf8), outputByteCount: 32)
        let device: [String: Any] = ["id": me.id, "name": name,
                                     "sign": RemoteCrypto.b64(me.sign.publicKey.rawRepresentation),
                                     "dh": RemoteCrypto.b64(me.dh.publicKey.rawRepresentation)]
        let pt = try JSONSerialization.data(withJSONObject: ["device": device, "ts": Int(Date().timeIntervalSince1970 * 1000)])
        let box = try ChaChaPoly.seal(pt, using: k, nonce: ChaChaPoly.Nonce(data: Data(count: 12)), authenticating: Data("pitwall-pair-v1".utf8))
        return ["type": "pair", "eph": RemoteCrypto.b64(eph.publicKey.rawRepresentation), "box": RemoteCrypto.b64(box.ciphertext + box.tag)]
    }

    static func verifyPaired(_ me: Identity, offer: PairingOffer, reply: [String: Any]) -> Bool {
        guard reply["type"] as? String == "paired", let sigS = reply["sig"] as? String, let sig = RemoteCrypto.unb64(sigS),
              let macSign = RemoteCrypto.unb64(offer.mac.sign),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: macSign) else { return false }
        let msg = Data("pitwall-paired-v1".utf8) + me.sign.publicKey.rawRepresentation + me.dh.publicKey.rawRepresentation
        return pub.isValidSignature(sig, for: msg)
    }

    /// Returns the hello message and a function that completes the handshake.
    static func hello(_ me: Identity, mac: PairingOffer.Mac) throws -> ([String: Any], ([String: Any]) throws -> RemoteSession) {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let sig = try me.sign.signature(for: Data("pitwall-hello-v1".utf8) + Data(mac.id.utf8) + ephPub + RemoteCrypto.u64be(ts))
        let msg: [String: Any] = ["type": "hello", "device": me.id, "eph": RemoteCrypto.b64(ephPub), "ts": ts, "sig": RemoteCrypto.b64(sig)]
        let finish: ([String: Any]) throws -> RemoteSession = { welcome in
            if let e = welcome["error"] as? String, e.contains("unknownDevice") { throw RemoteError.unknownDevice }
            guard let macEphS = welcome["eph"] as? String, let macEph = RemoteCrypto.unb64(macEphS),
                  let wsigS = welcome["sig"] as? String, let wsig = RemoteCrypto.unb64(wsigS),
                  let macSign = RemoteCrypto.unb64(mac.sign) else { throw RemoteError.badPair }
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: macSign)
            guard pub.isValidSignature(wsig, for: Data("pitwall-welcome-v1".utf8) + Data(me.id.utf8) + ephPub + macEph) else {
                throw RemoteError.macSignature
            }
            let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: macEph))
            let ikm = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
            let okm = RemoteCrypto.hkdf(ikm, salt: Data(SHA256.hash(data: ephPub + macEph)), info: "pitwall-session-v1", count: 64)
            return RemoteSession(sendKey: okm.prefix(32), recvKey: okm.suffix(32), isPhone: true)
        }
        return (msg, finish)
    }

    /// A signed approval decision: returns (json, signature).
    static func signedDecision(_ me: Identity, approval: String, decision: String) throws -> (String, String) {
        let obj: [String: Any] = ["approval": approval, "decision": decision, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let sig = try me.sign.signature(for: Data("pitwall-decision-v1".utf8) + Data(json.utf8))
        return (json, RemoteCrypto.b64(sig))
    }
}
