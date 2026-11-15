import Foundation
import CryptoKit
import Network
import Combine
import UIKit

// MARK: - State models (decoded from the Mac's `state` event)

struct RAgent: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var state: String
    var since: Date
    var terminal: Bool
    var message: String?
    var task: String?
    var branch: String?
    var cost: Double?
    var context: Int?
    var model: String?
    var added: Int?
    var removed: Int?
    var boardID: String
    var boardName: String

    var needsYou: Bool { state == "waiting" }
}

struct RBoard: Identifiable, Hashable {
    var id: String
    var name: String
    var color: Int
    var agents: [RAgent]
}

struct RApproval: Identifiable, Hashable {
    var id: String
    var tile: String
    var tileName: String
    var board: String
    var tool: String
    var summary: String
    var detail: String?
    var canAlways: Bool
    var at: Date
}

struct RTimelineEvent: Identifiable, Hashable {
    var id = UUID()
    var kind: String
    var text: String
    var at: Date
}

/// The Mac this phone is paired with (public info only).
struct PairedMac: Codable, Equatable {
    var mac: PairingOffer.Mac
    var addrs: [String]
}

// MARK: - Client

/// Connects to the paired Mac, keeps state in sync, and performs actions.
@MainActor
final class RemoteClient: ObservableObject {
    enum Phase: Equatable { case unpaired, connecting, connected, offline(String) }

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var paired: PairedMac?
    @Published private(set) var boards: [RBoard] = []
    @Published private(set) var approvals: [RApproval] = []
    @Published private(set) var macName = ""
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName") }
    }

    private var identity: RemoteClientHandshake.Identity
    private var task: URLSessionWebSocketTask?
    private var session: RemoteSession?
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<Any, Error>] = [:]
    private var terminals: [String: TerminalModel] = [:]
    private var retry = 1.0
    private var browser: NWBrowser?
    private let urlSession = URLSession(configuration: .default)

    init() {
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
        identity = Self.loadIdentity()
        if let d = UserDefaults.standard.data(forKey: "pairedMac"), let m = try? JSONDecoder().decode(PairedMac.self, from: d) {
            paired = m
            macName = m.mac.name
            phase = .connecting
        }
    }

    var agents: [RAgent] { boards.flatMap(\.agents) }
    var attention: [RAgent] { agents.filter { $0.state == "waiting" || $0.state == "error" || $0.state == "done" } }
    var badge: Int {
        let pendingTiles = Set(approvals.map(\.tile))
        return approvals.count + agents.filter { $0.state == "waiting" && !pendingTiles.contains($0.id) }.count
    }

    // MARK: Identity (Keychain)

    private static func loadIdentity() -> RemoteClientHandshake.Identity {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pitwall.remote",
                                kSecAttrAccount as String: "phone-identity", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data, raw.count == 64,
           let s = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw.prefix(32)),
           let d = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw.suffix(32)) {
            return .init(sign: s, dh: d)
        }
        let id = RemoteClientHandshake.Identity(sign: .init(), dh: .init())
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pitwall.remote",
                                  kSecAttrAccount as String: "phone-identity"]
        SecItemDelete(add as CFDictionary)
        add[kSecValueData as String] = id.sign.rawRepresentation + id.dh.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return id
    }

    // MARK: Pairing

    func pair(with url: URL) async throws {
        guard let offer = PairingOffer.parse(url) else { throw RemoteError.badQR }
        var lastError: Error = RemoteError.badPair
        for addr in offer.addrs {
            do {
                let t = urlSession.webSocketTask(with: URL(string: "ws://\(addr)")!)
                t.resume()
                let req = try RemoteClientHandshake.pairRequest(identity, name: deviceName, offer: offer)
                try await t.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)))
                let reply = try await Self.receiveJSON(t, timeout: 8)
                t.cancel(with: .normalClosure, reason: nil)
                if let e = reply["error"] as? String { throw e.contains("noOffer") ? RemoteError.noOffer : RemoteError.badPair }
                guard RemoteClientHandshake.verifyPaired(identity, offer: offer, reply: reply) else { throw RemoteError.macSignature }
                let m = PairedMac(mac: offer.mac, addrs: [addr] + offer.addrs.filter { $0 != addr })
                paired = m
                macName = m.mac.name
                UserDefaults.standard.set(try JSONEncoder().encode(m), forKey: "pairedMac")
                connect()
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    func unpair() {
        disconnect()
        paired = nil
        boards = []; approvals = []
        UserDefaults.standard.removeObject(forKey: "pairedMac")
        phase = .unpaired
    }

    // MARK: Connection

    func connect() {
        guard let paired, session == nil, task == nil else { return }
        phase = .connecting
        startBrowsing()
        Task { await connect(to: paired) }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        for (_, w) in waiters { w.resume(throwing: CancellationError()) }
        waiters.removeAll()
    }

    private func connect(to m: PairedMac) async {
        for addr in m.addrs {
            let t = urlSession.webSocketTask(with: URL(string: "ws://\(addr)")!)
            t.resume()
            do {
                let (hello, finish) = try RemoteClientHandshake.hello(identity, mac: m.mac)
                try await t.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: hello), as: UTF8.self)))
                let welcome = try await Self.receiveJSON(t, timeout: 6)
                if let e = welcome["error"] as? String {
                    if e.contains("unknownDevice") { unpair(); phase = .offline("This phone was removed from Pitwall. Pair it again."); return }
                    throw RemoteError.badPair
                }
                session = try finish(welcome)
                task = t
                retry = 1
                phase = .connected
                if m.addrs.first != addr { updateAddrs([addr] + m.addrs.filter { $0 != addr }) }
                receiveLoop(t)
                if let s = try? await call("state.get") as? [String: Any] { apply(state: s) }
                for tile in terminals.keys { _ = try? await call("terminal.subscribe", ["tile": tile]) }
                return
            } catch {
                t.cancel(with: .goingAway, reason: nil)
            }
        }
        phase = .offline("Can't reach \(m.mac.name). Make sure Pitwall is running and your phone is on the same network.")
        scheduleRetry()
    }

    private func scheduleRetry() {
        let delay = retry
        retry = min(retry * 2, 20)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if session == nil, let p = paired { await connect(to: p) }
        }
    }

    private func updateAddrs(_ a: [String]) {
        guard var m = paired else { return }
        m.addrs = Array(NSOrderedSet(array: a).array as! [String]).prefix(6).map { $0 }
        paired = m
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: "pairedMac") }
    }

    /// Finds the Mac on the network if its address changed (Bonjour).
    private func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_pitwall._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                let c = NWConnection(to: r.endpoint, using: .tcp)
                c.stateUpdateHandler = { st in
                    guard case .ready = st, case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint else { return }
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    c.cancel()
                    guard !h.contains(":") else { return } // IPv4 only
                    Task { @MainActor in
                        guard let self, let m = self.paired, !m.addrs.contains("\(h):\(port)") else { return }
                        self.updateAddrs(m.addrs + ["\(h):\(port)"])
                    }
                }
                c.start(queue: .main)
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private static func receiveJSON(_ t: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { g in
            g.addTask {
                let m = try await t.receive()
                var data = Data()
                switch m {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            g.addTask { try await Task.sleep(for: .seconds(timeout)); throw URLError(.timedOut) }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .failure:
                    self.task = nil; self.session = nil
                    self.phase = .offline("Reconnecting to \(self.macName)…")
                    self.scheduleRetry()
                case .success(let m):
                    if case .data(let d) = m, let s = self.session, let pt = try? s.open(d),
                       let obj = try? JSONSerialization.jsonObject(with: pt) as? [String: Any] {
                        self.handle(obj)
                    }
                    self.receiveLoop(t)
                }
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int, let w = waiters.removeValue(forKey: id) {
            if let e = obj["error"] as? String { w.resume(throwing: NSError(domain: "pitwall", code: 1, userInfo: [NSLocalizedDescriptionKey: e])) }
            else { w.resume(returning: obj["result"] ?? NSNull()) }
            return
        }
        switch obj["event"] as? String {
        case "state":
            if let s = obj["data"] as? [String: Any] { apply(state: s) }
        case "terminal":
            if let d = obj["data"] as? [String: Any], let tile = d["tile"] as? String, let b = d["data"] as? String,
               let bytes = RemoteCrypto.unb64(b), let model = terminals[tile] {
                if d["snapshot"] as? Bool == true {
                    model.reset()
                    if let c = d["cols"] as? Int, let r = d["rows"] as? Int { model.resize(cols: c, rows: r) }
                }
                model.write(bytes)
            }
        default: break
        }
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard let t = task, let s = session else { throw URLError(.notConnectedToInternet) }
        let id = nextID
        nextID += 1
        let frame = try s.seal(try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]))
        return try await withCheckedThrowingContinuation { cont in
            waiters[id] = cont
            t.send(.data(frame)) { err in
                if let err { Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: err) } }
            }
        }
    }

    private func apply(state s: [String: Any]) {
        macName = s["mac"] as? String ?? macName
        let date = { (v: Any?) -> Date in Date(timeIntervalSince1970: ((v as? Double) ?? 0) / 1000) }
        boards = (s["boards"] as? [[String: Any]] ?? []).map { b in
            let bid = b["id"] as? String ?? "", bname = b["name"] as? String ?? ""
            return RBoard(id: bid, name: bname, color: b["color"] as? Int ?? 0, agents: (b["tiles"] as? [[String: Any]] ?? []).map { t in
                RAgent(id: t["id"] as? String ?? "", name: t["name"] as? String ?? "", kind: t["kind"] as? String ?? "",
                       state: t["state"] as? String ?? "idle", since: date(t["since"]), terminal: t["terminal"] as? Bool ?? false,
                       message: t["message"] as? String, task: t["task"] as? String, branch: t["branch"] as? String,
                       cost: t["cost"] as? Double, context: t["context"] as? Int, model: t["model"] as? String,
                       added: t["added"] as? Int, removed: t["removed"] as? Int, boardID: bid, boardName: bname)
            })
        }
        approvals = (s["inbox"] as? [[String: Any]] ?? []).map { a in
            RApproval(id: a["id"] as? String ?? "", tile: a["tile"] as? String ?? "", tileName: a["tileName"] as? String ?? "Agent",
                      board: a["board"] as? String ?? "", tool: a["tool"] as? String ?? "", summary: a["summary"] as? String ?? "",
                      detail: a["detail"] as? String, canAlways: a["always"] as? Bool ?? false, at: date(a["at"]))
        }
        UIApplication.shared.applicationIconBadgeNumber = badge
    }

    // MARK: Actions

    func decide(_ a: RApproval, _ decision: String) async throws {
        let (json, sig) = try RemoteClientHandshake.signedDecision(identity, approval: a.id, decision: decision)
        approvals.removeAll { $0.id == a.id } // optimistic
        try await call("inbox.decide", ["decision": json, "sig": sig])
    }

    func message(_ agent: RAgent, _ text: String) async throws -> String {
        (try await call("agent.message", ["tile": agent.id, "text": text]) as? String) ?? "sent"
    }

    func newAgent(board: String, task: String, worktree: Bool) async throws {
        try await call("agent.new", ["board": board, "task": task, "worktree": worktree])
    }

    func timeline(_ agent: RAgent) async throws -> [RTimelineEvent] {
        let list = try await call("timeline.get", ["tile": agent.id]) as? [[String: Any]] ?? []
        return list.map { RTimelineEvent(kind: $0["kind"] as? String ?? "", text: $0["text"] as? String ?? "",
                                         at: Date(timeIntervalSince1970: (($0["at"] as? Double) ?? 0) / 1000)) }.reversed()
    }

    func terminal(for agent: RAgent) -> TerminalModel {
        if let m = terminals[agent.id] { return m }
        let m = TerminalModel()
        terminals[agent.id] = m
        Task {
            if let r = try? await call("terminal.subscribe", ["tile": agent.id]) as? [String: Any] {
                m.resize(cols: r["cols"] as? Int ?? 80, rows: r["rows"] as? Int ?? 24)
            }
        }
        return m
    }

    func closeTerminal(_ agent: RAgent) {
        guard terminals.removeValue(forKey: agent.id) != nil else { return }
        Task { _ = try? await call("terminal.unsubscribe", ["tile": agent.id]) }
    }
}
