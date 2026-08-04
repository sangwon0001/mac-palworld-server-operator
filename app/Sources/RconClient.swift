import Foundation
import Darwin

/// 팰월드 서버와 직접 말하는 Source RCON 클라이언트.
///
/// 왜 스크립트(`rcon_cmd`)를 두고 따로 만들었나:
/// 셸 경유 호출은 매번 bash + python3 인터프리터를 새로 띄워 약 260ms 가 듭니다.
/// 3초마다 접속자를 조회하는 폴링에서는 순수 낭비이고, 실제 TCP 왕복은 34ms 면
/// 끝납니다. 그래서 '살아 있는 서버와의 대화'만 네이티브로 처리합니다.
///
/// 스크립트 쪽 RCON 은 그대로 둡니다. CLI 와 cron 이 쓰고, 무엇보다
/// `stop_server.sh` 의 4단계 폴백(RCON→SIGINT→SIGTERM→SIGKILL)은
/// RCON 이 먹통일 때를 위한 안전장치라 앱이 흉내 내면 안 됩니다.
///
/// actor 로 만든 이유: 한 연결에 요청이 겹치면 응답이 뒤섞이므로 직렬화가 필요합니다.
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
            case .notConfigured:            return "RCON 비밀번호가 설정되지 않았습니다."
            case .connectionFailed(let m):  return "RCON 연결 실패: \(m)"
            case .authFailed:               return "RCON 인증 실패 — AdminPassword 를 확인하세요."
            case .protocolError(let m):     return "RCON 프로토콜 오류: \(m)"
            }
        }
    }

    private var credentials = Credentials()

    func configure(_ c: Credentials) { credentials = c }

    /// 명령을 보내고 응답 본문을 돌려줍니다.
    /// 연결은 매 호출마다 새로 맺습니다 — 팰월드 RCON 은 유휴 연결을 끊는 편이라
    /// 연결을 재사용하면 오히려 실패 처리가 늘어납니다. 34ms 면 충분히 쌉니다.
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

    // MARK: - 프로토콜 구현 (블로킹 소켓, 백그라운드 큐에서만 호출)

    private static let typeAuth: Int32 = 3
    private static let typeExec: Int32 = 2

    private static func exchange(command: String,
                                 credentials c: Credentials,
                                 timeout: TimeInterval) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RconError.connectionFailed("소켓 생성 실패") }
        defer { close(fd) }

        // 서버가 응답하지 않을 때 영원히 매달리지 않도록 송수신 타임아웃을 겁니다.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = c.port.bigEndian
        guard inet_pton(AF_INET, c.host, &addr.sin_addr) == 1 else {
            throw RconError.connectionFailed("주소 변환 실패: \(c.host)")
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw RconError.connectionFailed("서버가 응답하지 않습니다 (포트 \(c.port))")
        }

        // 1) 인증 — 실패 시 서버는 요청 ID 를 -1 로 돌려줍니다.
        try writeAll(fd, packet(id: 1, type: typeAuth, body: c.password))
        let auth = try readPacket(fd, timeout: timeout)
        guard auth.id != -1 else { throw RconError.authFailed }

        // 2) 명령 실행
        try writeAll(fd, packet(id: 2, type: typeExec, body: command))
        return try readPacket(fd, timeout: timeout).body
    }

    private static func packet(id: Int32, type: Int32, body: String) -> Data {
        var payload = Data()
        withUnsafeBytes(of: id.littleEndian)   { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(body.utf8))
        payload.append(contentsOf: [0, 0])          // 본문 종단 + 패킷 종단

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
                guard n > 0 else { throw RconError.connectionFailed("전송 중단") }
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
            guard n > 0 else { throw RconError.protocolError("응답이 끊겼습니다") }
            got += n
        }
        return Data(buf)
    }

    /// 최대 `count` 바이트까지 읽되, 더 이상 오지 않으면 받은 만큼만 돌려줍니다.
    ///
    /// [팰월드 서버 버그 대응] 응답 본문에 비ASCII(예: 한글)가 섞이면 서버가
    /// 실제로 보내는 것보다 **큰 길이**를 헤더에 적어 보냅니다.
    ///   Info  선언 74 / 실제 58,  Broadcast 선언 54 / 실제 39
    ///   Save·ShowPlayers 처럼 순수 ASCII 응답은 정확히 일치
    /// 선언 길이를 곧이곧대로 믿고 그만큼 기다리면 영원히 오지 않는 바이트를
    /// 기다리다 타임아웃이 납니다.
    ///
    /// 다행히 길이를 잘못 적은 응답도 패킷 종단(`00 00`)은 정상적으로 붙여 보냅니다.
    ///   Info(잘못된 길이):  ... 90 ec 9d 98 20 ed 00 00
    ///   Save(정상 길이):    ... 20 53 61 76 65 0a 00 00
    /// 그래서 선언 길이는 '상한'으로만 쓰고 **널 종단을 만나면 즉시 끝냅니다.**
    /// 덕분에 길이가 틀린 응답도 대기 없이 곧바로 반환됩니다.
    /// (본문은 텍스트라 0x00 이 중간에 나올 일이 없어 종단 판정이 안전합니다.)
    /// settle 은 종단조차 오지 않는 예외적인 경우를 위한 안전망입니다.
    private static func readUpTo(_ fd: Int32, _ count: Int, settle: TimeInterval) -> Data {
        var out = Data(); out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: count)

        while out.count < count {
            let n = buf.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!, count - out.count, 0)
            }
            guard n > 0 else { break }          // 타임아웃(-1) 또는 연결 종료(0)
            out.append(contentsOf: buf[0..<n])

            // 패킷 종단에 도달했으면 선언 길이와 무관하게 완료.
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
        // readUpTo 가 낮춰 놓은 타임아웃이 다음 패킷까지 남지 않도록 되돌립니다.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let sizeData = try readExact(fd, 4)
        let size = sizeData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
        guard size >= 10, size < 8 * 1024 * 1024 else {
            throw RconError.protocolError("패킷 길이가 비정상입니다 (\(size))")
        }

        let payload = readUpTo(fd, Int(size), settle: settle)
        guard payload.count >= 8 else {
            throw RconError.protocolError("응답이 너무 짧습니다 (\(payload.count)바이트)")
        }

        let id = payload.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
        // [id(4)][type(4)][본문...][0][0]
        // 길이가 어긋날 수 있으므로 끝의 널 바이트를 개수로 자르지 않고 훑어 냅니다.
        var bodyBytes = payload.dropFirst(8)
        while bodyBytes.last == 0 { bodyBytes = bodyBytes.dropLast() }
        return (id, String(decoding: bodyBytes, as: UTF8.self))
    }
}

// MARK: - 팰월드 전용 명령

extension RconClient {
    /// `ShowPlayers` 는 CSV 를 돌려줍니다: 첫 줄이 헤더(name,playeruid,steamid).
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
        // 팰월드 Broadcast 는 공백을 인자 구분자로 취급해 첫 단어만 표시됩니다.
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
