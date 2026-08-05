import SwiftUI

@main
struct PalworldServerApp: App {
    @StateObject private var controller = ServerController()

    // Two notes on where polling is started:
    //
    //  1. Not in onAppear. When the app launches with the window closed (menu bar
    //     only) it never fires, leaving the menu bar showing empty values.
    //  2. Not by constructing the controller in App.init() either. SwiftUI may
    //     initialise the App struct more than once; @StateObject keeps only the first
    //     instance and discards the rest — but a discarded instance's poll task would
    //     keep running.
    //
    // So polling starts inside ServerController.init(), and construction is left to
    // @StateObject's autoclosure, which SwiftUI evaluates exactly once.
    var body: some Scene {
        Window(t("Palworld 서버"), id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .windowResizability(.contentMinSize)

        // Menu bar item — status stays visible with the window closed, and
        // start/stop/backup are one click away.
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
