import Foundation
import Combine

/// Permission requests from Claude Code (`PermissionRequest` hook) waiting for
/// the user. The hook process blocks on a background thread while the user
/// answers in the Inbox, a toast, or Pitwall Remote.
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    enum Decision: Equatable { case allow, allowAlways, deny }

    struct Pending: Identifiable, Equatable {
        let id: String
        let tileID: String
        let tool: String
        let summary: String
        let detail: String?
        let suggestions: String?
        let createdAt: Date
        var canAlwaysAllow: Bool { suggestions != nil }
    }

    @Published private(set) var pending: [Pending] = []
    private let lock = NSLock()
    private var waiters: [String: DispatchSemaphore] = [:]
    private var decisions: [String: Decision?] = [:]

    /// Main thread. Registers a request and returns its id.
    func register(tileID: String, args: [String: String]) -> Pending {
        let tool = args["tool_name"] ?? "tool"
        let p = Pending(id: UUID().uuidString, tileID: tileID, tool: tool,
                        summary: Self.summary(tool: tool, args: args),
                        detail: args["input.description"],
                        suggestions: args["permission_suggestions"].flatMap { $0 == "[]" ? nil : $0 },
                        createdAt: Date())
        lock.lock(); waiters[p.id] = DispatchSemaphore(value: 0); lock.unlock()
        pending.append(p)
        return p
    }

    /// Background thread. Blocks until decided, passed through, or timed out.
    func wait(_ id: String, timeout: TimeInterval) -> Decision? {
        lock.lock(); let sem = waiters[id]; lock.unlock()
        guard let sem else { return nil }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock()
        let d = decisions[id] ?? nil
        waiters[id] = nil
        decisions[id] = nil
        lock.unlock()
        DispatchQueue.main.async { self.pending.removeAll { $0.id == id } }
        return d
    }

    /// Main thread. The user answered.
    func decide(_ id: String, _ d: Decision?) {
        lock.lock()
        decisions[id] = d
        let sem = waiters[id]
        lock.unlock()
        pending.removeAll { $0.id == id }
        sem?.signal()
    }

    /// The user answered in the terminal (or the agent moved on): release any
    /// waiting hooks for this tile without a decision.
    func passThrough(tileID: String) {
        for p in pending where p.tileID == tileID { decide(p.id, nil) }
    }

    func pending(for tileID: String) -> Pending? { pending.first { $0.tileID == tileID } }

    /// Claude Code hook output for a decision.
    static func hookOutput(_ d: Decision, suggestions: String?) -> String {
        var decision: [String: Any] = ["behavior": d == .deny ? "deny" : "allow"]
        if d == .deny { decision["message"] = "The user denied this in Pitwall." }
        if d == .allowAlways, let s = suggestions, let data = s.data(using: .utf8),
           var rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // Persist for this project rather than only this session.
            for i in rules.indices where rules[i]["destination"] == nil || (rules[i]["destination"] as? String) == "session" {
                rules[i]["destination"] = "localSettings"
            }
            decision["updatedPermissions"] = rules
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: out)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func summary(tool: String, args: [String: String]) -> String {
        if let c = args["input.command"] { return "$ " + String(c.prefix(200)) }
        if let f = args["input.file_path"] { return "\(tool) \((f as NSString).lastPathComponent)" }
        if let u = args["input.url"] { return "\(tool) \(u)" }
        if tool.hasPrefix("mcp__") { return tool.split(separator: "__").dropFirst().joined(separator: " › ") }
        return tool
    }
}

/// What an agent did, for the per-tile timeline.
struct TimelineEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case prompt, tool, permission, approved, denied, notification, message, done, error, subagent }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var text: String
}

/// Per-tile timelines, kept in memory and appended to JSONL on disk.
final class Timelines: ObservableObject {
    static let shared = Timelines()
    @Published private(set) var events: [String: [TimelineEvent]] = [:]
    private let dir = PitwallPaths.support.appendingPathComponent("timelines", isDirectory: true)
    private let io = DispatchQueue(label: "pitwall.timelines")

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func add(_ tileID: String, _ kind: TimelineEvent.Kind, _ text: String) {
        let e = TimelineEvent(kind: kind, text: String(text.prefix(300)))
        load(tileID)
        events[tileID, default: []].append(e)
        if events[tileID]!.count > 500 { events[tileID]!.removeFirst(events[tileID]!.count - 500) }
        let url = dir.appendingPathComponent("\(tileID).jsonl")
        io.async {
            var line = (try? Wire.encoder.encode(e)) ?? Data()
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: url) }
        }
    }

    func load(_ tileID: String) {
        guard events[tileID] == nil else { return }
        let url = dir.appendingPathComponent("\(tileID).jsonl")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { events[tileID] = []; return }
        events[tileID] = s.split(separator: "\n").suffix(500).compactMap { try? Wire.decoder.decode(TimelineEvent.self, from: Data($0.utf8)) }
    }

    func remove(_ tileID: String) {
        events[tileID] = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(tileID).jsonl"))
    }
}
