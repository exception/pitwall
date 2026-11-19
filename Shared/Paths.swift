import Foundation

/// Filesystem locations shared by the app and the `pitwall` helper.
enum PitwallPaths {
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["PITWALL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pitwall", isDirectory: true)
    }

    /// Unix sockets have a ~104 byte path limit, so sockets live in a short dir.
    static var runDir: URL {
        // An isolated instance (PITWALL_HOME) gets its own sockets too.
        if let override = ProcessInfo.processInfo.environment["PITWALL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("run", isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/pitwall-\(getuid())", isDirectory: true)
    }

    /// Socket for the session daemon that owns all PTYs.
    static var daemonSocket: URL { runDir.appendingPathComponent("daemon.sock") }
    /// Socket the app listens on for CLI / hook / MCP control.
    static var appSocket: URL { runDir.appendingPathComponent("app.sock") }

    static var boardsDir: URL { support.appendingPathComponent("boards", isDirectory: true) }
    static var stateFile: URL { support.appendingPathComponent("state.json") }
    /// Cross-board agent connections.
    static var portalsFile: URL { support.appendingPathComponent("portals.json") }
    static var terminalConfig: URL { support.appendingPathComponent("terminal.ghostty") }
    static var daemonLog: URL { support.appendingPathComponent("daemon.log") }
    static var hooksSettings: URL { support.appendingPathComponent("claude-hooks.json") }

    static func ensure() {
        let fm = FileManager.default
        for dir in [support, boardsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
}

/// Environment variables Pitwall sets inside every session.
enum PitwallEnv {
    /// The only variables a new session inherits from whoever started the
    /// daemon; the login shell rebuilds the rest (like Terminal.app does).
    /// Prevents leaking e.g. a parent Claude Code session's markers.
    static let inheritedAllowlist: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE",
        "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "PITWALL_HOME",
    ]

    static func scrubbed(_ env: [String: String]) -> [String: String] {
        env.filter { inheritedAllowlist.contains($0.key) }
    }

    static let tileID = "PITWALL_TILE_ID"
    static let sessionID = "PITWALL_SESSION_ID"
    static let boardID = "PITWALL_BOARD_ID"
    static let appSocket = "PITWALL_SOCKET"
    static let helper = "PITWALL_CLI"
}
