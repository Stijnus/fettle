import Foundation
import AppKit
import SwiftUI

enum HealthProbe {
    static func runAndExit() {
        Task {
            let sampler = HealthSampler()
            let first = await sampler.sample()
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            let second = await sampler.sample()
            var report: [String: Any] = [:]
            report["first_read"] = ISO8601DateFormatter().string(from: first.readAt)
            report["cpu_percent"] = second.cpu.usagePercent
            report["cpu_cores"] = second.cpu.coreCount
            report["load1"] = second.cpu.load1
            report["memory_total"] = second.memory.totalBytes
            report["memory_used"] = second.memory.usedBytes
            report["memory_pressure"] = second.memory.pressure.rawValue
            report["swap_used"] = second.memory.swapUsedBytes
            report["process_count"] = second.processCount
            report["top_cpu"] = second.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3).map { ["name": $0.name, "pid": $0.pid, "cpu": $0.cpuPercent, "memory": $0.memoryBytes] as [String: Any] }
            report["volumes"] = second.volumes.map { ["name": $0.name, "mount": $0.mountPath, "total": $0.totalBytes, "free": $0.availableBytes, "smart": $0.smartStatus ?? ""] as [String: Any] }
            report["drives"] = second.drives.map { ["id": $0.id, "model": $0.model, "smart": $0.smartStatus, "used": $0.percentageUsed as Any, "hours": $0.powerOnHours as Any] as [String: Any] }
            report["battery"] = ["present": second.battery.isPresent, "percent": second.battery.percent as Any, "cycles": second.battery.cycleCount as Any, "health": second.battery.healthPercent as Any, "condition": second.battery.condition ?? "", "temperature": second.battery.temperatureCelsius as Any, "charging": second.battery.isCharging, "plugged_in": second.battery.isPluggedIn, "minutes_remaining": second.battery.timeRemainingMinutes as Any, "voltage_mv": second.battery.voltageMillivolts as Any, "adapter_watts": second.battery.adapterWatts as Any]
            report["network"] = ["primary": second.network.primaryInterface ?? "", "total_in": second.network.totalReceived, "total_out": second.network.totalSent, "rate_in": second.network.receiveRate, "rate_out": second.network.sendRate, "interfaces": second.network.interfaces.map { ["name": $0.name, "address": $0.address ?? "", "in": $0.receivedBytes, "out": $0.sentBytes] as [String: Any] }] as [String: Any]
            report["disk_io_read_bps"] = second.diskIO.readBytesPerSecond
            report["disk_io_write_bps"] = second.diskIO.writeBytesPerSecond
            report["notes"] = second.notes
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

/// Hidden preview mode used during development. It renders the real window
/// contents to a PNG so the layout can be inspected without Screen Recording
/// permission. It is not shown anywhere in the interface.
enum AppPreview {
    struct Request: Codable {
        var module: String?
        var page: String?
        var appearance: String?
        var output: String?
        var settings: Bool?
        var menuBar: Bool?
        var width: Double?
        var height: Double?
        var settingsTab: String?
        var freeMemory: Bool?
        var accessibility: Bool?
        var backgroundTest: Bool?
        var settingsFromMenu: Bool?
        /// Runs the selected module's scan right after it is shown.
        var scan: Bool?
        /// Seconds to wait before capturing (default 3.2, or 4.2 for the menu bar).
        var delay: Double?
        /// Captures the sheet attached to the main window, such as the drive prompt.
        var sheet: Bool?
        /// Development only: selects the first updater result and opens Review.
        var review: Bool?
    }

    static func installIfRequested() {
        let requestURL = URL(fileURLWithPath: "/tmp/fettle-preview-request.json")
        let request = (try? Data(contentsOf: requestURL)).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
        let fromArguments = CommandLine.arguments.contains("--ui-preview")
        guard fromArguments || request != nil else { return }
        writeLog("installIfRequested args=\(CommandLine.arguments)")
        if request != nil { try? FileManager.default.removeItem(at: requestURL) }
        let module = request?.module.flatMap(ModuleID.init(rawValue:)) ?? previewModule()
        let page = request?.page.flatMap(HealthPage.init(rawValue:)) ?? previewHealthPage()
        let appearance = request?.appearance ?? CommandLine.arguments.firstIndex(of: "--preview-appearance").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        let output = request?.output ?? CommandLine.arguments.firstIndex(of: "--preview-output").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        } ?? "/tmp/fettle-preview.png"
        let showSettings = request?.settings ?? CommandLine.arguments.contains("--preview-settings")
        let showMenuBar = request?.menuBar ?? CommandLine.arguments.contains("--preview-menu-bar")

        writeLog("scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            writeLog("stage1 windows=\(NSApp.windows.count)")
            if let appearance, let mode = AppearanceMode(rawValue: appearance) {
                AppModel.current?.settings.appearance = mode
            }
            AppModel.current?.select(module)
            if module == .health { AppModel.current?.health.page = page }
            if request?.scan == true { AppModel.current?.scanCurrentOrAll() }
            if request?.review == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                    if let updater = AppModel.current?.updater, let first = updater.availableRecords.first {
                        updater.selectedIDs = [first.id]
                        updater.beginReview()
                    }
                }
            }
            if let height = request?.height,
               let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
                let width = request?.width ?? window.frame.width
                window.setContentSize(NSSize(width: width, height: height))
            }
            if showSettings, let app = AppModel.current {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = L("Settings")
                let tab = request?.settingsTab.flatMap(SettingsView.SettingsTab.init(rawValue:)) ?? .general
                window.contentView = NSHostingView(rootView: SettingsView(app: app, initialTab: tab).environmentObject(app))
                window.center()
                window.makeKeyAndOrderFront(nil)
                previewWindow = window
            }
            if showMenuBar {
                AppModel.current?.menuBar.showPopover()
            }
            if request?.freeMemory == true {
                AppModel.current?.health.showFreeMemory = true
            }
            if request?.accessibility == true {
                AppModel.current?.health.accessibilityPrompt = AccessibilityPrompt()
            }
            if request?.settingsFromMenu == true {
                func dump(_ menu: NSMenu?, depth: Int) {
                    guard let menu else { return }
                    for item in menu.items {
                        writeLog("menu \(String(repeating: " ", count: depth))\(item.title) action=\(item.action.map(NSStringFromSelector) ?? "nil") target=\(String(describing: item.target))")
                        if let submenu = item.submenu { dump(submenu, depth: depth + 1) }
                    }
                }
                dump(NSApp.mainMenu, depth: 0)
                AppModel.current?.menuBar.openSettings()
            }
            if request?.backgroundTest == true, let app = AppModel.current {
                app.setBackgroundMode(true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
                    writeLog("closing main window for background test")
                    window.close()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    writeLog("reopening main window for background test")
                    app.showMainWindow()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (request?.delay ?? (showMenuBar ? 4.2 : 3.2))) {
            writeLog("stage2 windows=\(NSApp.windows.count)")
            for window in NSApp.windows {
                writeLog("window class=\(type(of: window)) title=\(window.title) size=\(window.frame.size) canMain=\(window.canBecomeMain) panel=\(window is NSPanel) visible=\(window.isVisible)")
            }
            let target: NSWindow?
            if request?.sheet == true {
                target = NSApp.windows.first { $0.isSheet && $0.isVisible }
            } else if showMenuBar {
                target = NSApp.windows.first { $0.contentView?.frame.width == 368 }
            } else if showSettings {
                target = previewWindow
            } else if request?.freeMemory == true {
                target = NSApp.windows.first { $0.contentView?.frame.width == 560 }
                    ?? NSApp.windows.first { $0.contentView?.frame.width == 500 }
            } else if request?.accessibility == true {
                target = NSApp.windows.first { $0.contentView?.frame.width == 500 }
            } else if request?.settingsFromMenu == true {
                target = NSApp.windows.first { $0.contentView?.frame.width == 780 }
            } else if request?.backgroundTest == true {
                target = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
            } else {
                target = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
                    ?? NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) && $0.frame.width > 500 }
            }
            if let target, let view = target.contentView {
                writeLog("target size=\(view.bounds)")
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                if let rep {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: output))
                        writeLog("wrote \(output) bytes=\(data.count)")
                    } else { writeLog("no png data") }
                } else { writeLog("no bitmap rep") }
            } else { writeLog("no target") }
            // Preview mode is development-only. Exit directly so a captured
            // sheet cannot keep an app-modal termination request pending.
            exit(0)
        }
    }

    private static var previewWindow: NSWindow?

    static func writeLog(_ text: String) {
        let line = "\(Date()) \(text)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/fettle-preview.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func previewModule() -> ModuleID {
        guard let index = CommandLine.arguments.firstIndex(of: "--preview-module"), index + 1 < CommandLine.arguments.count else { return .health }
        return ModuleID(rawValue: CommandLine.arguments[index + 1]) ?? .health
    }

    private static func previewHealthPage() -> HealthPage {
        guard let index = CommandLine.arguments.firstIndex(of: "--preview-page"), index + 1 < CommandLine.arguments.count else { return .overview }
        return HealthPage(rawValue: CommandLine.arguments[index + 1]) ?? .overview
    }
}
