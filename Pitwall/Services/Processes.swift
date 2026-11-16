import Darwin

/// The process tree under an agent CLI, for spotting work it left running.
enum Processes {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "nu", "login"]

    static func children(of pid: pid_t) -> [pid_t] {
        let n = proc_listchildpids(pid, nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return Array(buf.prefix(Int(got))).filter { $0 > 0 }
    }

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Commands the agent is running outside its own process group. Claude
    /// Code starts each Bash tool call as `zsh -c …` in a new session, while
    /// its MCP servers (and helpers like caffeinate) stay in its group. Once a
    /// turn has ended, whatever is left is background work. Each is labeled by
    /// the first non-shell process under it ("npm", "sleep").
    static func toolCommands(under leader: pid_t) -> [String] {
        backgroundCommands(under: leader).map(\.label)
    }

    /// One command the agent left running.
    struct Command {
        /// The labeled process ("bun", not the `zsh -c` around it).
        var pid: pid_t
        var label: String
        /// Where its output goes: the file the command redirected to, else
        /// the file the agent collects the shell's output in.
        var output: String?
    }

    static func backgroundCommands(under leader: pid_t) -> [Command] {
        let group = getpgid(leader)
        guard group > 0 else { return [] }
        var out: [Command] = []
        // The group leader may be a wrapper (npx, node) around the agent: look a few levels down.
        var frontier = [leader]
        for _ in 0..<3 where !frontier.isEmpty {
            var next: [pid_t] = []
            for p in frontier {
                for c in children(of: p) {
                    let g = getpgid(c)
                    if g > 0 && g != group {
                        // Our own hook / status-line calls run the same way; they aren't work.
                        let (pid, l) = labeled(c)
                        if l != "pitwall" { out.append(Command(pid: pid, label: l, output: outputFile(pid) ?? outputFile(c))) }
                    } else { next.append(c) }
                }
            }
            frontier = next
        }
        return out
    }

    private static func labeled(_ pid: pid_t) -> (pid_t, String) {
        var p = pid
        var n = name(p) ?? "command"
        for _ in 0..<4 where shells.contains(n) {
            guard let c = children(of: p).first, let cn = name(c) else { break }
            p = c; n = cn
        }
        return (p, n)
    }

    /// The regular file a process's stdout is written to, if it is one
    /// (not a terminal, pipe or /dev/null).
    static func outputFile(_ pid: pid_t) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard !path.isEmpty, !path.hasPrefix("/dev/") else { return nil }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return path
    }
}
