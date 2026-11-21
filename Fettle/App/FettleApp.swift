import SwiftUI
import AppKit

@main
enum FettleMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.runAndExit()
        }
        if CommandLine.arguments.contains("--integration-test") {
            IntegrationTest.runAndExit()
        }
        if CommandLine.arguments.contains("--health-probe") {
            HealthProbe.runAndExit()
        }
        if CommandLine.arguments.contains("--login-item-probe") {
            LoginItemProbe.runAndExit()
        }
        FettleApp.main()
    }
}

struct FettleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Fettle", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1_020, minHeight: 680)
        }
        .defaultSize(width: 1_180, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView(app: app)
                .environmentObject(app)
                .frame(width: 780, height: 600)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = nil
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.current?.menuBar.sync()
        AppPreview.installIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(AppModel.current?.settings.backgroundMode ?? false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.current?.showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.current?.health.stopMonitoring()
    }
}
