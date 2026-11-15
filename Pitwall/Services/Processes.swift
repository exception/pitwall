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
        let group = getpgid(leader)
        guard group > 0 else { return [] }
        var out: [String] = []
        // The group leader may be a wrapper (npx, node) around the agent: look a few levels down.
        var frontier = [leader]
        for _ in 0..<3 where !frontier.isEmpty {
            var next: [pid_t] = []
            for p in frontier {
                for c in children(of: p) {
                    let g = getpgid(c)
                    if g > 0 && g != group {
                        // Our own hook / status-line calls run the same way; they aren't work.
                        let l = label(c)
                        if l != "pitwall" { out.append(l) }
                    } else { next.append(c) }
                }
            }
            frontier = next
        }
        return out
    }

    private static func label(_ pid: pid_t) -> String {
        var p = pid
        var n = name(p) ?? "command"
        for _ in 0..<4 where shells.contains(n) {
            guard let c = children(of: p).first, let cn = name(c) else { break }
            p = c; n = cn
        }
        return n
    }
}
