import Foundation
import Darwin

/// Source RCON client that talks to the Palworld server directly.
///
/// Why this exists alongside the shell helper (`rcon_cmd`): going through the shell
/// spawns a fresh bash + python3 interpreter every time, costing about 260ms. That
/// is pure waste in a player poll that runs every 3 seconds, when the actual TCP
/// round trip takes 34ms. So only "conversation with a live server" is native.
///
/// The shell-side RCON stays as it is. The CLI and cron use it, and more
/// importantly `stop_server.sh`'s four-stage fallback (RCON→SIGINT→SIGTERM→SIGKILL)
/// is the safety net for when RCON itself is unresponsive — the app must not try to
/// reimplement that.
///
/// Why an actor: overlapping requests on one connection interleave their responses,
/// so calls need to be serialized.
actor RconClient {

    struct Credentials: Equatable {
        var host: String = "127.0.0.1"
        var port: UInt16 = 25575
        var password: String = ""
        var isUsable: Bool { !password.isEmpty }
    }

    enum RconError: LocalizedError {
        case notConfigured
        case connectionFailed(String)
        case authFailed
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:            return t("RCON 비밀번호가 설정되지 않았습니다.")
            case .connectionFailed(let m):  return t("RCON 연결 실패: %@", m)
            case .authFailed:               return t("RCON 인증 실패 — AdminPassword 를 확인하세요.")
            case .protocolError(let m):     return t("RCON 프로토콜 오류: %@", m)
            }
        }
    }

    private var credentials = Credentials()

    func configure(_ c: Credentials) { credentials = c }

    /// Sends a command and returns the response body.
    /// A fresh connection per call: Palworld's RCON tends to drop idle connections,
    /// so reusing one causes more failure handling than it saves. 34ms is cheap.
    func send(_ command: String, timeout: TimeInterval = 5) async throws -> String {
        let c = credentials
        guard c.isUsable else { throw RconError.notConfigured }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.exchange(command: command, credentials: c, timeout: timeout)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Protocol (blocking sockets; only ever called on a background queue)

    private static let typeAuth: Int32 = 3
    private static let typeExec: Int32 = 2

    private static func exchange(command: String,
                                 credentials c: Credentials,
                                 timeout: TimeInterval) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RconError.connectionFailed(t("소켓 생성 실패")) }
        defer { close(fd) }

        // Send/receive timeouts so an unresponsive server can't hang us forever.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = c.port.bigEndian
        guard inet_pton(AF_INET, c.host, &addr.sin_addr) == 1 else {
            throw RconError.connectionFailed(t("주소 변환 실패: %@", c.host))
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw RconError.connectionFailed(t("서버가 응답하지 않습니다 (포트 %@)", "\(c.port)"))
        }

        // 1) Authenticate — on failure the server echoes request ID -1.
        try writeAll(fd, packet(id: 1, type: typeAuth, body: c.password))
        let auth = try readPacket(fd, timeout: timeout)
        guard auth.id != -1 else { throw RconError.authFailed }

        // 2) Run the command
        try writeAll(fd, packet(id: 2, type: typeExec, body: command))
        return try readPacket(fd, timeout: timeout).body
    }

    private static func packet(id: Int32, type: Int32, body: String) -> Data {
        var payload = Data()
        withUnsafeBytes(of: id.littleEndian)   { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(body.utf8))
        payload.append(contentsOf: [0, 0])          // body terminator + packet terminator

        var out = Data()
        withUnsafeBytes(of: Int32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent, 0)
                guard n > 0 else { throw RconError.connectionFailed(t("전송 중단")) }
                sent += n
            }
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: got), count - got, 0)
            }
            guard n > 0 else { throw RconError.protocolError(t("응답이 끊겼습니다")) }
            got += n
        }
        return Data(buf)
    }

    /// Reads up to `count` bytes, returning whatever arrived if the rest never does.
    ///
    /// [Palworld server bug] When the response body contains non-ASCII text (Korean,
    /// for example) the server declares a length **larger** than what it actually
    /// sends:
    ///   Info      declared 74 / sent 58,   Broadcast declared 54 / sent 39
    ///   Save and ShowPlayers (pure ASCII) match exactly
    /// Trusting the declared length means waiting for bytes that never arrive, which
    /// ends in a timeout.
    ///
    /// Fortunately even a mis-declared response still terminates properly (`00 00`):
    ///   Info (bad length):   ... 90 ec 9d 98 20 ed 00 00
    ///   Save (good length):  ... 20 53 61 76 65 0a 00 00
    /// So the declared length is treated as an upper bound only, and reading **stops
    /// as soon as the null terminator appears** — mis-declared responses return
    /// immediately rather than stalling. (Bodies are text, so a stray 0x00 in the
    /// middle isn't a concern.) `settle` is the safety net for the pathological case
    /// where even the terminator never arrives.
    private static func readUpTo(_ fd: Int32, _ count: Int, settle: TimeInterval) -> Data {
        var out = Data(); out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: count)

        while out.count < count {
            let n = buf.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!, count - out.count, 0)
            }
            guard n > 0 else { break }          // timeout (-1) or closed (0)
            out.append(contentsOf: buf[0..<n])

            // Terminator reached — done, regardless of the declared length.
            if out.count >= 10, out.suffix(2) == Data([0, 0]) { break }

            if out.count < count {
                var tv = timeval(tv_sec: 0, tv_usec: Int32(settle * 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        return out
    }

    private static func readPacket(_ fd: Int32,
                                   timeout: TimeInterval,
                                   settle: TimeInterval = 0.35) throws -> (id: Int32, body: String) {
        // Restore the timeout that readUpTo lowered, so it doesn't leak into the next packet.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let sizeData = try readExact(fd, 4)
        let size = sizeData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
        guard size >= 10, size < 8 * 1024 * 1024 else {
            throw RconError.protocolError(t("패킷 길이가 비정상입니다 (%@)", "\(size)"))
        }

        let payload = readUpTo(fd, Int(size), settle: settle)
        guard payload.count >= 8 else {
            throw RconError.protocolError(t("응답이 너무 짧습니다 (%@바이트)", "\(payload.count)"))
        }

        let id = payload.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
        // [id(4)][type(4)][body...][0][0]
        // Lengths can be wrong, so strip trailing nulls by scanning rather than by count.
        var bodyBytes = payload.dropFirst(8)
        while bodyBytes.last == 0 { bodyBytes = bodyBytes.dropLast() }
        return (id, String(decoding: bodyBytes, as: UTF8.self))
    }
}

// MARK: - Palworld-specific commands

extension RconClient {
    /// `ShowPlayers` returns CSV; the first line is the header (name,playeruid,steamid).
    func players() async throws -> [Player] {
        let raw = try await send("ShowPlayers")
        return raw
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 3, !f[0].isEmpty else { return nil }
                return Player(name: String(f[0]), uid: String(f[1]), steamID: String(f[2]))
            }
    }

    func info() async throws -> String        { try await send("Info") }
    func save() async throws -> String        { try await send("Save") }
    func broadcast(_ m: String) async throws  -> String {
        // Palworld's Broadcast treats spaces as argument separators, so only the
        // first word would show up.
        try await send("Broadcast " + m.replacingOccurrences(of: " ", with: "_"))
    }
    func kick(_ uid: String) async throws -> String { try await send("KickPlayer \(uid)") }
    func ban(_ uid: String) async throws -> String  { try await send("BanPlayer \(uid)") }

    struct Player: Identifiable, Hashable {
        let name: String
        let uid: String
        let steamID: String
        var id: String { steamID.isEmpty ? name : steamID }
    }
}
