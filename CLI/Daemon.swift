import Foundation
import Darwin

/// The session daemon. It owns every PTY so agents keep running when the app
/// quits, crashes or updates. Clients attach over a unix socket and get the
/// scrollback replayed on attach.
final class SessionDaemon {
    static let ringCapacity = 8 << 20 // 8 MB per session

    final class Session {
        let id: String
        let pid: pid_t
        let master: Int32
        let startedAt = Date()
        let cwd: String?
        var ring = Data()
        /// Headless terminal mirroring the screen, for exact re-attach.
        var vt: UnsafeMutableRawPointer?
        var alive = true
        var exitCode: Int32?
        var lastOutputAt: Date?
        var client: Client?
        /// Read-only watchers (e.g. viewers): output only, no input.
        var observers: [Client] = []
        var readSource: DispatchSourceRead?
        var procSource: DispatchSourceProcess?

        init(id: String, pid: pid_t, master: Int32, cwd: String?, cols: UInt16, rows: UInt16) {
            self.id = id; self.pid = pid; self.master = master; self.cwd = cwd
            self.vt = pw_vt_new(cols, rows)
        }

        deinit { pw_vt_free(vt) }

        /// VT sequences that recreate the screen + scrollback exactly.
        func snapshot() -> Data {
            var len = 0
            guard let p = pw_vt_format(vt, 1, &len) else { return ring }
            defer { pw_vt_free_buf(p, len) }
            return Data(bytes: p, count: len)
        }

        /// Plain text of the screen + scrollback (wrapped lines joined).
        func plainText() -> String? {
            var len = 0
            guard let p = pw_vt_format(vt, 0, &len) else { return nil }
            defer { pw_vt_free_buf(p, len) }
            return String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
        }

        func append(_ bytes: UnsafeRawBufferPointer) {
            if let base = bytes.baseAddress {
                pw_vt_write(vt, base.assumingMemoryBound(to: UInt8.self), bytes.count)
            }
            ring.append(contentsOf: bytes)
            if ring.count > SessionDaemon.ringCapacity {
                // Trim to 3/4 capacity, then forward to a line boundary so a
                // replay never starts in the middle of an escape sequence.
                var cut = ring.count - SessionDaemon.ringCapacity * 3 / 4
                if let nl = ring[(ring.startIndex + cut)...].firstIndex(of: 0x0A) {
                    cut = nl - ring.startIndex + 1
                }
                ring.removeFirst(cut)
                ring = Data(ring) // re-base indices
            }
        }

        func info() -> SessionInfo {
            var fgPid: Int32?
            var fgName: String?
            var fgCwd: String?
            if alive {
                let pg = pw_foreground_pgrp(master)
                if pg > 0 {
                    fgPid = pg
                    var buf = [CChar](repeating: 0, count: 1024)
                    if pw_pid_name(pg, &buf, Int32(buf.count)) == 0 { fgName = String(cString: buf) }
                    if pw_pid_cwd(pg, &buf, Int32(buf.count)) == 0 { fgCwd = String(cString: buf) }
                }
            }
            var c: UInt16 = 0, r: UInt16 = 0
            if alive { pw_get_winsize(master, &c, &r) }
            return SessionInfo(id: id, pid: pid, alive: alive, exitCode: exitCode, cwd: cwd,
                               foregroundPid: fgPid, foregroundName: fgName, foregroundCwd: fgCwd,
                               startedAt: startedAt, lastOutputAt: lastOutputAt, attached: client != nil,
                               cols: c > 0 ? Int(c) : nil, rows: r > 0 ? Int(r) : nil)
        }
    }

    /// An attached client. Writes go through a dedicated queue so a slow
    /// client never blocks PTY reads for other sessions.
    final class Client {
        let fd: Int32
        let writeQueue: DispatchQueue
        var closed = false
        init(fd: Int32) {
            self.fd = fd
            self.writeQueue = DispatchQueue(label: "pitwall.client.\(fd)")
        }
        func send(_ data: Data) {
            writeQueue.async { [self] in
                if closed { return }
                if !UnixSocket.writeAll(fd, data) { closed = true }
            }
        }
        func close() {
            writeQueue.async { [self] in
                if closed { return }
                closed = true
                shutdown(fd, SHUT_RDWR)
            }
        }
    }

    private let q = DispatchQueue(label: "pitwall.daemon")
    private var sessions: [String: Session] = [:]
    private var listenSource: DispatchSourceRead?
    private let log: FileHandle?

    init() {
        PitwallPaths.ensure()
        // Append across restarts (keep history after a crash); start fresh past 2 MB.
        let logPath = PitwallPaths.daemonLog.path
        let size = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0
        if size == 0 || size > 2 << 20 { FileManager.default.createFile(atPath: logPath, contents: nil) }
        log = try? FileHandle(forWritingTo: PitwallPaths.daemonLog)
        log?.seekToEndOfFile()
    }

    func logLine(_ s: String) {
        log?.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n".utf8))
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let path = PitwallPaths.daemonSocket.path
        // Refuse to start if another daemon is already serving.
        if let res = try? UnixSocket.roundTrip(path, DaemonRequest(op: .ping), as: DaemonResponse.self), res.ok {
            FileHandle.standardError.write(Data("pitwall daemon already running\n".utf8))
            exit(0)
        }
        let fd: Int32
        do { fd = try UnixSocket.listen(path) } catch {
            logLine("listen failed: \(error)")
            exit(1)
        }
        logLine("daemon started pid=\(getpid())")
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0, let self else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { self.handle(client) }
        }
        src.resume()
        listenSource = src
        dispatchMain()
    }

    // MARK: Connections

    private func handle(_ fd: Int32) {
        guard let (line, rest) = UnixSocket.readLine(fd),
              let req = try? Wire.decoder.decode(DaemonRequest.self, from: line) else {
            close(fd); return
        }
        switch req.op {
        case .ping:
            reply(fd, DaemonResponse(ok: true)); close(fd)
        case .list:
            let infos = q.sync { sessions.values.map { $0.info() }.sorted { $0.startedAt < $1.startedAt } }
            reply(fd, DaemonResponse(ok: true, sessions: infos)); close(fd)
        case .info:
            let info = q.sync { req.id.flatMap { sessions[$0]?.info() } }
            reply(fd, DaemonResponse(ok: info != nil, error: info == nil ? "no such session" : nil, session: info))
            close(fd)
        case .kill:
            q.sync {
                if let id = req.id, let s = sessions[id] {
                    if s.alive { kill(-s.pid, SIGHUP); kill(s.pid, SIGHUP) }
                    if !s.alive { sessions[id] = nil }
                }
            }
            reply(fd, DaemonResponse(ok: true)); close(fd)
        case .scrollback:
            let text: String? = q.sync {
                guard let id = req.id, let s = sessions[id] else { return nil }
                let max = req.maxBytes ?? 256 << 10
                if let text = s.plainText() { return String(text.suffix(max)) }
                return String(decoding: s.ring.suffix(max), as: UTF8.self)
            }
            reply(fd, DaemonResponse(ok: text != nil, text: text)); close(fd)
        case .shutdown:
            reply(fd, DaemonResponse(ok: true)); close(fd)
            q.sync { for s in sessions.values where s.alive { kill(-s.pid, SIGHUP) } }
            exit(0)
        case .attach:
            attach(fd, req, pending: rest)
        case .observe:
            observe(fd, req)
        }
    }

    /// Read-only stream: ack (with size), a snapshot, then live output.
    private func observe(_ fd: Int32, _ req: DaemonRequest) {
        let client = Client(fd: fd)
        let ok: Bool = q.sync {
            guard let id = req.id, let s = sessions[id], s.alive else { return false }
            client.send(Wire.line(DaemonResponse(ok: true, session: s.info())))
            client.send(s.snapshot())
            s.observers.append(client)
            return true
        }
        guard ok else { reply(fd, DaemonResponse(ok: false, error: "no such session")); close(fd); return }
        // Wait for the watcher to go away; it never sends input.
        var buf = [UInt8](repeating: 0, count: 256)
        while read(fd, &buf, buf.count) > 0 {}
        q.sync { for s in sessions.values { s.observers.removeAll { $0 === client } } }
        client.writeQueue.sync { client.closed = true }
        close(fd)
    }

    private func reply(_ fd: Int32, _ res: DaemonResponse) {
        UnixSocket.writeAll(fd, Wire.line(res))
    }

    private func attach(_ fd: Int32, _ req: DaemonRequest, pending: Data) {
        guard let id = req.id else { reply(fd, DaemonResponse(ok: false, error: "missing id")); close(fd); return }
        let cols = UInt16(clamping: req.cols ?? 80), rows = UInt16(clamping: req.rows ?? 24)

        var created = false
        var errorText: String?
        let client = Client(fd: fd)

        q.sync {
            var session = sessions[id]
            if let s = session, !s.alive {
                // Dead session: report its exit and drop it.
                errorText = "exited:\(s.exitCode ?? 0)"
                sessions[id] = nil
                return
            }
            if session == nil {
                guard let s = spawn(id: id, req: req, cols: cols, rows: rows) else {
                    errorText = "spawn failed"; return
                }
                session = s
                created = true
            }
            guard let s = session else { return }
            if let old = s.client { old.close() }
            // Ack and replay are queued before the client can receive any live
            // output, because PTY reads also run on `q`.
            client.send(Wire.line(DaemonResponse(ok: true, created: created)))
            // Exact snapshot of screen, scrollback and modes (not raw bytes),
            // taken at the attaching client's size so positions line up.
            if !created {
                pw_set_winsize(s.master, cols, rows)
                pw_vt_resize(s.vt, cols, rows)
                client.send(s.snapshot())
            }
            s.client = client
        }

        if let errorText {
            reply(fd, DaemonResponse(ok: false, error: errorText)); close(fd); return
        }

        // Apply the client's size; if unchanged still nudge the app to redraw.
        q.sync {
            guard let s = sessions[id] else { return }
            // Same size or not, SIGWINCH makes full-screen programs redraw.
            // (Never shrink-then-grow: shrinking pushes the top row away.)
            pw_set_winsize(s.master, cols, rows)
            pw_vt_resize(s.vt, cols, rows)
            let pg = pw_foreground_pgrp(s.master)
            if pg > 0 { kill(-pg, SIGWINCH) }
        }

        // Read frames from the client until it disconnects.
        var buf = pending
        var chunk = [UInt8](repeating: 0, count: 65536)
        outer: while true {
            while buf.count >= 5 {
                let kind = buf[buf.startIndex]
                let len = Int(buf[buf.startIndex + 1]) << 24 | Int(buf[buf.startIndex + 2]) << 16
                    | Int(buf[buf.startIndex + 3]) << 8 | Int(buf[buf.startIndex + 4])
                guard buf.count >= 5 + len else { break }
                let payload = buf.subdata(in: (buf.startIndex + 5)..<(buf.startIndex + 5 + len))
                buf = Data(buf.dropFirst(5 + len))
                let master: Int32? = q.sync {
                    guard let s = sessions[id], s.client === client, s.alive else { return nil }
                    return s.master
                }
                guard let master else { break outer }
                switch FrameKind(rawValue: kind) {
                case .input:
                    UnixSocket.writeAll(master, payload)
                case .resize where payload.count >= 4:
                    let c = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                    let r = UInt16(payload[payload.startIndex + 2]) << 8 | UInt16(payload[payload.startIndex + 3])
                    if c > 0 && r > 0 {
                        pw_set_winsize(master, c, r)
                        q.sync { if let s = sessions[id] { pw_vt_resize(s.vt, c, r) } }
                    }
                default:
                    break
                }
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buf.append(chunk, count: n)
        }

        q.sync {
            if let s = sessions[id], s.client === client { s.client = nil }
        }
        client.writeQueue.sync { client.closed = true }
        close(fd)
    }

    // MARK: Spawning

    private func loginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
        return "/bin/zsh"
    }

    /// Must be called on `q`.
    private func spawn(id: String, req: DaemonRequest, cols: UInt16, rows: UInt16) -> Session? {
        var env = PitwallEnv.scrubbed(ProcessInfo.processInfo.environment)
        for (k, v) in req.env ?? [:] { env[k] = v }
        env[PitwallEnv.sessionID] = id
        env["TERM"] = env["TERM"] ?? "xterm-256color"

        let path = loginShell()
        let name = (path as NSString).lastPathComponent
        if name == "zsh", let res = env["GHOSTTY_RESOURCES_DIR"] {
            // Ghostty-style zsh integration: cwd reporting, prompt marks.
            let integ = res + "/shell-integration/zsh"
            if FileManager.default.fileExists(atPath: integ) {
                if let old = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
                env["ZDOTDIR"] = integ
            }
        }
        var argv: [String]
        if let script = req.script, !script.isEmpty {
            // Run through an interactive login shell so PATH and aliases match
            // the user's terminal; fall back to a shell when it finishes.
            argv = ["-" + name, "-l", "-i", "-c", script + "\nexec " + shellQuote(path) + " -l"]
        } else if let cmd = req.argv, !cmd.isEmpty {
            argv = ["-" + name, "-l", "-i", "-c", "exec " + cmd.map(shellQuote).joined(separator: " ")]
        } else {
            // Default: the user's login shell, as a login shell ("-zsh").
            argv = ["-" + name]
        }

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var master: Int32 = -1
        let cwd = req.cwd ?? env["HOME"]
        let pid = cArgv.withUnsafeBufferPointer { a in
            cEnv.withUnsafeBufferPointer { e in
                pw_spawn_pty(path, a.baseAddress, e.baseAddress, cwd, cols, rows, &master)
            }
        }
        guard pid > 0 else { logLine("spawn failed for \(id): errno=\(errno)"); return nil }
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let s = Session(id: id, pid: pid, master: master, cwd: cwd, cols: cols, rows: rows)
        sessions[id] = s
        logLine("spawned \(id) pid=\(pid) argv=\(argv)")

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)
        var buf = [UInt8](repeating: 0, count: 65536)
        rs.setEventHandler { [weak self, weak s] in
            guard let s else { return }
            while true {
                let n = read(master, &buf, buf.count)
                if n > 0 {
                    buf.withUnsafeBytes { raw in s.append(UnsafeRawBufferPointer(rebasing: raw[0..<n])) }
                    s.lastOutputAt = Date()
                    let chunk = Data(buf[0..<n])
                    s.client?.send(chunk)
                    s.observers.forEach { $0.send(chunk) }
                    continue
                }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                // EOF / EIO: the child side is gone.
                self?.finish(s)
                return
            }
        }
        rs.setCancelHandler { close(master) }
        rs.resume()
        s.readSource = rs

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: q)
        ps.setEventHandler { [weak self, weak s] in
            guard let s else { return }
            var status: Int32 = 0
            if waitpid(s.pid, &status, WNOHANG) == s.pid {
                let exited = status & 0x7f == 0
                s.exitCode = exited ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            }
            // Give the read source a moment to drain remaining output.
            self?.q.asyncAfter(deadline: .now() + 0.2) { self?.finish(s) }
        }
        ps.resume()
        s.procSource = ps
        return s
    }

    /// Must be called on `q`.
    private func finish(_ s: Session) {
        guard s.alive else { return }
        s.alive = false
        if s.exitCode == nil {
            var status: Int32 = 0
            for _ in 0..<40 {
                if waitpid(s.pid, &status, WNOHANG) == s.pid {
                    let exited = status & 0x7f == 0
                    s.exitCode = exited ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    break
                }
                usleep(5_000)
            }
        }
        s.readSource?.cancel()
        s.procSource?.cancel()
        logLine("session \(s.id) exited code=\(s.exitCode ?? -1)")
        s.client?.close()
        s.client = nil
        s.observers.forEach { $0.close() }
        s.observers.removeAll()
        // Keep the dead record briefly so a re-attach can learn the exit code.
        q.asyncAfter(deadline: .now() + 60) { [weak self] in
            if let cur = self?.sessions[s.id], cur === s { self?.sessions[s.id] = nil }
        }
    }
}

