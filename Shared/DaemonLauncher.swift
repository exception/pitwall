import Foundation
import Darwin

/// Starts the daemon if it isn't answering pings.
enum DaemonLauncher {
    static func isRunning() -> Bool {
        (try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .ping), as: DaemonResponse.self))?.ok == true
    }

    static func ensureRunning(helper: String) {
        if isRunning() { return }
        PitwallPaths.ensure()
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        // Strip terminal-specific env so the daemon starts clean.
        let env = PitwallEnv.scrubbed(ProcessInfo.processInfo.environment)
        let argv = [strdup(helper), strdup("daemon"), nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        posix_spawn(&pid, helper, &actions, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        for _ in 0..<50 {
            if isRunning() { return }
            usleep(20_000)
        }
    }
}

func shellQuote(_ s: String) -> String {
    if s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

