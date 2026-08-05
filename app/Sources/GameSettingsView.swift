import SwiftUI

/// Editor for the game settings in PalWorldSettings.ini.
///
/// Edits are staged rather than saved immediately, then handed to `settings.sh --set`
/// in one batch on Apply. That keeps a stray slider nudge from dirtying the file and
/// lets the user see exactly what will change.
struct GameSettingsView: View {
    @EnvironmentObject var controller: ServerController

    @State private var category: SettingMeta.Category = .server
    @State private var search: String = ""
    @State private var showApplyConfirm = false
    @State private var showResetAllConfirm = false

    var body: some View {
        // [Do not use HSplitView here.]
        // HSplitView proposes a width to its children and re-proposes based on the
        // result. When the list contains rows whose height depends on width (the
        // wrapping help text with fixedSize), the proposals never converge and layout
        // recalculates forever — the main thread was observed pinned at 100% inside
        // sizeThatFits. Fixing the sidebar width removes the cycle entirely.
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 700, minHeight: 560)
        .task { await controller.loadSettings() }
        .confirmationDialog(t("변경 내용을 적용할까요?"),
                            isPresented: $showApplyConfirm, titleVisibility: .visible) {
            Button(t("적용")) { controller.applySettings() }
            Button(t("취소"), role: .cancel) { }
        } message: {
            Text(applySummary)
        }
        .confirmationDialog(t("운영 항목까지 전부 기본값으로 되돌릴까요?"),
                            isPresented: $showResetAllConfirm, titleVisibility: .visible) {
            Button(t("전부 되돌리기"), role: .destructive) {
                controller.resetAllToDefaults(includeOperational: true)
            }
            Button(t("취소"), role: .cancel) { }
        } message: {
            Text(t("관리자 비밀번호가 지워지고 RCON 이 꺼집니다. 그러면 안전 종료가 시그널 방식으로 바뀌어 세이브가 유실될 위험이 생기고, 서버 이름과 포트 설정도 초기화됩니다.\n\n변경분은 [적용] 을 누르기 전까지 파일에 쓰이지 않으므로 [되돌리기] 로 취소할 수 있습니다."))
        }
    }

    // MARK: - Category sidebar

    private var sidebar: some View {
        List(selection: $category) {
            ForEach(SettingMeta.Category.allCases, id: \.self) { c in
                let n = count(in: c)
                Label {
                    HStack {
                        Text(t(c.rawValue))
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

    // MARK: - Editor pane

    private var detail: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if controller.settings.isEmpty {
                ContentUnavailableView(
                    t("설정을 불러올 수 없습니다"),
                    systemImage: "doc.questionmark",
                    description: Text(t("서버를 한 번 설치·기동해야 PalWorldSettings.ini 가 생성됩니다."))
                )
            } else {
                ScrollView {
                    // VStack, not LazyVStack. Lazy containers grow and shrink their
                    // children as you scroll and re-measure as they go, which tangles
                    // with the width proposals above and retriggers layout. A category
                    // holds at most 26 rows (119 when searching), so rendering them all
                    // is cheap — stability beats lazy instantiation here.
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
            TextField(t("설정 검색 (한글 이름 또는 키)"), text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)

            Menu {
                Button(t("게임플레이 값만 기본값으로 (%@개)", "\(controller.modifiedGameplayCount)")) {
                    controller.resetAllToDefaults()
                }
                .disabled(controller.modifiedGameplayCount == 0)

                Divider()

                Button(t("운영 항목까지 전부 기본값으로…"), role: .destructive) {
                    showResetAllConfirm = true
                }
            } label: {
                Label(t("기본값 복구"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t("기본값과 다른 항목을 되돌립니다 (적용 전까지 취소 가능)"))

            Button {
                Task { await controller.loadSettings() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(t("파일에서 다시 읽기 (변경분 버림)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// With a search term, ignore the category and search everything.
    private var visible: [GameSetting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.isEmpty else {
            return controller.settings.filter {
                $0.key.lowercased().contains(q)
                || SettingsCatalog.meta(for: $0.key).label.lowercased().contains(q)
                || t(SettingsCatalog.meta(for: $0.key).label).lowercased().contains(q)
            }
        }
        return controller.settings.filter {
            SettingsCatalog.meta(for: $0.key).category == category
        }
    }

    private var applySummary: String {
        controller.pendingSettings
            .sorted { $0.key < $1.key }
            .map { "\(t(SettingsCatalog.meta(for: $0.key).label)): \($0.value)" }
            .joined(separator: "\n")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(t("%@개 변경됨", "\(controller.pendingSettings.count)"))
                    .font(.callout.weight(.medium))

                if controller.status.running {
                    Label(t("적용하려면 서버 재시작이 필요합니다"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                Spacer()

                Button(t("되돌리기")) { controller.discardPendingSettings() }
                Button(t("적용")) { showApplyConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
    }
}

// MARK: - One setting row

private struct SettingRow: View {
    let item: GameSetting
    let pending: String?
    let onChange: (String) -> Void
    let onReset: () -> Void

    private var meta: SettingMeta { SettingsCatalog.meta(for: item.key) }
    private var current: String { pending ?? item.value }
    private var isDirty: Bool { pending != nil }

    /// Whether the current (possibly staged) value differs from the default.
    private var differsFromDefault: Bool {
        guard let def = item.defaultValue else { return false }
        return def != current
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t(meta.label)).font(.callout)
                    if isDirty {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                if t(meta.label) != item.key {
                    Text(item.key)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let help = meta.help {
                    Text(t(help)).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only offer the revert link when the value differs from default.
                if differsFromDefault, let def = item.defaultValue {
                    Button {
                        onReset()
                    } label: {
                        Label(t("기본값 %@ 으로", def.isEmpty ? t("(빈값)") : def),
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

    /// Trims trailing noise, showing 1.000000 as 1.
    private func trimFloat(_ s: String) -> String {
        guard let d = Double(s) else { return s }
        return d == d.rounded() && abs(d) < 1e9
            ? String(Int(d))
            : String(format: "%g", d)
    }
}
