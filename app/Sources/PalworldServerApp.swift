import SwiftUI

@main
struct PalworldServerApp: App {
    @StateObject private var controller = ServerController()

    // 폴링 시작 위치에 대한 주의사항 두 가지:
    //
    //  1. onAppear 에 걸면 안 됩니다. 창이 닫힌 채(메뉴 막대만) 실행되면
    //     호출되지 않아 메뉴 막대가 빈 값을 계속 보여줍니다.
    //  2. App 의 init() 에서 컨트롤러를 직접 만들어도 안 됩니다.
    //     SwiftUI 는 App 구조체를 여러 번 초기화할 수 있는데, @StateObject 는
    //     첫 인스턴스만 보관하므로 나머지는 버려집니다. 그런데 그 버려진
    //     인스턴스들의 폴링 Task 는 계속 돌아 RCON 호출이 배로 늘어납니다.
    //     (실측: 3초 주기여야 할 ShowPlayers 가 15초에 30회)
    //
    // 그래서 폴링은 ServerController.init() 안에서 시작하고, 여기서는
    // @StateObject 의 autoclosure 에 생성을 맡깁니다. autoclosure 는 SwiftUI 가
    // 실제로 필요할 때 단 한 번만 평가하므로 인스턴스가 하나로 보장됩니다.
    var body: some Scene {
        Window(t("Palworld 서버"), id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .windowResizability(.contentMinSize)

        // 메뉴 막대 상주 항목 — 창을 닫아도 상태를 계속 볼 수 있고
        // 시작/종료/백업을 즉시 실행할 수 있습니다.
        MenuBarExtra {
            MenuBarContent().environmentObject(controller)
        } label: {
            Image(systemName: menuBarIcon)
        }
    }

    private var menuBarIcon: String {
        guard controller.status.running else { return "gamecontroller" }
        return controller.status.portBound ? "gamecontroller.fill" : "gamecontroller"
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var controller: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)
        if controller.status.running {
            Text(t("CPU %@%% · RAM %@ · 접속자 %@명",
                   String(format: "%.1f", controller.status.cpuPercent),
                   memoryText, "\(controller.players.count)"))
        }

        Divider()

        if controller.status.running {
            Button(t("안전 종료")) { controller.stop() }
            Button(t("재시작")) { controller.restart() }
        } else {
            Button(t("서버 시작")) { controller.start() }
        }
        Button(t("지금 백업")) { controller.backup() }

        Divider()

        Button(t("창 열기")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(t("종료")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        guard controller.status.running else { return t("● 정지됨") }
        return controller.status.portBound
            ? t("● 실행 중 (가동 %@)", controller.status.uptime)
            : t("● 기동 중…")
    }

    private var memoryText: String {
        let mb = controller.status.memoryMB
        return mb >= 1024 ? String(format: "%.1fGB", Double(mb) / 1024) : "\(mb)MB"
    }
}
