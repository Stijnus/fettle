import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About Fettle")) { app.showAbout = true }
            Divider()
            Button(L("Check for Updates…")) {
                Task { await app.checkForUpdates(manual: true) }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L("Scan Again")) { app.scanCurrentOrAll() }
                .keyboardShortcut("r", modifiers: .command)
            Button(L("Stop Scan")) { app.cancelCurrentScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isGlobalScanning && !app.isAnyModuleScanning)
        }
        CommandMenu(L("Select")) {
            Button(L("Select All")) { app.selectAllCurrent() }
                .keyboardShortcut("a", modifiers: .command)
            Button(L("Deselect All")) { app.deselectAllCurrent() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button(L("Search Results")) { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu(L("Go")) {
            ForEach(ModuleID.allCases.filter { $0.shortcutNumber != nil }) { module in
                Button(module.title) { app.select(module) }
                    .keyboardShortcut(KeyEquivalent(Character("\(module.shortcutNumber ?? 1)")), modifiers: .command)
            }
            Divider()
            Button(L("App Updater")) { app.select(.updater) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button(L("Help & Safety")) { app.showHelp = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

extension AppModel {
    func selectAllCurrent() {
        switch selectedModule {
        case .disk: disk.selectAll(query: searchText)
        case .maintenance: maintenance.selectAll(query: searchText)
        case .privacy: privacy.selectAll(query: searchText)
        case .uninstaller: uninstaller.selectAllApps()
        case .updater: updater.selectAll()
        default: break
        }
    }

    func deselectAllCurrent() {
        switch selectedModule {
        case .disk: disk.deselectAll()
        case .maintenance: maintenance.deselectAll()
        case .privacy: privacy.selectedIDs.removeAll()
        case .uninstaller: uninstaller.selectedAppIDs.removeAll()
        case .updater: updater.deselectAll()
        default: break
        }
    }
}
