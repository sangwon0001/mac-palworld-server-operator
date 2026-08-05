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
    var installedBuild: String
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
        installedBuild: "", rconConfigured: false
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
    /// 사용자가 붙인 이름. 비어 있으면 이름 없는 자동 백업입니다.
    let label: String

    /// 이름이 있으면 자동 정리에서 제외됩니다 (backup_save.sh 와 같은 규칙).
    var isKept: Bool { !label.isEmpty }

    private static let prefix = "palworld_backup_"

    /// `palworld_backup_YYYYMMDD_HHMMSS[_이름].tar.gz` 에서 시각을 복원합니다.
    static func parseDate(from filename: String) -> Date? {
        guard let r = filename.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(filename[r]))
    }

    /// 타임스탬프는 고정폭 15자(YYYYMMDD_HHMMSS)이므로 그 뒤가 이름입니다.
    /// 이름 안에 밑줄이 있어도 정확히 분리됩니다.
    static func parseLabel(from filename: String) -> String {
        var s = filename
        guard s.hasPrefix(prefix) else { return "" }
        s.removeFirst(prefix.count)
        if s.hasSuffix(".tar.gz") { s.removeLast(".tar.gz".count) }
        guard s.count > 15 else { return "" }
        let rest = String(s.dropFirst(15))
        return rest.hasPrefix("_") ? String(rest.dropFirst()) : rest
    }
}


/// `update_check.sh --json` 의 출력.
struct UpdateStatus: Codable, Equatable {
    var installedBuild: String
    var latestBuild: String
    /// "up-to-date" | "update-available" | "unknown"
    var state: String
    var checkedAt: Int
    var cacheAgeSeconds: Int
    var installedAt: Int

    var updateAvailable: Bool { state == "update-available" }
    var isKnown: Bool { state != "unknown" }

    var checkedAtText: String? {
        guard checkedAt > 0 else { return nil }
        let d = Date(timeIntervalSince1970: TimeInterval(checkedAt))
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
