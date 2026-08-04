import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: ServerController
    @State private var restoreTarget: BackupEntry?
    @State private var showSettings = false
    @State private var tab: Tab = .dashboard
    @State private var broadcastText = ""
    @State private var kickTarget: RconClient.Player?
    @State private var banTarget: RconClient.Player?

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
                ForEach(Tab.allCases, id: \.self) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
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
        .confirmationDialog(
            "이 백업으로 복원할까요?",
            isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("복원", role: .destructive) {
                if let t = restoreTarget { controller.restore(t.filename) }
                restoreTarget = nil
            }
            Button("취소", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("""
            \(restoreTarget?.filename ?? "")

            현재 세이브를 덮어씁니다. 복원 직전 상태는 prerestore_*.tar.gz 로 \
            자동 저장되므로 되돌릴 수 있습니다. 서버가 켜져 있으면 먼저 종료해야 합니다.
            """)
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
                .help("설정")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusColor: Color {
        guard controller.status.running else { return .secondary }
        return controller.status.portBound ? .green : .orange
    }

    private var statusTitle: String {
        guard controller.status.running else { return "정지됨" }
        return controller.status.portBound ? "실행 중" : "기동 중 (포트 대기)"
    }

    private var statusSubtitle: String {
        let s = controller.status
        guard s.running else { return "시작 버튼을 눌러 서버를 켜세요" }
        return "PID \(s.pid) · 가동 \(s.uptime) · UDP \(s.gamePort)"
    }

    // MARK: - 지표

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            MetricCard(title: "CPU", value: String(format: "%.1f%%", controller.status.cpuPercent),
                       icon: "cpu")
            MetricCard(title: "메모리", value: memoryText, icon: "memorychip",
                       tint: memoryTint, note: memoryNote)
            MetricCard(title: "접속자", value: "\(controller.players.count)명",
                       icon: "person.2")
            MetricCard(title: "세이브", value: controller.status.saveSizeText, icon: "externaldrive")
            MetricCard(title: "게임 포트",
                       value: controller.status.portBound ? "열림" : "닫힘",
                       icon: "network",
                       tint: controller.status.portBound ? .green : .secondary,
                       note: "UDP \(controller.status.gamePort)")
            MetricCard(title: "RCON",
                       value: controller.status.rconListening ? "연결됨" : "꺼짐",
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
        case .elevated: return "누수 진행 가능"
        case .critical: return "재시작 권장"
        }
    }

    // MARK: - 동작 버튼

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("제어")
            HStack(spacing: 10) {
                Button {
                    controller.status.running ? controller.stop() : controller.start()
                } label: {
                    Label(controller.status.running ? "안전 종료" : "서버 시작",
                          systemImage: controller.status.running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.status.running ? .red : .green)
                .controlSize(.large)

                Button {
                    controller.restart()
                } label: {
                    Label("재시작", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!controller.status.running)

                Button {
                    controller.backup()
                } label: {
                    Label("지금 백업", systemImage: "archivebox").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .disabled(controller.isBusy)

            if controller.status.running && !controller.status.rconConfigured {
                Label("RCON 미설정 — 안전 종료 대신 시그널 종료가 사용됩니다.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 접속자 (네이티브 RCON)

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("접속자 (\(controller.players.count))")

            if !controller.status.running {
                Text("서버가 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let err = controller.rconError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if controller.players.isEmpty {
                Text("접속 중인 플레이어가 없습니다.")
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
                            Button("강퇴") { kickTarget = p }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button("밴") { banTarget = p }
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
                TextField("전체 공지 보내기", text: $broadcastText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendBroadcast)
                Button("전송", action: sendBroadcast)
                    .disabled(broadcastText.trimmingCharacters(in: .whitespaces).isEmpty
                              || !controller.status.running)
            }
            Text("공백은 밑줄(_)로 바뀌어 전송됩니다 — 팰월드 RCON 이 공백을 인자 구분자로 "
                 + "취급하기 때문입니다. 또한 서버가 한글 등 비ASCII 문자를 잘라 보내는 "
                 + "버그가 있어, 공지는 영문·숫자로 쓰시는 편이 확실합니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.saveWorld()
            } label: {
                Label("지금 월드 저장 (서버는 계속 실행)", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .disabled(!controller.status.running)
        }
        .confirmationDialog("이 플레이어를 강퇴할까요?",
                            isPresented: Binding(get: { kickTarget != nil },
                                                 set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            Button("강퇴", role: .destructive) {
                if let p = kickTarget { controller.kick(p) }
                kickTarget = nil
            }
            Button("취소", role: .cancel) { kickTarget = nil }
        } message: {
            Text("\(kickTarget?.name ?? "") — 다시 접속할 수 있습니다.")
        }
        .confirmationDialog("이 플레이어를 밴할까요?",
                            isPresented: Binding(get: { banTarget != nil },
                                                 set: { if !$0 { banTarget = nil } }),
                            titleVisibility: .visible) {
            Button("밴", role: .destructive) {
                if let p = banTarget { controller.ban(p) }
                banTarget = nil
            }
            Button("취소", role: .cancel) { banTarget = nil }
        } message: {
            Text("\(banTarget?.name ?? "") — 다시 접속할 수 없게 됩니다.")
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
                SectionTitle("백업 (\(controller.backups.count))")
                Spacer()
                Button("폴더 열기") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory() + "/palworld_backups"))
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if controller.backups.isEmpty {
                Text("백업이 없습니다. '지금 백업'을 눌러 첫 백업을 만드세요.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.backups.prefix(6)) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                                Text(b.size).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("복원") { restoreTarget = b }
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
                    Text("복원하려면 먼저 서버를 종료하세요.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 로그

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("실행 로그")
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
            Text("설정").font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("스크립트 폴더").font(.callout)
                Text("start_server.sh 등이 들어 있는 폴더입니다. 앱은 이 스크립트들을 그대로 실행합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $controller.scriptsDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Button("선택…") { chooseDirectory() }
                }
            }

            Spacer()
            HStack {
                Spacer()
                Button("닫기") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 220)
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
