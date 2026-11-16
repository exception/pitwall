import Foundation
import Darwin

/// `pitwall attach --id <session> [--cwd dir] [-- argv...]`
///
/// Runs inside the terminal surface. It relays the surface's PTY to a daemon
/// session (creating it on first attach) and replays scrollback on re-attach.
enum AttachCommand {
    /// Env vars forwarded from the surface into a newly created session.
    static let forwardedEnv: Set<String> = [
        "TERM", "TERMINFO", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "GHOSTTY_SHELL_FEATURES",
        "LANG", "LC_ALL", "LC_CTYPE",
        PitwallEnv.tileID, PitwallEnv.boardID, PitwallEnv.appSocket, PitwallEnv.helper,
    ]

    static func run(_ args: [String]) -> Int32 {
        var id: String?
        var cwd: String?
        var argv: [String] = []
        var script: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--id": i += 1; id = args[safe: i]
            case "--cwd": i += 1; cwd = args[safe: i]
            case "--sh": i += 1; script = args[safe: i]
            case "--": argv = Array(args[(i + 1)...]); i = args.count
            default: break
            }
            i += 1
        }
        guard let id else { fputs("attach: --id required\n", stderr); return 2 }

        let helper = CommandLine.executablePath
        DaemonLauncher.ensureRunning(helper: helper)

        var cols: UInt16 = 80, rows: UInt16 = 24
        pw_get_winsize(STDIN_FILENO, &cols, &rows)

        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment where forwardedEnv.contains(k) { env[k] = v }

        let fd: Int32
        do { fd = try UnixSocket.connect(PitwallPaths.daemonSocket.path) } catch {
            fputs("pitwall: cannot reach session daemon: \(error)\r\n", stderr)
            return 1
        }
        let req = DaemonRequest(op: .attach, id: id, cwd: cwd, argv: argv.isEmpty ? nil : argv,
                                script: script, env: env, cols: Int(cols), rows: Int(rows))
        UnixSocket.writeAll(fd, Wire.line(req))
        guard let (line, rest) = UnixSocket.readLine(fd),
              let res = try? Wire.decoder.decode(DaemonResponse.self, from: line) else {
            fputs("pitwall: session daemon closed the connection\r\n", stderr)
            return 1
        }
        if !res.ok {
            if let e = res.error, e.hasPrefix("exited:") { return Int32(e.dropFirst(7)) ?? 0 }
            fputs("pitwall: \(res.error ?? "attach failed")\r\n", stderr)
            return 1
        }

        pw_tty_raw(STDIN_FILENO)
        defer { pw_tty_restore(STDIN_FILENO) }

        // Replies the terminal sends to queries contained in replayed output
        // must not be typed into the running program, so ignore input briefly.
        let replaying = res.created != true
        let inputOpensAt = Date().addingTimeInterval(replaying ? 0.35 : 0)

        let sendLock = NSLock()
        func sendFrame(_ kind: FrameKind, _ payload: Data) {
            var frame = Data([kind.rawValue])
            let n = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: n) { frame.append(contentsOf: $0) }
            frame.append(payload)
            sendLock.lock(); UnixSocket.writeAll(fd, frame); sendLock.unlock()
        }

        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winch.setEventHandler {
            var c: UInt16 = 0, r: UInt16 = 0
            if pw_get_winsize(STDIN_FILENO, &c, &r) == 0 {
                sendFrame(.resize, Data([UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)]))
            }
        }
        winch.resume()
        // A resize between reading the size above and installing the handler
        // was ignored (SIGWINCH defaults to ignore): send the current size so
        // the session doesn't keep a stale, smaller grid.
        var nowCols: UInt16 = 0, nowRows: UInt16 = 0
        if pw_get_winsize(STDIN_FILENO, &nowCols, &nowRows) == 0, nowCols > 0, nowRows > 0, nowCols != cols || nowRows != rows {
            sendFrame(.resize, Data([UInt8(nowCols >> 8), UInt8(nowCols & 0xff), UInt8(nowRows >> 8), UInt8(nowRows & 0xff)]))
        }

        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return } // stdin closed: keep receiving output
                if Date() < inputOpensAt { continue }
                sendFrame(.input, Data(buf[0..<n]))
            }
        }

        if !rest.isEmpty { writeStdout(rest) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buf.withUnsafeBytes { raw in
                var p = raw.baseAddress!
                var left = n
                while left > 0 {
                    let w = write(STDOUT_FILENO, p, left)
                    if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                    p = p.advanced(by: w); left -= w
                }
            }
        }
        close(fd)

        // The session ended (or we were detached). Report the exit code.
        if let info = try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path,
                                                DaemonRequest(op: .info, id: id), as: DaemonResponse.self),
           let s = info.session {
            if s.alive { return 0 } // detached by a newer client
            return s.exitCode ?? 0
        }
        return 0
    }

    private static func writeStdout(_ d: Data) {
        d.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let w = write(STDOUT_FILENO, p, left)
                if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                p = p.advanced(by: w); left -= w
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension CommandLine {
    static var executablePath: String {
        var size: UInt32 = 4096
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
        }
        return arguments[0]
    }
}
