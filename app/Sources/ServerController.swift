import Foundation
import SwiftUI

/// Runs the shell scripts and polls server state.
///
/// Design rule: all server-control logic lives in the .sh scripts; this class only
/// invokes them. The app, the terminal and cron therefore run exactly the same code,
/// and anything done in the app is reproducible from the CLI.
@MainActor
final class ServerController: ObservableObject {

    @Published private(set) var status: ServerStatus = .unknown
    @Published private(set) var backups: [BackupEntry] = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var busyMessage: String?

    /// Game settings as read from the file.
    @Published private(set) var settings: [GameSetting] = []
    /// Edited but not yet written to disk; applied in one batch on Apply.
    @Published private(set) var pendingSettings: [String: String] = [:]

    /// Players fetched over native RCON — direct TCP (34ms) instead of the shell (260ms).
    @Published private(set) var players: [RconClient.Player] = []
    /// Last RCON error, so the UI can explain why the player list is empty.
    @Published private(set) var rconError: String?

    /// Public IP. Fetching it calls an external service, so it is only looked up
    /// when the user explicitly asks.
    @Published private(set) var publicIP: String?
    @Published private(set) var isFetchingPublicIP = false

    private let rcon = RconClient()
    private var rconReady = false

    /// Game version parsed from RCON `Info` (e.g. "1.0.2.101103").
    /// Only knowable while the server is running.
    @Published private(set) var gameVersion: String?
    /// Result of comparing the installed build against Steam's latest.
    @Published private(set) var updateStatus: UpdateStatus?
    @Published private(set) var isCheckingUpdate = false
    @Published var scriptsDirectory: String {
        didSet { UserDefaults.standard.set(scriptsDirectory, forKey: "scriptsDirectory") }
    }

    var isBusy: Bool { busyMessage != nil }

    private var pollTask: Task<Void, Never>?

    init() {
        // Precedence: user-chosen path > path baked in at build time > guess from $HOME
        let stored = UserDefaults.standard.string(forKey: "scriptsDirectory")
        let baked = Bundle.main.object(forInfoDictionaryKey: "PWScriptsDirectory") as? String
        scriptsDirectory = stored ?? baked ?? NSHomeDirectory() + "/palworld-server"

        // Tie polling to this instance's lifetime; see the note in PalworldServerApp.
        startPolling()
    }

    // MARK: - Polling

    func startPolling() {
        // Don't start a second loop if one is already running.
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            // Read only the cached update state at startup (no network).
            // A Steam lookup takes ~6s and cannot ride along with a 3s poll, so the
            // real check happens only when the user presses Check for Updates.
            await self?.checkUpdate(cachedOnly: true)

            while !Task.isCancelled {
                // End the loop once the controller is gone. (With `self?` the loop
                // would keep spinning and burning CPU after the instance disappears.)
                guard let self else { return }
                await self.refresh()
                // Every poll spawns bash + status.sh (lsof, ps, du). At 3s that is
                // worth it for a live server whose players and memory move, and
                // pure waste for a stopped one where nothing changes until the user
                // presses Start — which refreshes immediately anyway.
                try? await Task.sleep(for: .seconds(self.status.running ? 3 : 10))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Skip status polling during long operations (start/stop/restart): it keeps
        // poll output from interleaving with task output and avoids extra processes.
        guard !isBusy else { return }

        // --no-rcon: players are fetched natively below, so skip the shell's RCON
        // call. (0.39s → 0.14s)
        if let json = try? await run(script: "status.sh", args: ["--json", "--no-rcon"], capture: true),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ServerStatus.self, from: data) {
            status = decoded
        }

        await refreshPlayers()
        await loadBackups()
    }

    // MARK: - Connection address

    /// Looks up the public IP. This calls out to api.ipify.org, so it is kept out of
    /// the poll loop and only runs on explicit request.
    func fetchPublicIP() {
        guard !isFetchingPublicIP else { return }
        isFetchingPublicIP = true
        Task {
            defer { isFetchingPublicIP = false }
            guard let url = URL(string: "https://api.ipify.org") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let ip = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                publicIP = ip
            } else {
                append(t("‼️ 공인 IP 조회 실패 — 네트워크를 확인하세요."))
            }
        }
    }

    // MARK: - RCON

    /// AdminPassword / RCONPort in PalWorldSettings.ini are the source of truth for
    /// RCON credentials — those are the values the running server actually checks.
    private func prepareRcon() async {
        guard !rconReady else { return }
        if settings.isEmpty { await loadSettings() }

        let pw = settings.first { $0.key == "AdminPassword" }?.value ?? ""
        let port = UInt16(settings.first { $0.key == "RCONPort" }?.value ?? "") ?? 25575
        await rcon.configure(.init(host: "127.0.0.1", port: port, password: pw))
        rconReady = !pw.isEmpty
    }

    private func refreshPlayers() async {
        guard status.running, status.rconListening else {
            players = []
            // Forget the version when the server goes down, so the next start picks
            // up a version that changed during an update.
            gameVersion = nil
            return
        }
        await prepareRcon()
        guard rconReady else { return }

        do {
            players = try await rcon.players()
            rconError = nil
        } catch {
            players = []
            rconError = error.localizedDescription
        }

        // The game version only needs reading once; it can't change until a restart.
        if gameVersion == nil, let v = try? await rcon.info() {
            // Extract just the version from "Welcome to Pal Server[v1.0.2.101103] name".
            // The server truncates non-ASCII names, but the version comes first, so
            // parsing it is safe.
            if let r = v.range(of: #"\[v[0-9.]+\]"#, options: .regularExpression) {
                gameVersion = String(v[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[v]"))
            }
        }
    }

    // MARK: - Update check

    /// Compares the installed build against Steam's latest.
    /// - Parameter cachedOnly: read only the cache, no network (returns immediately).
    ///   Keeps the 6-second Steam lookup out of the recurring poll.
    func checkUpdate(cachedOnly: Bool = false, force: Bool = false) async {
        if !cachedOnly { isCheckingUpdate = true }
        defer { isCheckingUpdate = false }

        var args = ["--json"]
        if cachedOnly { args.append("--cached") }
        if force { args.append("--force") }

        guard let json = try? await run(script: "update_check.sh", args: args, capture: true),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(UpdateStatus.self, from: data)
        else { return }
        updateStatus = decoded
    }

    /// Back up → shut down safely → update → start again.
    func updateServer() {
        let task = perform(t("서버 업데이트 중…"), script: "auto_restart.sh", args: ["--update"])
        Task {
            await task.value
            await checkUpdate(force: true)
        }
    }

    /// Broadcasts a message to every connected player.
    func broadcast(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        rconCommand(t("공지 전송"), { try await self.rcon.broadcast(text) })
    }

    func kick(_ player: RconClient.Player) {
        rconCommand(t("%@ 강퇴", player.name), { try await self.rcon.kick(player.uid) })
    }

    func ban(_ player: RconClient.Player) {
        rconCommand(t("%@ 밴", player.name), { try await self.rcon.ban(player.uid) })
    }

    /// Flushes the save to disk without stopping the server.
    func saveWorld() {
        rconCommand(t("월드 저장"), { try await self.rcon.save() })
    }

    /// RCON commands finish in tens of milliseconds, so they don't lock the UI with
    /// busyMessage — only the result is logged.
    private func rconCommand(_ label: String, _ body: @escaping () async throws -> String) {
        Task {
            await prepareRcon()
            guard rconReady else {
                append(t("‼️ %@ 실패: RCON 비밀번호가 설정되지 않았습니다.", label))
                return
            }
            do {
                let reply = try await body()
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                append("✔︎ \(label): \(trimmed.isEmpty ? "완료" : trimmed)")
                await refreshPlayers()
            } catch {
                append(t("‼️ %@ 실패: %@", label, error.localizedDescription))
            }
        }
    }

    private func loadBackups() async {
        let dir = status.backupDirectoryPath
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { backups = []; return }

        backups = names
            .filter { $0.hasPrefix("palworld_backup_") && $0.hasSuffix(".tar.gz") }
            .compactMap { name in
                let path = (dir as NSString).appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: path)
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let date = BackupEntry.parseDate(from: name)
                    ?? (attrs?[.creationDate] as? Date) ?? .distantPast
                return BackupEntry(
                    filename: name,
                    size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    date: date,
                    label: BackupEntry.parseLabel(from: name)
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Actions

    func start()   { perform(t("서버 기동 중…"),   script: "start_server.sh") }
    func stop()    { perform(t("안전 종료 중…"),   script: "stop_server.sh") }
    /// With a name, the archive becomes `palworld_backup_<time>_<name>.tar.gz`, and
    /// named backups are excluded from automatic cleanup.
    func backup(named label: String = "") {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let args = trimmed.isEmpty ? [] : ["--name", trimmed]
        perform(t("백업 생성 중…"), script: "backup_save.sh", args: args)
    }

    /// Renames a backup. An empty string clears the name.
    func renameBackup(_ entry: BackupEntry, to newLabel: String) {
        perform(t("이름 변경 중…"), script: "backup_save.sh",
                args: ["--rename", entry.filename,
                       newLabel.trimmingCharacters(in: .whitespaces)])
    }
    func restart() { perform(t("재시작 중…"),      script: "auto_restart.sh") }
    func update()  { perform(t("서버 업데이트 중…"), script: "install_update.sh") }

    /// Restoring is hard to undo, so the UI must confirm before calling this.
    /// `--yes` rather than piping "y" into the prompt: that made the GUI depend on
    /// the exact wording and order of a shell `read`.
    func restore(_ filename: String) {
        perform(t("복원 중…"), script: "restore_save.sh", args: ["--yes", filename])
    }

    // MARK: - Game settings

    func loadSettings() async {
        guard let json = try? await run(script: "settings.sh", args: ["--json"], capture: true),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        settings = arr.map {
            GameSetting(
                key: $0["key"] as? String ?? "",
                type: $0["type"] as? String ?? "string",
                raw: $0["raw"] as? String ?? "",
                value: $0["value"] as? String ?? "",
                defaultValue: $0["default"] as? String,
                modified: $0["modified"] as? Bool ?? false
            )
        }
        pendingSettings.removeAll()
        // AdminPassword / RCONPort may have changed, so force credentials to reload.
        rconReady = false
    }

    /// Stages an edit. Setting it back to the original value removes it again.
    func stageSetting(_ key: String, _ newValue: String) {
        guard let original = settings.first(where: { $0.key == key }) else { return }
        if newValue == original.value {
            pendingSettings.removeValue(forKey: key)
        } else {
            pendingSettings[key] = newValue
        }
    }

    func discardPendingSettings() { pendingSettings.removeAll() }

    /// Reverts one item to its default. Staged rather than written immediately, so it
    /// can still be cancelled before Apply.
    func resetToDefault(_ key: String) {
        guard let item = settings.first(where: { $0.key == key }),
              let def = item.defaultValue else { return }
        stageSetting(key, def)
    }

    /// Reverts every item that differs from its default.
    /// - Parameter includeOperational: when true, also covers operational keys such as
    ///   AdminPassword and RCONEnabled. Reverting those drops safe shutdown back to
    ///   signals and risks save loss, hence the false default.
    /// - Returns: how many items were staged.
    @discardableResult
    func resetAllToDefaults(includeOperational: Bool = false) -> Int {
        var count = 0
        for item in settings {
            guard let def = item.defaultValue, def != item.value else { continue }
            if !includeOperational && SettingsCatalog.operationalKeys.contains(item.key) {
                continue
            }
            stageSetting(item.key, def)
            count += 1
        }
        return count
    }

    /// Count of items differing from defaults, excluding operational keys.
    var modifiedGameplayCount: Int {
        settings.filter {
            guard let def = $0.defaultValue else { return false }
            return def != $0.value && !SettingsCatalog.operationalKeys.contains($0.key)
        }.count
    }

    func applySettings() {
        guard !pendingSettings.isEmpty else { return }
        // settings.sh takes Key=Value arguments and rewrites only those keys.
        let args = pendingSettings.map { "\($0.key)=\($0.value)" }.sorted()
        let task = perform(t("설정 저장 중…"), script: "settings.sh", args: ["--set"] + args)
        Task {
            // Re-read from disk afterwards so the UI shows what was actually written.
            await task.value
            await loadSettings()
        }
    }

    @discardableResult
    private func perform(_ message: String, script: String,
                         args: [String] = [], stdin: String? = nil) -> Task<Void, Never> {
        guard !isBusy else { return Task<Void, Never> { } }
        busyMessage = message
        logLines.removeAll()
        append("$ ./\(script) \(args.joined(separator: " "))")

        return Task {
            do {
                _ = try await run(script: script, args: args, capture: false, stdin: stdin)
            } catch {
                append(t("‼️ 실행 실패: %@", error.localizedDescription))
            }
            busyMessage = nil
            await refresh()
        }
    }

    // MARK: - Process execution

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    /// Runs a script.
    ///
    /// [Important] Reading a Process pipe (`availableData`, `readDataToEndOfFile`) and
    /// `waitUntilExit()` are all **synchronous blocking** calls. This class is
    /// @MainActor, so running them inline would pin the main thread for the whole of a
    /// server start (up to 120s waiting for the port) or a safe shutdown (30s warning)
    /// and freeze the UI completely.
    /// The actual execution therefore happens on a background queue from a nonisolated
    /// function; only log appends and state updates hop back to the main actor.
    ///
    /// - Parameter capture: true returns stdout as a string (for status queries);
    ///                      false streams output into the log view as it arrives.
    @discardableResult
    private func run(script: String, args: [String], capture: Bool, stdin: String? = nil) async throws -> String {
        let dir = scriptsDirectory
        let path = (dir as NSString).appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "Palworld", code: 1, userInfo: [
                NSLocalizedDescriptionKey: t("스크립트를 찾을 수 없습니다: %@\n설정에서 스크립트 폴더를 지정하세요.", path)
            ])
        }

        // Only streaming mode gets a per-line callback. It is invoked on a background
        // queue, so it hops to the main queue to update @Published state.
        var onLine: (@Sendable (String) -> Void)?
        if !capture {
            onLine = { [weak self] line in
                // Called from a background queue; hop to main to touch @Published.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.append(line)
                    }
                }
            }
        }

        return try await Self.execute(path: path, args: args, cwd: dir, stdin: stdin, onLine: onLine)
    }

    /// The actual process run — blocking I/O, performed off the main actor.
    private nonisolated static func execute(
        path: String,
        args: [String],
        cwd: String,
        stdin: String?,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [path] + args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                // GUI apps don't go through a login shell, so PATH is minimal.
                // wine64 / lsof / python3 / tar need it spelled out explicitly.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["TERM"] = "dumb"    // suppress ANSI colour codes
                process.environment = env

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = outPipe

                if let stdin {
                    let inPipe = Pipe()
                    process.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    inPipe.fileHandleForWriting.closeFile()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let handle = outPipe.fileHandleForReading

                guard let onLine else {
                    // Capture mode: read the whole output at once and return it
                    let data = handle.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    return
                }

                // Streaming mode: hand each line to the callback
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if var line = String(data: lineData, encoding: .utf8) {
                            line = line.replacingOccurrences(
                                of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { onLine(trimmed) }
                        }
                    }
                }
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    onLine(t("종료 코드: %@", "\(process.terminationStatus)"))
                }
                continuation.resume(returning: "")
            }
        }
    }
}
