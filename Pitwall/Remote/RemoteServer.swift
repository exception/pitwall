import Foundation
import Network
import Combine
import AppKit

/// Serves the Pitwall Remote web app (HTTP) and the encrypted protocol
/// (WebSocket) on the local network. The relay will reuse RemoteHandshake and
/// RemoteAPI unchanged; only the transport differs.
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    static let httpPort: UInt16 = 7457
    static let wsPort: UInt16 = 7458

    weak var controller: CanvasController?
    @Published private(set) var running = false
    @Published private(set) var connectedDevices: Set<String> = []

    private var http: NWListener?
    private var ws: NWListener?
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    private let queue = DispatchQueue(label: "pitwall.remote")
    private var bag = Set<AnyCancellable>()
    private var stateWork: DispatchWorkItem?

    private init() {
        // Push state to phones whenever boards, tiles or approvals change.
        Store.shared.objectWillChange.sink { [weak self] _ in self?.scheduleState() }.store(in: &bag)
        ApprovalCenter.shared.objectWillChange.sink { [weak self] _ in self?.scheduleState() }.store(in: &bag)
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        do {
            let httpL = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
            httpL.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
            httpL.start(queue: queue)
            http = httpL

            let params = NWParameters.tcp
            let wsOpts = NWProtocolWebSocket.Options()
            wsOpts.autoReplyPing = true
            wsOpts.maximumMessageSize = 1 << 20
            params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
            let wsL = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.wsPort)!)
            wsL.service = NWListener.Service(name: RemoteIdentity.shared.name, type: "_pitwall._tcp")
            wsL.newConnectionHandler = { [weak self] c in self?.accept(c) }
            wsL.start(queue: queue)
            ws = wsL
            running = true
        } catch {
            NSLog("pitwall: remote server failed: \(error)")
            stop()
        }
    }

    func stop() {
        http?.cancel(); ws?.cancel()
        http = nil; ws = nil
        queue.async { [weak self] in
            self?.connections.values.forEach { $0.close() }
            self?.connections.removeAll()
        }
        running = false
        connectedDevices = []
    }

    func disconnect(deviceID: String) {
        queue.async { [weak self] in
            self?.connections.values.filter { $0.device?.id == deviceID }.forEach { $0.close() }
        }
    }

    /// LAN addresses phones can use, best first.
    static var addresses: [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: ifa.ifa_name)
            let ip = String(cString: host)
            // Prefer Wi-Fi/Ethernet (en*), then Tailscale (utun with 100.x).
            if name.hasPrefix("en") { out.insert(ip, at: 0) } else if ip.hasPrefix("100.") { out.append(ip) }
        }
        return out
    }

    /// The URL encoded in the pairing QR code.
    func pairingURL() -> URL? {
        guard let host = Self.addresses.first else { return nil }
        let secret = RemoteDevices.shared.newOffer()
        let payload: [String: Any] = [
            "v": 1, "mac": RemoteIdentity.shared.publicInfo, "secret": RemoteCrypto.b64(secret),
            "addrs": Self.addresses.map { "\($0):\(Self.wsPort)" },
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        _ = host
        // The iPhone camera hands pitwall:// links straight to Pitwall Remote.
        return URL(string: "pitwall://pair#\(RemoteCrypto.b64(d))")
    }

    // MARK: HTTP: the web app's static files

    private func serveHTTP(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            guard let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            var path = parts.count > 1 ? String(parts[1]) : "/"
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            if path == "/" { path = "/index.html" }
            let name = (path as NSString).lastPathComponent
            let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css",
                         "webmanifest": "application/manifest+json", "png": "image/png", "svg": "image/svg+xml"]
            let ext = (name as NSString).pathExtension
            let file = Bundle.main.resourceURL?.appendingPathComponent("Remote").appendingPathComponent(name)
            var head: String
            var body = Data()
            if !name.contains(".."), let file, let d = try? Data(contentsOf: file), let type = types[ext] {
                body = d
                head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-cache\r\n"
            } else if name == "icon.png", let png = NSApp.applicationIconImage.pngData(size: 512) {
                body = png
                head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n"
            } else {
                body = Data("Not found".utf8)
                head = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
            }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    // MARK: WebSocket connections

    private func accept(_ c: NWConnection) {
        let rc = RemoteConnection(connection: c, server: self)
        connections[ObjectIdentifier(rc)] = rc
        rc.start(queue: queue)
    }

    fileprivate func closed(_ rc: RemoteConnection) {
        connections[ObjectIdentifier(rc)] = nil
        let ids = Set(connections.values.compactMap { $0.device?.id })
        DispatchQueue.main.async { self.connectedDevices = ids }
    }

    fileprivate func authenticated(_ rc: RemoteConnection) {
        let ids = Set(connections.values.compactMap { $0.device?.id })
        DispatchQueue.main.async {
            self.connectedDevices = ids
            if let id = rc.device?.id { RemoteDevices.shared.touch(id) }
        }
    }

    private func scheduleState() {
        DispatchQueue.main.async {
            self.stateWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                let state = RemoteAPI.state(controller: self.controller)
                self.queue.async { self.connections.values.forEach { $0.push(event: "state", data: state) } }
            }
            self.stateWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }
}

/// One phone connection: pairing or handshake, then encrypted RPC.
final class RemoteConnection {
    private let c: NWConnection
    private weak var server: RemoteServer?
    private(set) var device: PairedDevice?
    private var session: RemoteSession?
    private var queue: DispatchQueue!
    private var terminals: [String: Int32] = [:] // tile → daemon observe fd

    init(connection: NWConnection, server: RemoteServer) {
        self.c = connection
        self.server = server
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        c.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.close() }
            if case .cancelled = st { self?.cleanup() }
        }
        c.start(queue: queue)
        receive()
    }

    func close() { c.cancel() }

    private func cleanup() {
        for fd in terminals.values { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        terminals.removeAll()
        server?.closed(self)
    }

    private func receive() {
        c.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if err != nil { self.close(); return }
            if let data, !data.isEmpty {
                let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close { self.close(); return }
                self.handle(data)
            }
            self.receive()
        }
    }

    private func sendRaw(_ data: Data, binary: Bool) {
        let meta = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
        let ctx = NWConnection.ContentContext(identifier: "pw", metadata: [meta])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func sendJSON(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj) { sendRaw(d, binary: false) }
    }

    private func sendSealed(_ obj: [String: Any]) {
        guard let s = session, let d = try? JSONSerialization.data(withJSONObject: obj), let f = try? s.seal(d) else { return }
        sendRaw(f, binary: true)
    }

    func push(event: String, data: Any) {
        guard session != nil else { return }
        sendSealed(["event": event, "data": data])
    }

    private func handle(_ data: Data) {
        // Before the handshake: plaintext JSON (pair / hello).
        guard let session else {
            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { close(); return }
            do {
                switch msg["type"] as? String {
                case "pair":
                    var result: ([String: Any], PairedDevice)?
                    try DispatchQueue.main.sync { result = try RemoteHandshake.pair(msg) }
                    guard let (reply, dev) = result else { throw RemoteError.badPair }
                    DispatchQueue.main.async { RemoteDevices.shared.add(dev) }
                    sendJSON(reply)
                case "hello":
                    var result: ([String: Any], RemoteSession, PairedDevice)?
                    try DispatchQueue.main.sync { result = try RemoteHandshake.hello(msg) }
                    guard let (reply, s, dev) = result else { throw RemoteError.badPair }
                    sendJSON(reply)
                    self.session = s
                    self.device = dev
                    server?.authenticated(self)
                default:
                    close()
                }
            } catch {
                sendJSON(["type": "error", "error": "\(error)"])
                queue.asyncAfter(deadline: .now() + 0.2) { self.close() }
            }
            return
        }
        // After: encrypted RPC.
        guard let pt = try? session.open(data),
              let msg = try? JSONSerialization.jsonObject(with: pt) as? [String: Any] else { close(); return }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        if method == "terminal.subscribe", let tile = params["tile"] as? String {
            subscribeTerminal(tile, reply: id)
            return
        }
        if method == "terminal.unsubscribe", let tile = params["tile"] as? String {
            if let fd = terminals.removeValue(forKey: tile) { shutdown(fd, SHUT_RDWR) }
            sendSealed(["id": id ?? NSNull(), "result": true])
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let device = self.device else { return }
            let res = RemoteAPI.call(method, params: params, device: device, controller: self.server?.controller)
            self.queue.async {
                switch res {
                case .success(let v): self.sendSealed(["id": id ?? NSNull(), "result": v])
                case .failure(let e): self.sendSealed(["id": id ?? NSNull(), "error": e.message])
                }
            }
        }
    }

    /// Streams a terminal read-only: snapshot, then live output.
    private func subscribeTerminal(_ tile: String, reply id: Any?) {
        var sid: String?
        DispatchQueue.main.sync { sid = Store.shared.findTile(tile)?.tile.sessionID }
        guard let sid, terminals[tile] == nil else {
            sendSealed(["id": id ?? NSNull(), "error": sid == nil ? "not a terminal" : "already subscribed"])
            return
        }
        guard let fd = try? UnixSocket.connect(PitwallPaths.daemonSocket.path) else {
            sendSealed(["id": id ?? NSNull(), "error": "session service unavailable"]); return
        }
        UnixSocket.writeAll(fd, Wire.line(DaemonRequest(op: .observe, id: sid)))
        guard let (line, rest) = UnixSocket.readLine(fd),
              let res = try? Wire.decoder.decode(DaemonResponse.self, from: line), res.ok else {
            Darwin.close(fd); sendSealed(["id": id ?? NSNull(), "error": "session not running"]); return
        }
        terminals[tile] = fd
        let cols = res.session?.cols ?? 80, rows = res.session?.rows ?? 24
        sendSealed(["id": id ?? NSNull(), "result": ["cols": cols, "rows": rows]])
        if !rest.isEmpty { push(event: "terminal", data: ["tile": tile, "data": RemoteCrypto.b64(rest), "snapshot": true, "cols": cols, "rows": rows]) }
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 32768)
            var first = rest.isEmpty
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                let snap = first
                first = false
                self?.queue.async { self?.push(event: "terminal", data: ["tile": tile, "data": RemoteCrypto.b64(chunk), "snapshot": snap, "cols": cols, "rows": rows]) }
            }
            Darwin.close(fd)
        }
    }
}

/// The remote API: everything a phone can see and do.
enum RemoteAPI {
    struct APIError: Error { let message: String }

    static func state(controller: CanvasController?) -> [String: Any] {
        let store = Store.shared
        let boards: [[String: Any]] = store.boards.map { b in
            [
                "id": b.id, "name": b.name, "color": b.colorIndex,
                "tiles": b.tiles.filter { $0.kind != .subagent }.map { t -> [String: Any] in
                    var o: [String: Any] = ["id": t.id, "name": t.displayName, "kind": t.kind.rawValue,
                                            "state": t.state.rawValue, "since": t.stateSince.timeIntervalSince1970 * 1000,
                                            "terminal": t.isTerminalBacked]
                    if let v = t.statusMessage { o["message"] = v }
                    if let v = t.task { o["task"] = String(v.prefix(400)) }
                    if let v = t.branch { o["branch"] = v }
                    if let v = t.costUSD { o["cost"] = v }
                    if let v = t.contextPct { o["context"] = v }
                    if let v = t.model { o["model"] = v }
                    if let a = t.diffAdded { o["added"] = a }
                    if let r = t.diffRemoved { o["removed"] = r }
                    return o
                },
            ]
        }
        let inbox: [[String: Any]] = ApprovalCenter.shared.pending.map { p in
            var o: [String: Any] = ["id": p.id, "tile": p.tileID, "tool": p.tool, "summary": p.summary,
                                    "always": p.canAlwaysAllow, "at": p.createdAt.timeIntervalSince1970 * 1000]
            if let d = p.detail { o["detail"] = d }
            if let (b, t) = store.findTile(p.tileID) { o["board"] = b.name; o["tileName"] = t.displayName }
            return o
        }
        return ["mac": RemoteIdentity.shared.name, "boards": boards, "inbox": inbox, "current": store.currentBoardID]
    }

    static func call(_ method: String, params: [String: Any], device: PairedDevice, controller: CanvasController?) -> Result<Any, APIError> {
        guard let ctl = controller else { return .failure(APIError(message: "Pitwall isn't ready")) }
        switch method {
        case "state.get":
            return .success(state(controller: ctl))

        case "timeline.get":
            guard let tile = params["tile"] as? String else { return .failure(APIError(message: "tile required")) }
            Timelines.shared.load(tile)
            let events = (Timelines.shared.events[tile] ?? []).suffix(200).map {
                ["kind": $0.kind.rawValue, "text": $0.text, "at": $0.at.timeIntervalSince1970 * 1000] as [String: Any]
            }
            return .success(events)

        case "inbox.decide":
            guard let json = params["decision"] as? String, let sig = params["sig"] as? String,
                  let (approval, decision) = RemoteHandshake.verifyDecision(json: json, sig: sig, device: device) else {
                return .failure(APIError(message: "decision signature did not verify"))
            }
            guard let p = ApprovalCenter.shared.pending.first(where: { $0.id == approval }) else {
                return .failure(APIError(message: "This request was already answered"))
            }
            let d: ApprovalCenter.Decision = decision == "deny" ? .deny : (decision == "always" && p.canAlwaysAllow ? .allowAlways : .allow)
            Timelines.shared.add(p.tileID, .notification, "Answered from \(device.name)")
            ApprovalCenter.shared.decide(approval, d)
            return .success(true)

        case "agent.message":
            guard let tile = params["tile"] as? String, let text = params["text"] as? String, !text.isEmpty,
                  let t = Store.shared.findTile(tile)?.tile else { return .failure(APIError(message: "tile and text required")) }
            let msg = AgentMessage(from: "remote:" + device.id, fromName: device.name, text: text)
            Timelines.shared.add(tile, .message, "From \(device.name): \(text)")
            if t.state == .working || t.state == .waiting || ctl.surface(for: tile) == nil {
                Store.shared.inbox[tile, default: []].append(msg)
                return .success("queued")
            }
            ctl.surface(for: tile)?.submit(text)
            ctl.setState(tile, .working, message: "Message from \(device.name)")
            return .success("delivered")

        case "agent.new":
            guard let task = params["task"] as? String, !task.isEmpty else { return .failure(APIError(message: "task required")) }
            if let b = params["board"] as? String, Store.shared.board(b) != nil { ctl.switchBoard(b) }
            let before = Set(Store.shared.current.tiles.map(\.id))
            ctl.newAgent(task: task, repo: Store.shared.current.root, worktree: (params["worktree"] as? Bool) ?? Prefs.shared.worktreeByDefault,
                         agent: AgentKind(rawValue: Prefs.shared.defaultAgent) ?? .claude)
            return .success(Store.shared.current.tiles.first { !before.contains($0.id) }?.id ?? "")

        default:
            return .failure(APIError(message: "unknown method \(method)"))
        }
    }
}

extension NSImage {
    func pngData(size: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
