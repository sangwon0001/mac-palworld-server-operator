import SwiftUI

/// 게임 설정(PalWorldSettings.ini) 편집 화면.
///
/// 편집 내용은 즉시 저장하지 않고 '변경분'으로 모아 두었다가 [적용] 시 한 번에
/// `settings.sh --set` 으로 넘깁니다. 실수로 값을 스쳤을 때 파일이 더럽혀지는 걸
/// 막고, 무엇이 바뀔지 미리 보여 주기 위함입니다.
struct GameSettingsView: View {
    @EnvironmentObject var controller: ServerController

    @State private var category: SettingMeta.Category = .server
    @State private var search: String = ""
    @State private var showApplyConfirm = false
    @State private var showResetAllConfirm = false

    var body: some View {
        // [주의] 여기서 HSplitView 를 쓰면 안 됩니다.
        // HSplitView 는 자식에게 폭을 제안하고 결과에 따라 다시 제안하는데,
        // 아래 목록에 '폭에 따라 높이가 정해지는' 줄(fixedSize 로 여러 줄 감싸는
        // 설명 텍스트)이 섞이면 제안이 수렴하지 않고 무한 재계산에 빠집니다.
        // 실제로 메인 스레드가 sizeThatFits 안에서 100% 를 태우며 멈췄습니다.
        // 사이드바 폭을 고정하면 그 순환 자체가 사라집니다.
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 700, minHeight: 560)
        .task { await controller.loadSettings() }
        .confirmationDialog("변경 내용을 적용할까요?",
                            isPresented: $showApplyConfirm, titleVisibility: .visible) {
            Button("적용") { controller.applySettings() }
            Button("취소", role: .cancel) { }
        } message: {
            Text(applySummary)
        }
        .confirmationDialog("운영 항목까지 전부 기본값으로 되돌릴까요?",
                            isPresented: $showResetAllConfirm, titleVisibility: .visible) {
            Button("전부 되돌리기", role: .destructive) {
                controller.resetAllToDefaults(includeOperational: true)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("""
            관리자 비밀번호가 지워지고 RCON 이 꺼집니다. 그러면 안전 종료가 \
            시그널 방식으로 바뀌어 세이브가 유실될 위험이 생기고, 서버 이름과 \
            포트 설정도 초기화됩니다.

            변경분은 [적용] 을 누르기 전까지 파일에 쓰이지 않으므로 \
            [되돌리기] 로 취소할 수 있습니다.
            """)
        }
    }

    // MARK: - 좌측 분류

    private var sidebar: some View {
        List(selection: $category) {
            ForEach(SettingMeta.Category.allCases, id: \.self) { c in
                let n = count(in: c)
                Label {
                    HStack {
                        Text(c.rawValue)
                        Spacer()
                        if n > 0 {
                            Text("\(n)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: c.icon)
                }
                .tag(c)
            }
        }
        .listStyle(.sidebar)
    }

    private func count(in c: SettingMeta.Category) -> Int {
        controller.settings.filter { SettingsCatalog.meta(for: $0.key).category == c }.count
    }

    // MARK: - 우측 편집 영역

    private var detail: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if controller.settings.isEmpty {
                ContentUnavailableView(
                    "설정을 불러올 수 없습니다",
                    systemImage: "doc.questionmark",
                    description: Text("서버를 한 번 설치·기동해야 PalWorldSettings.ini 가 생성됩니다.")
                )
            } else {
                ScrollView {
                    // LazyVStack 이 아니라 VStack 을 씁니다.
                    // Lazy 계열은 스크롤 위치에 따라 자식을 늘렸다 줄이며 크기를
                    // 다시 재는데, 그 과정이 위의 폭 제안과 얽혀 재계산이 반복됩니다.
                    // 한 분류에 많아야 26개(검색 시 최대 119개)라 전부 그려도
                    // 부담이 없으므로 지연 생성의 이점보다 안정성을 택합니다.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { item in
                            SettingRow(item: item,
                                       pending: controller.pendingSettings[item.key],
                                       onChange: { controller.stageSetting(item.key, $0) },
                                       onReset: { controller.resetToDefault(item.key) })
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            if !controller.pendingSettings.isEmpty { footer }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("설정 검색 (한글 이름 또는 키)", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)

            Menu {
                Button("게임플레이 값만 기본값으로 (\(controller.modifiedGameplayCount)개)") {
                    controller.resetAllToDefaults()
                }
                .disabled(controller.modifiedGameplayCount == 0)

                Divider()

                Button("운영 항목까지 전부 기본값으로…", role: .destructive) {
                    showResetAllConfirm = true
                }
            } label: {
                Label("기본값 복구", systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("기본값과 다른 항목을 되돌립니다 (적용 전까지 취소 가능)")

            Button {
                Task { await controller.loadSettings() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("파일에서 다시 읽기 (변경분 버림)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 검색어가 있으면 분류를 무시하고 전체에서 찾습니다.
    private var visible: [GameSetting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.isEmpty else {
            return controller.settings.filter {
                $0.key.lowercased().contains(q)
                || SettingsCatalog.meta(for: $0.key).label.lowercased().contains(q)
            }
        }
        return controller.settings.filter {
            SettingsCatalog.meta(for: $0.key).category == category
        }
    }

    private var applySummary: String {
        controller.pendingSettings
            .sorted { $0.key < $1.key }
            .map { "\(SettingsCatalog.meta(for: $0.key).label): \($0.value)" }
            .joined(separator: "\n")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(controller.pendingSettings.count)개 변경됨")
                    .font(.callout.weight(.medium))

                if controller.status.running {
                    Label("적용하려면 서버 재시작이 필요합니다",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                Spacer()

                Button("되돌리기") { controller.discardPendingSettings() }
                Button("적용") { showApplyConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
    }
}

// MARK: - 개별 설정 행

private struct SettingRow: View {
    let item: GameSetting
    let pending: String?
    let onChange: (String) -> Void
    let onReset: () -> Void

    private var meta: SettingMeta { SettingsCatalog.meta(for: item.key) }
    private var current: String { pending ?? item.value }
    private var isDirty: Bool { pending != nil }

    /// 지금 값이 기본값과 다른가 (편집 중인 값 기준).
    private var differsFromDefault: Bool {
        guard let def = item.defaultValue else { return false }
        return def != current
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meta.label).font(.callout)
                    if isDirty {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                if meta.label != item.key {
                    Text(item.key)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let help = meta.help {
                    Text(help).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 기본값과 다를 때만 되돌리기 버튼을 보여 줍니다.
                if differsFromDefault, let def = item.defaultValue {
                    Button {
                        onReset()
                    } label: {
                        Label("기본값 \(def.isEmpty ? "(빈값)" : def) 으로",
                              systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                    }
                    .buttonStyle(.link)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control.frame(width: 210, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var control: some View {
        switch item.type {
        case "bool":
            Toggle("", isOn: Binding(
                get: { current.lowercased() == "true" },
                set: { onChange($0 ? "True" : "False") }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

        case "float":
            VStack(alignment: .trailing, spacing: 2) {
                if let r = meta.range {
                    Slider(value: Binding(
                        get: { Double(current) ?? r.lowerBound },
                        set: { onChange(String(format: "%.6f", $0)) }
                    ), in: r)
                }
                TextField("", text: Binding(
                    get: { trimFloat(current) },
                    set: { onChange($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            }

        case "int":
            TextField("", text: Binding(get: { current }, set: { onChange($0) }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)

        case "enum":
            if let opts = meta.options {
                Picker("", selection: Binding(get: { current }, set: { onChange($0) })) {
                    ForEach(opts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            } else {
                TextField("", text: Binding(get: { current }, set: { onChange($0) }))
                    .textFieldStyle(.roundedBorder)
            }

        default:  // string, tuple
            if item.key == "AdminPassword" || item.key == "ServerPassword" {
                SecureField("", text: Binding(get: { current }, set: { onChange($0) }))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: Binding(get: { current }, set: { onChange($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// 1.000000 처럼 꼬리가 긴 값을 1 로 줄여 보여 줍니다.
    private func trimFloat(_ s: String) -> String {
        guard let d = Double(s) else { return s }
        return d == d.rounded() && abs(d) < 1e9
            ? String(Int(d))
            : String(format: "%g", d)
    }
}
