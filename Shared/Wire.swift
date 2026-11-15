import Foundation

// MARK: - Daemon protocol
//
// Every connection to the daemon starts with one JSON line (a `DaemonRequest`).
// The daemon replies with one JSON line (a `DaemonResponse`). For `attach`, the
// connection then switches to a byte stream:
//   daemon -> client : raw PTY output bytes
//   client -> daemon : frames  [u8 kind][u32 BE length][payload]
//       kind 0 = input bytes, kind 1 = resize (u16 cols, u16 rows)

struct DaemonRequest: Codable {
    enum Op: String, Codable { case attach, observe, list, kill, info, ping, scrollback, shutdown }
    var op: Op
    var id: String?
    var cwd: String?
    var argv: [String]?
    /// Shell script to run (via `$SHELL -l -i -c`) instead of argv; a login
    /// shell takes over when it ends so the tile stays usable.
    var script: String?
    var env: [String: String]?
    var cols: Int?
    var rows: Int?
    var maxBytes: Int?
}

struct SessionInfo: Codable, Equatable {
    var id: String
    var pid: Int32
    var alive: Bool
    var exitCode: Int32?
    var cwd: String?
    var foregroundPid: Int32?
    var foregroundName: String?
    var foregroundCwd: String?
    var startedAt: Date
    var lastOutputAt: Date?
    var attached: Bool
    var cols: Int?
    var rows: Int?
}

struct DaemonResponse: Codable {
    var ok: Bool
    var error: String?
    var sessions: [SessionInfo]?
    var session: SessionInfo?
    var created: Bool?
    var text: String?
}

enum FrameKind: UInt8 { case input = 0, resize = 1 }

// MARK: - App control protocol
//
// One JSON line request, one JSON line response, over the app socket. Used by
// `pitwall hook`, `pitwall tile ...`, and `pitwall mcp`.

struct ControlRequest: Codable {
    var cmd: String
    var tileID: String?
    var boardID: String?
    var args: [String: String]?
}

struct ControlResponse: Codable {
    var ok: Bool
    var error: String?
    var result: JSONValue?
}

/// Minimal JSON value for loosely-typed payloads.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
}

enum Wire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func line<T: Encodable>(_ value: T) -> Data {
        var d = (try? encoder.encode(value)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }
}
