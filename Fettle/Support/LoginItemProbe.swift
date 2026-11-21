import Foundation
import ServiceManagement

enum LoginItemProbe {
    static func runAndExit() {
        let before = LoginItemManager.statusText
        var actions: [String] = []
        if ProcessInfo.processInfo.environment["FETTLE_LOGIN_TEST"] == "1" {
            do {
                try SMAppService.mainApp.register()
                actions.append("registered")
            } catch {
                actions.append("register failed: \(error.localizedDescription)")
            }
            sleep(1)
            actions.append("status after register: \(LoginItemManager.statusText)")
            do {
                try SMAppService.mainApp.unregister()
                actions.append("unregistered")
            } catch {
                actions.append("unregister failed: \(error.localizedDescription)")
            }
            actions.append("status after unregister: \(LoginItemManager.statusText)")
        }
        let report: [String: Any] = [
            "bundle": Bundle.main.bundlePath,
            "before": before,
            "actions": actions,
            "after": LoginItemManager.statusText
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
        exit(0)
    }
}
