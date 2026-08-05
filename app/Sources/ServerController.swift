import Foundation
import SwiftUI

/// 셸 스크립트들을 실행하고 상태를 폴링하는 컨트롤러.
///
/// 설계 원칙: 서버 제어 로직은 전부 기존 .sh 스크립트에 있고, 이 클래스는
/// 그것을 호출하기만 합니다. 덕분에 터미널/cron 경로와 앱이 완전히 같은
/// 코드를 사용하며, 앱에서 한 동작이 CLI 에서도 동일하게 재현됩니다.
@MainActor
final class ServerController: ObservableObject {

    @Published private(set) var status: ServerStatus = .unknown
    @Published private(set) var backups: [BackupEntry] = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var busyMessage: String?

    /// 파일에서 읽어 온 게임 설정 원본.
    @Published private(set) var settings: [GameSetting] = []
    /// 사용자가 편집했지만 아직 파일에 쓰지 않은 값. [적용] 시 한 번에 반영합니다.
    @Published private(set) var pendingSettings: [String: String] = [:]

    /// 네이티브 RCON 으로 조회한 접속자. 셸 경유(260ms) 대신 직접 TCP(34ms).
    @Published private(set) var players: [RconClient.Player] = []
    /// 마지막 RCON 오류. 접속자 목록이 비는 이유를 UI 에서 알려 주기 위함입니다.
    @Published private(set) var rconError: String?

    /// 공인 IP. 외부 서비스에 요청이 나가므로 자동 조회하지 않고,
    /// 사용자가 버튼을 눌렀을 때만 가져옵니다.
    @Published private(set) var publicIP: String?
    @Published private(set) var isFetchingPublicIP = false

    private let rcon = RconClient()
    private var rconReady = false

    /// RCON `Info` 에서 뽑은 게임 버전 (예: "1.0.2.101103").
    /// 서버가 실행 중일 때만 알 수 있습니다.
    @Published private(set) var gameVersion: String?
    /// 설치 빌드와 Steam 최신 빌드 비교 결과.
    @Published private(set) var updateStatus: UpdateStatus?
    @Published private(set) var isCheckingUpdate = false
    @Published var scriptsDirectory: String {
        didSet { UserDefaults.standard.set(scriptsDirectory, forKey: "scriptsDirectory") }
    }

    var isBusy: Bool { busyMessage != nil }

    private var pollTask: Task<Void, Never>?

    init() {
        // 우선순위: 사용자가 앱에서 지정한 값 > 빌드 시 기록된 값 > 홈 기준 추정
        let stored = UserDefaults.standard.string(forKey: "scriptsDirectory")
        let baked = Bundle.main.object(forInfoDictionaryKey: "PWScriptsDirectory") as? String
        scriptsDirectory = stored ?? baked ?? NSHomeDirectory() + "/palworld-server"

        // 이 인스턴스의 수명과 폴링을 일치시킵니다. 자세한 이유는
        // PalworldServerApp 의 주석 참고.
        startPolling()
    }

    // MARK: - 폴링

    func startPolling() {
        // 이미 돌고 있으면 새로 만들지 않습니다 (중복 폴링 방지).
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            // 시작할 때 캐시된 업데이트 상태만 한 번 읽습니다 (네트워크 없음).
            // Steam 조회는 6초가 걸려 3초 폴링에 섞을 수 없으므로,
            // 실제 조회는 사용자가 [확인] 을 누를 때만 합니다.
            await self?.checkUpdate(cachedOnly: true)

            while !Task.isCancelled {
                // 컨트롤러가 사라졌으면 루프도 끝냅니다.
                // (self? 로 두면 인스턴스가 없어져도 루프가 계속 돌며 CPU 를 먹습니다)
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // 장시간 작업(기동/종료/재시작) 중에는 상태 조회를 건너뜁니다.
        // 폴링과 작업 출력이 뒤섞이는 것을 막고 불필요한 프로세스 생성도 줄입니다.
        guard !isBusy else { return }

        // --no-rcon: 접속자는 아래에서 네이티브로 조회하므로 셸 쪽 RCON 은 생략합니다.
        // (0.39초 → 0.14초)
        if let json = try? await run(script: "status.sh", args: ["--json", "--no-rcon"], capture: true),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ServerStatus.self, from: data) {
            status = decoded
        }

        await refreshPlayers()
        await loadBackups()
    }

    // MARK: - 접속 주소

    /// 공인 IP 를 조회합니다. 외부(api.ipify.org)로 요청이 나가므로
    /// 폴링에 섞지 않고 사용자가 명시적으로 요청할 때만 호출합니다.
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

    /// RCON 자격 증명은 PalWorldSettings.ini 의 AdminPassword / RCONPort 가 원본입니다.
    /// (실행 중인 서버가 실제로 검사하는 값이 그쪽이기 때문입니다.)
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
            // 서버가 내려가면 버전도 잊습니다. 다음 기동 때 다시 읽어야
            // 업데이트 후 바뀐 버전이 반영됩니다.
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

        // 게임 버전은 한 번만 알아내면 됩니다 (재기동 전까지 바뀌지 않음).
        if gameVersion == nil, let v = try? await rcon.info() {
            // "Welcome to Pal Server[v1.0.2.101103] 서버이름" 에서 버전만.
            // 서버가 한글 이름을 잘라 보내는 버그가 있지만 버전은 앞쪽이라 안전합니다.
            if let r = v.range(of: #"\[v[0-9.]+\]"#, options: .regularExpression) {
                gameVersion = String(v[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[v]"))
            }
        }
    }

    // MARK: - 업데이트 확인

    /// 설치 빌드와 Steam 최신 빌드를 비교합니다.
    /// - Parameter cachedOnly: true 면 네트워크를 타지 않고 캐시만 읽습니다(즉시).
    ///   상시 폴링에서 6초짜리 Steam 조회가 반복되지 않도록 하기 위함입니다.
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

    /// 백업 → 안전 종료 → 업데이트 → 재기동.
    func updateServer() {
        let task = perform(t("서버 업데이트 중…"), script: "auto_restart.sh", args: ["--update"])
        Task {
            await task.value
            await checkUpdate(force: true)
        }
    }

    /// 접속자 전원에게 공지를 보냅니다.
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

    /// 세이브만 즉시 플러시합니다 (서버는 계속 실행).
    func saveWorld() {
        rconCommand(t("월드 저장"), { try await self.rcon.save() })
    }

    /// RCON 명령은 수십 ms 면 끝나므로 busyMessage 로 UI 를 잠그지 않고,
    /// 결과만 로그에 남깁니다.
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
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("palworld_backups")
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

    // MARK: - 동작

    func start()   { perform(t("서버 기동 중…"),   script: "start_server.sh") }
    func stop()    { perform(t("안전 종료 중…"),   script: "stop_server.sh") }
    /// 이름을 주면 `palworld_backup_<시각>_<이름>.tar.gz` 로 만들어지고,
    /// 이름이 붙은 백업은 자동 정리에서 제외됩니다.
    func backup(named label: String = "") {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let args = trimmed.isEmpty ? [] : ["--name", trimmed]
        perform(t("백업 생성 중…"), script: "backup_save.sh", args: args)
    }

    /// 백업 이름 바꾸기. 빈 문자열을 주면 이름을 지웁니다.
    func renameBackup(_ entry: BackupEntry, to newLabel: String) {
        perform(t("이름 변경 중…"), script: "backup_save.sh",
                args: ["--rename", entry.filename,
                       newLabel.trimmingCharacters(in: .whitespaces)])
    }
    func restart() { perform(t("재시작 중…"),      script: "auto_restart.sh") }
    func update()  { perform(t("서버 업데이트 중…"), script: "install_update.sh") }

    /// 복원은 되돌리기 어려우므로 호출부(UI)에서 반드시 확인을 받은 뒤 부릅니다.
    func restore(_ filename: String) {
        perform(t("복원 중…"), script: "restore_save.sh", args: [filename], stdin: "y\n")
    }

    // MARK: - 게임 설정

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
        // AdminPassword / RCONPort 가 바뀌었을 수 있으므로 자격 증명을 다시 읽게 합니다.
        rconReady = false
    }

    /// 편집 값을 보류 목록에 담습니다. 원래 값으로 되돌리면 목록에서 빠집니다.
    func stageSetting(_ key: String, _ newValue: String) {
        guard let original = settings.first(where: { $0.key == key }) else { return }
        if newValue == original.value {
            pendingSettings.removeValue(forKey: key)
        } else {
            pendingSettings[key] = newValue
        }
    }

    func discardPendingSettings() { pendingSettings.removeAll() }

    /// 항목 하나를 기본값으로 되돌립니다.
    /// 즉시 파일에 쓰지 않고 '변경분'에만 담아, [적용] 전까지 취소할 수 있게 합니다.
    func resetToDefault(_ key: String) {
        guard let item = settings.first(where: { $0.key == key }),
              let def = item.defaultValue else { return }
        stageSetting(key, def)
    }

    /// 기본값과 다른 항목을 한꺼번에 되돌립니다.
    /// - Parameter includeOperational: true 면 AdminPassword·RCONEnabled 같은
    ///   운영 항목까지 포함합니다. 되돌리면 안전 종료가 시그널 방식으로 떨어져
    ///   세이브 유실 위험이 생기므로 기본값은 false 입니다.
    /// - Returns: 되돌릴 항목 수
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

    /// 기본값과 다른 항목 수 (운영 항목 제외).
    var modifiedGameplayCount: Int {
        settings.filter {
            guard let def = $0.defaultValue else { return false }
            return def != $0.value && !SettingsCatalog.operationalKeys.contains($0.key)
        }.count
    }

    func applySettings() {
        guard !pendingSettings.isEmpty else { return }
        // settings.sh 가 Key=Value 인자를 받아 '요청한 키만' 정밀 치환합니다.
        let args = pendingSettings.map { "\($0.key)=\($0.value)" }.sorted()
        let task = perform(t("설정 저장 중…"), script: "settings.sh", args: ["--set"] + args)
        Task {
            // 저장이 끝난 뒤 파일에서 다시 읽어 실제 반영 결과를 보여 줍니다.
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

    // MARK: - 프로세스 실행

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    /// 스크립트를 실행합니다.
    ///
    /// [중요] Process 의 파이프 읽기(`availableData`, `readDataToEndOfFile`)와
    /// `waitUntilExit()` 는 모두 **동기 블로킹** 호출입니다. 이 클래스는 @MainActor 라서
    /// 그대로 실행하면 서버 기동(포트 대기 최대 120초)이나 안전 종료(30초 예고) 동안
    /// 메인 스레드가 잡혀 UI 가 통째로 얼어붙습니다.
    /// 그래서 실제 실행은 nonisolated 함수에서 백그라운드 큐로 넘기고,
    /// 로그 추가·상태 갱신만 메인 액터로 돌아와 처리합니다.
    ///
    /// - Parameter capture: true 면 stdout 을 문자열로 반환(상태 조회용),
    ///                      false 면 출력을 실시간으로 로그 창에 흘려보냅니다.
    @discardableResult
    private func run(script: String, args: [String], capture: Bool, stdin: String? = nil) async throws -> String {
        let dir = scriptsDirectory
        let path = (dir as NSString).appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "Palworld", code: 1, userInfo: [
                NSLocalizedDescriptionKey: t("스크립트를 찾을 수 없습니다: %@\n설정에서 스크립트 폴더를 지정하세요.", path)
            ])
        }

        // 스트리밍 모드일 때만 줄 단위 콜백을 넘깁니다.
        // 콜백은 백그라운드에서 불리므로 메인 액터로 되돌려 @Published 를 갱신합니다.
        var onLine: (@Sendable (String) -> Void)?
        if !capture {
            onLine = { [weak self] line in
                // 백그라운드 큐에서 불리므로 메인 큐로 넘겨 @Published 를 갱신합니다.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.append(line)
                    }
                }
            }
        }

        return try await Self.execute(path: path, args: args, cwd: dir, stdin: stdin, onLine: onLine)
    }

    /// 실제 프로세스 실행. 메인 액터 밖에서 블로킹 I/O 를 수행합니다.
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

                // GUI 앱은 로그인 셸을 거치지 않아 PATH 가 최소입니다.
                // wine64 / lsof / python3 / tar 를 찾으려면 명시적으로 넣어야 합니다.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["TERM"] = "dumb"    // 색 코드 억제
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
                    // 캡처 모드: 전체 출력을 한 번에 읽어 반환
                    let data = handle.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    return
                }

                // 스트리밍 모드: 줄 단위로 콜백에 넘김
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
