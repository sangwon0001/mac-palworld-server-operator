import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: ServerController
    @ObservedObject private var l10n = Localization.shared
    @State private var restoreTarget: BackupEntry?
    @State private var showSettings = false
    @State private var tab: Tab = .dashboard
    @State private var broadcastText = ""
    @State private var kickTarget: RconClient.Player?
    @State private var banTarget: RconClient.Player?
    @State private var showUpdateConfirm = false
    @State private var backupName = ""
    @State private var renameTarget: BackupEntry?
    @State private var renameText = ""

    enum Tab: String, CaseIterable {
        case dashboard = "대시보드"
        case game      = "게임 설정"
        var icon: String { self == .dashboard ? "gauge" : "slider.horizontal.3" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $tab) {
                // 루프 변수를 t 로 두면 번역 함수 t() 를 가려 버립니다.
                ForEach(Tab.allCases, id: \.self) { tab in
                    Label(t(tab.rawValue), systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .dashboard:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        metrics
                        versionSection
                        addressSection
                        actions
                        playersSection
                        backupsSection
                        logSection
                    }
                    .padding(20)
                }
            case .game:
                GameSettingsView().environmentObject(controller)
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(item: $renameTarget) { target in
            VStack(alignment: .leading, spacing: 14) {
                Text(t("백업 이름 바꾸기")).font(.title3.bold())
                Text(target.filename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                TextField(t("이름 (비우면 이름 없음)"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        controller.renameBackup(target, to: renameText)
                        renameTarget = nil
                    }

                Text(t("이름을 붙이면 보관 기간이 지나도 자동으로 삭제되지 않습니다. 비우면 다시 자동 정리 대상이 됩니다."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
                HStack {
                    Spacer()
                    Button(t("취소")) { renameTarget = nil }
                    Button(t("변경")) {
                        controller.renameBackup(target, to: renameText)
                        renameTarget = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460, height: 230)
        }
        .confirmationDialog(
            t("이 백업으로 복원할까요?"),
            isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(t("복원"), role: .destructive) {
                if let target = restoreTarget { controller.restore(target.filename) }
                restoreTarget = nil
            }
            Button(t("취소"), role: .cancel) { restoreTarget = nil }
        } message: {
            Text(t("%@\n\n현재 세이브를 덮어씁니다. 복원 직전 상태는 prerestore_*.tar.gz 로 자동 저장되므로 되돌릴 수 있습니다. 서버가 켜져 있으면 먼저 종료해야 합니다.",
                   restoreTarget?.filename ?? ""))
        }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let busy = controller.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }

            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help(t("설정"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusColor: Color {
        guard controller.status.running else { return .secondary }
        return controller.status.portBound ? .green : .orange
    }

    private var statusTitle: String {
        guard controller.status.running else { return t("정지됨") }
        return controller.status.portBound ? t("실행 중") : t("기동 중 (포트 대기)")
    }

    private var statusSubtitle: String {
        let s = controller.status
        guard s.running else { return t("시작 버튼을 눌러 서버를 켜세요") }
        return t("PID %@ · 가동 %@ · UDP %@", "\(s.pid)", s.uptime, "\(s.gamePort)")
    }

    // MARK: - 지표

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            MetricCard(title: "CPU", value: String(format: "%.1f%%", controller.status.cpuPercent),
                       icon: "cpu")
            MetricCard(title: t("메모리"), value: memoryText, icon: "memorychip",
                       tint: memoryTint, note: memoryNote)
            MetricCard(title: t("접속자"), value: t("%@명", "\(controller.players.count)"),
                       icon: "person.2")
            MetricCard(title: t("세이브"), value: controller.status.saveSizeText, icon: "externaldrive")
            MetricCard(title: t("게임 포트"),
                       value: controller.status.portBound ? t("열림") : t("닫힘"),
                       icon: "network",
                       tint: controller.status.portBound ? .green : .secondary,
                       note: "UDP \(controller.status.gamePort)")
            MetricCard(title: "RCON",
                       value: controller.status.rconListening ? t("연결됨") : t("꺼짐"),
                       icon: "terminal",
                       tint: controller.status.rconListening ? .green : .secondary,
                       note: "TCP \(controller.status.rconPort)")
        }
    }

    private var memoryText: String {
        let mb = controller.status.memoryMB
        return mb >= 1024 ? String(format: "%.2f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    private var memoryTint: Color {
        switch controller.status.memoryLevel {
        case .normal: return .primary
        case .elevated: return .orange
        case .critical: return .red
        }
    }

    private var memoryNote: String? {
        switch controller.status.memoryLevel {
        case .normal: return nil
        case .elevated: return t("누수 진행 가능")
        case .critical: return t("재시작 권장")
        }
    }

    // MARK: - 접속 주소

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(t("접속 주소"))

            VStack(spacing: 0) {
                if let lan = controller.status.lanAddress {
                    AddressRow(label: t("같은 공유기 안"), address: lan, note: nil)
                    Divider()
                }
                if let host = controller.status.hostnameAddress {
                    AddressRow(label: t("같은 공유기 안"), address: host,
                               note: t("IP 가 바뀌어도 계속 통합니다"))
                    Divider()
                }

                // 공인 IP 는 외부 서비스에 요청이 나가므로 누를 때만 조회합니다.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("외부 (인터넷)")).font(.caption).foregroundStyle(.secondary)
                        if let pub = controller.publicIP {
                            Text("\(pub):\(controller.status.gamePort)")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(t("공유기에서 UDP %@ 포트포워딩이 되어 있어야 합니다", "\(controller.status.gamePort)"))
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text(t("아직 조회하지 않음"))
                                .font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if controller.isFetchingPublicIP {
                        ProgressView().controlSize(.small)
                    } else if let pub = controller.publicIP {
                        Button(t("복사")) { copy("\(pub):\(controller.status.gamePort)") }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button(t("공인 IP 조회")) { controller.fetchPublicIP() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            if !controller.status.portBound {
                Text(t("서버가 꺼져 있어 지금은 접속할 수 없습니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 동작 버튼

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(t("제어"))
            HStack(spacing: 10) {
                Button {
                    controller.status.running ? controller.stop() : controller.start()
                } label: {
                    Label(controller.status.running ? t("안전 종료") : t("서버 시작"),
                          systemImage: controller.status.running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.status.running ? .red : .green)
                .controlSize(.large)

                Button {
                    controller.restart()
                } label: {
                    Label(t("재시작"), systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!controller.status.running)

                Button {
                    controller.backup(named: backupName)
                    backupName = ""
                } label: {
                    Label(t("지금 백업"), systemImage: "archivebox").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .disabled(controller.isBusy)

            if controller.status.running && !controller.status.rconConfigured {
                Label(t("RCON 미설정 — 안전 종료 대신 시그널 종료가 사용됩니다."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 버전 · 업데이트

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(t("버전"))

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(controller.gameVersion.map { "v\($0)" } ?? t("버전 미확인"))
                            .font(.callout.weight(.medium))
                        if let u = controller.updateStatus, u.updateAvailable {
                            Text(t("업데이트 있음"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    if controller.gameVersion == nil {
                        Text(t("서버가 실행 중일 때 RCON 으로 읽어 옵니다"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }

                    if !controller.status.installedBuild.isEmpty {
                        Text(t("설치 빌드 %@", controller.status.installedBuild)
                             + (controller.updateStatus.map { u in
                                 u.updateAvailable ? t(" → 최신 %@", u.latestBuild) : ""
                               } ?? ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if let checked = controller.updateStatus?.checkedAtText {
                        Text(t("마지막 확인 %@", checked))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        Task { await controller.checkUpdate(force: true) }
                    } label: {
                        if controller.isCheckingUpdate {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(t("확인 중…"))
                            }
                        } else {
                            Text(t("업데이트 확인"))
                        }
                    }
                    .disabled(controller.isCheckingUpdate || controller.isBusy)

                    if let u = controller.updateStatus, u.updateAvailable {
                        Button(t("지금 업데이트")) { showUpdateConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(controller.isBusy)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
        .confirmationDialog(t("지금 업데이트할까요?"),
                            isPresented: $showUpdateConfirm, titleVisibility: .visible) {
            Button(t("업데이트")) { controller.updateServer() }
            Button(t("취소"), role: .cancel) { }
        } message: {
            Text(t("세이브를 백업하고 서버를 안전하게 종료한 뒤, 최신 버전을 내려받아 다시 기동합니다. 접속자가 있으면 종료 예고 후 끊깁니다.\n\n백업이 실패하면 업데이트를 진행하지 않고 중단합니다."))
        }
    }

    // MARK: - 접속자 (네이티브 RCON)

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(t("접속자 (%@)", "\(controller.players.count)"))

            if !controller.status.running {
                Text(t("서버가 꺼져 있습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let err = controller.rconError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if controller.players.isEmpty {
                Text(t("접속 중인 플레이어가 없습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.players) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.callout)
                                Text("UID \(p.uid)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(t("강퇴")) { kickTarget = p }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button(t("밴")) { banTarget = p }
                                .buttonStyle(.bordered).controlSize(.small)
                                .tint(.red)
                        }
                        .padding(.vertical, 7)
                        if p.id != controller.players.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            // 공지 방송
            HStack(spacing: 8) {
                TextField(t("전체 공지 보내기"), text: $broadcastText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendBroadcast)
                Button(t("전송"), action: sendBroadcast)
                    .disabled(broadcastText.trimmingCharacters(in: .whitespaces).isEmpty
                              || !controller.status.running)
            }
            Text(t("공백은 밑줄(_)로 바뀌어 전송됩니다 — 팰월드 RCON 이 공백을 인자 구분자로 취급하기 때문입니다. 또한 서버가 한글 등 비ASCII 문자를 잘라 보내는 버그가 있어, 공지는 영문·숫자로 쓰시는 편이 확실합니다."))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.saveWorld()
            } label: {
                Label(t("지금 월드 저장 (서버는 계속 실행)"), systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .disabled(!controller.status.running)
        }
        .confirmationDialog(t("이 플레이어를 강퇴할까요?"),
                            isPresented: Binding(get: { kickTarget != nil },
                                                 set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            Button(t("강퇴"), role: .destructive) {
                if let p = kickTarget { controller.kick(p) }
                kickTarget = nil
            }
            Button(t("취소"), role: .cancel) { kickTarget = nil }
        } message: {
            Text(t("%@ — 다시 접속할 수 있습니다.", kickTarget?.name ?? ""))
        }
        .confirmationDialog(t("이 플레이어를 밴할까요?"),
                            isPresented: Binding(get: { banTarget != nil },
                                                 set: { if !$0 { banTarget = nil } }),
                            titleVisibility: .visible) {
            Button(t("밴"), role: .destructive) {
                if let p = banTarget { controller.ban(p) }
                banTarget = nil
            }
            Button(t("취소"), role: .cancel) { banTarget = nil }
        } message: {
            Text(t("%@ — 다시 접속할 수 없게 됩니다.", banTarget?.name ?? ""))
        }
    }

    private func sendBroadcast() {
        controller.broadcast(broadcastText)
        broadcastText = ""
    }

    // MARK: - 백업

    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(t("백업 (%@)", "\(controller.backups.count)"))
                Spacer()
                Button(t("폴더 열기")) {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory() + "/palworld_backups"))
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // 이름을 붙이면 자동 정리에서 제외되므로, 중요한 시점을 남길 때 씁니다.
            HStack(spacing: 8) {
                TextField(t("백업 이름 (선택) — 예: 보스전 직전"), text: $backupName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        controller.backup(named: backupName)
                        backupName = ""
                    }
                if !backupName.isEmpty {
                    Text(t("자동 삭제 안 됨"))
                        .font(.caption2).foregroundStyle(.green)
                }
            }

            if controller.backups.isEmpty {
                Text(t("백업이 없습니다. '지금 백업'을 눌러 첫 백업을 만드세요."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.backups.prefix(6)) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(b.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.callout)
                                    if b.isKept {
                                        Text(b.label)
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.green.opacity(0.18), in: Capsule())
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(b.isKept ? t("%@ · 자동 삭제 안 됨", b.size) : b.size)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(t("이름")) {
                                renameTarget = b
                                renameText = b.label
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(controller.isBusy)

                            Button(t("복원")) { restoreTarget = b }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                // 실행 중 복원은 즉시 덮어써지므로 막습니다.
                                .disabled(controller.isBusy || controller.status.running)
                        }
                        .padding(.vertical, 7)
                        if b.id != controller.backups.prefix(6).last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                if controller.status.running {
                    Text(t("복원하려면 먼저 서버를 종료하세요."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 로그

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(t("실행 로그"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 150)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: controller.logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - 설정

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("설정")).font(.title3.bold())

            // 언어 선택. .lproj 번들을 직접 열어 조회하므로 재시작 없이 즉시 바뀝니다.
            VStack(alignment: .leading, spacing: 6) {
                Text(t("언어")).font(.callout)
                Picker("", selection: Binding(
                    get: { l10n.language },
                    set: { l10n.setLanguage($0) }
                )) {
                    ForEach(Localization.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(t("스크립트 폴더")).font(.callout)
                Text(t("start_server.sh 등이 들어 있는 폴더입니다. 앱은 이 스크립트들을 그대로 실행합니다."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $controller.scriptsDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Button(t("선택…")) { chooseDirectory() }
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button(t("닫기")) { showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 320)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.scriptsDirectory = url.path
        }
    }
}

// MARK: - 구성 요소

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// 접속 주소 한 줄 — 주소를 그대로 보여 주고 복사 버튼을 답니다.
private struct AddressRow: View {
    let label: String
    let address: String
    let note: String?

    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(address)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(copied ? t("복사됨") : t("복사")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .primary
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
            if let note {
                Text(note).font(.caption2).foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
