import Foundation

/// `status.sh --json` 의 출력과 1:1 대응하는 모델.
/// 사람용 출력(색코드 포함)을 파싱하지 않고 전용 JSON 계약을 쓰는 이유는,
/// 표시 문구가 바뀌어도 UI 가 깨지지 않게 하기 위함입니다.
struct ServerStatus: Codable, Equatable {
    var running: Bool
    var pid: Int
    var cpuPercent: Double
    var memoryMB: Int
    var uptime: String
    var portBound: Bool
    var rconListening: Bool
    var playerCount: Int
    var players: [String]
    var saveBytes: Int64
    var worlds: [String]
    var latestBackup: String
    var backupCount: Int
    var gamePort: Int
    var rconPort: Int
    var lanIP: String
    var localHostname: String
    var rconConfigured: Bool

    /// 같은 공유기 안에서 쓰는 접속 주소.
    var lanAddress: String? { lanIP.isEmpty ? nil : "\(lanIP):\(gamePort)" }
    /// mDNS 이름. DHCP 로 IP 가 바뀌어도 같은 망에서는 계속 통합니다.
    var hostnameAddress: String? { localHostname.isEmpty ? nil : "\(localHostname):\(gamePort)" }

    static let unknown = ServerStatus(
        running: false, pid: 0, cpuPercent: 0, memoryMB: 0, uptime: "",
        portBound: false, rconListening: false, playerCount: 0, players: [],
        saveBytes: 0, worlds: [], latestBackup: "", backupCount: 0,
        gamePort: 8211, rconPort: 25575, lanIP: "", localHostname: "",
        rconConfigured: false
    )

    /// 팰월드 서버는 장시간 가동 시 RSS 가 계속 증가합니다.
    /// status.sh 의 사람용 경고와 같은 임계치를 씁니다.
    enum MemoryLevel { case normal, elevated, critical }
    var memoryLevel: MemoryLevel {
        if memoryMB >= 12288 { return .critical }
        if memoryMB >= 8192 { return .elevated }
        return .normal
    }

    var saveSizeText: String {
        ByteCountFormatter.string(fromByteCount: saveBytes, countStyle: .file)
    }
}

/// 목록 표시용 백업 항목.
struct BackupEntry: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let size: String
    let date: Date

    /// `palworld_backup_YYYYMMDD_HHMMSS.tar.gz` 에서 시각을 복원합니다.
    static func parseDate(from filename: String) -> Date? {
        guard let r = filename.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(filename[r]))
    }
}
