import AppKit
import SwiftUI
import Combine
import ServiceManagement

enum LoginItemManager {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: return L("Fettle opens at login.")
        case .requiresApproval: return L("Waiting for approval in System Settings → General → Login Items & Extensions.")
        case .notRegistered: return L("Fettle does not open at login.")
        case .notFound: return L("Fettle is not registered for login yet. Turn this on to register it with macOS.")
        @unknown default: return L("The login item status is unknown.")
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            if status == .notRegistered { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SystemActions.openSettings(.loginItems)
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private weak var app: AppModel?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func attach(app: AppModel) {
        self.app = app
        app.health.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        app.health.$activeAlerts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        sync()
    }

    var isInstalled: Bool { statusItem != nil }

    func sync() {
        guard let app else { return }
        if app.settings.menuBarEnabled {
            install()
        } else {
            remove()
        }
        updateTitle()
    }

    private func install() {
        guard statusItem == nil, let app else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Fettle")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = L("Fettle Mac health")
            button.setAccessibilityLabel(L("Fettle Mac health"))
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 368, height: 540)
        let actions = MenuBarActions(
            open: { [weak self] in self?.openMainWindow() },
            settings: { [weak self] in self?.openSettings() },
            scan: { [weak self] in self?.scan() },
            freeMemory: { [weak self] in self?.freeMemory() },
            eject: { [weak self] in self?.confirmEjectAll() },
            quit: { NSApp.terminate(nil) }
        )
        let root = MenuBarPopoverView(app: app, health: app.health, actions: actions)
            .environmentObject(app)
        popover.contentViewController = NSHostingController(rootView: root)
        self.popover = popover
    }

    private func remove() {
        popover?.performClose(nil)
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func updateTitle() {
        guard let item = statusItem, let app else { return }
        if app.settings.menuBarShowsCPU, let snapshot = app.health.snapshot, snapshot.cpu.warmedUp {
            item.button?.title = String(format: " %.0f%%", snapshot.cpu.usagePercent)
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else {
            item.button?.title = ""
        }
        let hasAlert = !app.health.activeAlerts.isEmpty
        item.button?.image = NSImage(
            systemSymbolName: hasAlert ? "exclamationmark.triangle.fill" : "waveform.path.ecg",
            accessibilityDescription: hasAlert ? L("Fettle needs attention") : "Fettle"
        )
        item.button?.image?.isTemplate = true
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Keep the status item visible; the popover is recreated on demand.
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func openMainWindow() {
        popover?.performClose(nil)
        app?.showMainWindow()
    }

    func openSettings() {
        popover?.performClose(nil)
        app?.showMainWindow()
        if let item = settingsMenuItem(), let action = item.action {
            if item.target?.perform(action, with: item) != nil { return }
        }
        let modern = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !modern {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func settingsMenuItem() -> NSMenuItem? {
        func search(_ menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if let submenu = item.submenu, let found = search(submenu) { return found }
                if item.title.hasPrefix("Settings") || item.title.hasPrefix("Instellingen") || item.title.hasPrefix("Voorkeuren") { return item }
                if let action = item.action, NSStringFromSelector(action).contains("Settings") || NSStringFromSelector(action).contains("Preferences") { return item }
            }
            return nil
        }
        return search(NSApp.mainMenu)
    }

    private func scan() {
        openMainWindow()
        app?.select(.overview)
        app?.startGlobalScan()
    }

    private func freeMemory() {
        openMainWindow()
        app?.select(.health)
        app?.health.page = .memory
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            app?.health.showFreeMemory = true
        }
    }

    private func confirmEjectAll() {
        popover?.performClose(nil)
        guard let app else { return }
        let targets = app.health.snapshot?.ejectableVolumes ?? []
        guard !targets.isEmpty else {
            app.health.setMessage(L("No ejectable drives are connected."))
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Eject all connected drives?")
        alert.informativeText = "\(targets.map(\.name).joined(separator: ", "))\n\n" + L("Fettle asks macOS to eject these volumes. Unsaved files should be saved first.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Eject All"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            app.health.ejectAll()
        }
    }
}

struct MenuBarActions {
    var open: () -> Void
    var settings: () -> Void
    var scan: () -> Void
    var freeMemory: () -> Void
    var eject: () -> Void
    var quit: () -> Void
}
