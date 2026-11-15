import Foundation
import Darwin

/// Thin blocking unix-socket helpers shared by the app, daemon and CLI.
enum UnixSocket {
    enum Failure: Error, CustomStringConvertible {
        case sys(String, Int32)
        var description: String {
            switch self { case .sys(let what, let e): return "\(what): \(String(cString: strerror(e)))" }
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let n = min(bytes.count, raw.count - 1)
            for i in 0..<n { raw[i] = UInt8(bitPattern: bytes[i]) }
            raw[n] = 0
        }
        return addr
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.sys("socket", errno) }
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { let e = errno; close(fd); throw Failure.sys("connect \(path)", e) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func listen(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.sys("socket", errno) }
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { let e = errno; close(fd); throw Failure.sys("bind \(path)", e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 64) == 0 else { let e = errno; close(fd); throw Failure.sys("listen", e) }
        return fd
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 1000)
                        continue
                    }
                    return false
                }
                p = p.advanced(by: n)
                left -= n
            }
            return true
        }
    }

    /// Reads bytes until a newline. Returns the line (without newline) and any
    /// bytes already read past it.
    static func readLine(_ fd: Int32, limit: Int = 16 << 20) -> (Data, Data)? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buf.count < limit {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return buf.isEmpty ? nil : (buf, Data()) }
            buf.append(chunk, count: n)
            if let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                let rest = buf[buf.index(after: nl)...]
                return (Data(line), Data(rest))
            }
        }
        return nil
    }

    /// One-shot request/response helper.
    static func roundTrip<Req: Encodable, Res: Decodable>(_ path: String, _ req: Req, as: Res.Type, timeout: TimeInterval = 30) throws -> Res {
        let fd = try connect(path)
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        writeAll(fd, Wire.line(req))
        guard let (line, _) = readLine(fd) else { throw Failure.sys("no response", EIO) }
        return try Wire.decoder.decode(Res.self, from: line)
    }
}
