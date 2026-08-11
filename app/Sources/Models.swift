import Foundation

/// Mirrors the output of `status.sh --json` one-to-one.
/// A dedicated JSON contract rather than parsing the human-readable output (which
/// carries ANSI colour codes) means UI does not break when wording changes.
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
    /// Optional so that a status.sh predating this field still decodes — a failed
    /// decode would freeze every value on screen, not just this one.
    var backupDir: String?
    var gamePort: Int
    var rconPort: Int
    var lanIP: String
    var localHostname: String
    var installedBuild: String
    var rconConfigured: Bool

    /// Where backups actually live. BACKUP_DIR is overridable in config.local.sh,
    /// so the app must not assume the default path — it would list an empty folder
    /// while showing a non-zero backupCount from the real one.
    var backupDirectoryPath: String {
        let dir = backupDir ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/palworld_backups" : dir
    }

    /// Address for players on the same router.
    var lanAddress: String? { lanIP.isEmpty ? nil : "\(lanIP):\(gamePort)" }
    /// mDNS name — keeps working on the same network even when DHCP changes the IP.
    var hostnameAddress: String? { localHostname.isEmpty ? nil : "\(localHostname):\(gamePort)" }

    static let unknown = ServerStatus(
        running: false, pid: 0, cpuPercent: 0, memoryMB: 0, uptime: "",
        portBound: false, rconListening: false, playerCount: 0, players: [],
        saveBytes: 0, worlds: [], latestBackup: "", backupCount: 0,
        gamePort: 8211, rconPort: 25575, lanIP: "", localHostname: "",
        installedBuild: "", rconConfigured: false
    )

    /// Palworld servers grow their RSS steadily over long uptimes.
    /// Same thresholds as the human-readable warning in status.sh.
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

/// A backup as shown in the list.
struct BackupEntry: Identifiable, Hashable {
    /// The filename, which is unique within the backup folder. A fresh UUID per
    /// instance would give every entry a new identity on each poll, so SwiftUI would
    /// tear down and rebuild all the rows every few seconds even when the folder had
    /// not changed — and no two lists of backups would ever compare equal.
    var id: String { filename }
    let filename: String
    let size: String
    let date: Date
    /// User-assigned name. Empty means an unnamed automatic backup.
    let label: String

    /// Named backups are exempt from automatic cleanup (same rule as backup_save.sh).
    var isKept: Bool { !label.isEmpty }

    private static let prefix = "palworld_backup_"

    /// Recovers the timestamp from `palworld_backup_YYYYMMDD_HHMMSS[_name].tar.gz`.
    static func parseDate(from filename: String) -> Date? {
        guard let r = filename.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(filename[r]))
    }

    /// The timestamp is a fixed 15 characters (YYYYMMDD_HHMMSS), so everything after
    /// it is the name. Splits correctly even when the name itself contains underscores.
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


/// Output of `update_check.sh --json`.
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
