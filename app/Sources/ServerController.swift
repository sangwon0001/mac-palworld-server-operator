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

    private let rcon = RconClient()
    private var rconReady = false
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
    }

    /// 접속자 전원에게 공지를 보냅니다.
    func broadcast(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        rconCommand("공지 전송", { try await self.rcon.broadcast(text) })
    }

    func kick(_ player: RconClient.Player) {
        rconCommand("\(player.name) 강퇴", { try await self.rcon.kick(player.uid) })
    }

    func ban(_ player: RconClient.Player) {
        rconCommand("\(player.name) 밴", { try await self.rcon.ban(player.uid) })
    }

    /// 세이브만 즉시 플러시합니다 (서버는 계속 실행).
    func saveWorld() {
        rconCommand("월드 저장", { try await self.rcon.save() })
    }

    /// RCON 명령은 수십 ms 면 끝나므로 busyMessage 로 UI 를 잠그지 않고,
    /// 결과만 로그에 남깁니다.
    private func rconCommand(_ label: String, _ body: @escaping () async throws -> String) {
        Task {
            await prepareRcon()
            guard rconReady else {
                append("‼️ \(label) 실패: RCON 비밀번호가 설정되지 않았습니다.")
                return
            }
            do {
                let reply = try await body()
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                append("✔︎ \(label): \(trimmed.isEmpty ? "완료" : trimmed)")
                await refreshPlayers()
            } catch {
                append("‼️ \(label) 실패: \(error.localizedDescription)")
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
                    date: date
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - 동작

    func start()   { perform("서버 기동 중…",   script: "start_server.sh") }
    func stop()    { perform("안전 종료 중…",   script: "stop_server.sh") }
    func backup()  { perform("백업 생성 중…",   script: "backup_save.sh") }
    func restart() { perform("재시작 중…",      script: "auto_restart.sh") }
    func update()  { perform("서버 업데이트 중…", script: "install_update.sh") }

    /// 복원은 되돌리기 어려우므로 호출부(UI)에서 반드시 확인을 받은 뒤 부릅니다.
    func restore(_ filename: String) {
        perform("복원 중…", script: "restore_save.sh", args: [filename], stdin: "y\n")
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

    func applySettings() {
        guard !pendingSettings.isEmpty else { return }
        // settings.sh 가 Key=Value 인자를 받아 '요청한 키만' 정밀 치환합니다.
        let args = pendingSettings.map { "\($0.key)=\($0.value)" }.sorted()
        let task = perform("설정 저장 중…", script: "settings.sh", args: ["--set"] + args)
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
                append("‼️ 실행 실패: \(error.localizedDescription)")
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
                NSLocalizedDescriptionKey: "스크립트를 찾을 수 없습니다: \(path)\n설정에서 스크립트 폴더를 지정하세요."
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
                    onLine("종료 코드: \(process.terminationStatus)")
                }
                continuation.resume(returning: "")
            }
        }
    }
}
