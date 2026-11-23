import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 242)
            VStack(spacing: 0) {
                DetailSearchBar(prompt: searchPrompt)
                ModuleDetailView()
                    .background(Palette.background(scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Palette.background(scheme))
        }
        .preferredColorScheme(app.settings.appearance.colorScheme)
        .sheet(isPresented: $app.showAbout) { AboutView() }
        .sheet(isPresented: $app.showHelp) { HelpView() }
        .sheet(item: $app.drivePrompt) { volume in
            DrivePromptView(volume: volume)
                .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(text: toast.text)
                    .id(toast.id)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: app.toast)
            }
        }
        .onExitCommand {
            app.cancelCurrentScan()
        }
        .onAppear {
            applyAppearance(app.settings.appearance)
            app.openMainWindowHandler = { openWindow(id: "main") }
        }
        .onChange(of: app.settings.appearance) { _, mode in applyAppearance(mode) }
        .frame(minWidth: 1_020, minHeight: 680)
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private var searchPrompt: String {
        if app.selectedModule == .overview { return L("Search all results") }
        return L("Search results, paths and categories")
    }

    private var isCurrentScanning: Bool {
        switch app.selectedModule {
        case .disk: return app.disk.isScanning
        case .maintenance: return app.maintenance.isScanning
        case .uninstaller: return app.uninstaller.isScanning
        case .updater: return app.updater.isScanning
        case .privacy: return app.privacy.isScanning
        case .extensions: return app.extensions.isScanning
        case .loginItems: return app.loginItems.isScanning
        default: return false
        }
    }
}

struct DetailSearchBar: View {
    var prompt: String
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $app.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
            if !app.searchText.isEmpty {
                Button {
                    app.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear"))
            }
            Text(L("⌘F"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.cardStrong(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .onChange(of: app.searchFocusRequest) { _, _ in focused = true }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(SidebarSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(1.1)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.white.opacity(0.38))
                                .padding(.horizontal, 14)
                            ForEach(ModuleID.allCases.filter { $0.section == section }) { module in
                                SidebarRow(module: module, badge: badge(for: module), isSelected: app.selectedModule == module) {
                                    withAnimation(.easeOut(duration: 0.16)) { app.select(module) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            footer
        }
        .background(
            ZStack {
                Palette.sidebarGradient
                LinearGradient(colors: [Palette.accent.opacity(0.18), .clear], startPoint: .topTrailing, endPoint: .center)
            }
            .ignoresSafeArea()
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Fettle")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(L("Local Mac care"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().overlay(Color.white.opacity(0.10))
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accentBright)
                Text(L("Local only"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .padding(.horizontal, 18)
            HStack(spacing: 4) {
                Button {
                    app.showHelp = true
                } label: {
                    Label(L("Help"), systemImage: "questionmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.62))
                Spacer()
                SettingsLink {
                    Label(L("Settings"), systemImage: "gearshape")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.62))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
    }

    private func badge(for module: ModuleID) -> String? {
        switch module {
        case .overview: return nil
        case .disk:
            let count = app.disk.items.filter { $0.category != .trash && !$0.isInformational && !$0.isProtected }.count
            return count > 0 ? "\(count)" : nil
        case .maintenance:
            let count = app.maintenance.findingCount
            return count > 0 ? "\(count)" : nil
        case .uninstaller:
            return app.uninstaller.apps.isEmpty ? nil : "\(app.uninstaller.apps.count)"
        case .updater:
            let count = app.updater.availableRecords.count
            return count > 0 ? "\(count)" : nil
        case .privacy:
            let count = app.privacy.items.filter { $0.category != .recentItems && !$0.isInformational }.count
            return count > 0 ? "\(count)" : nil
        case .extensions:
            return app.extensions.records.isEmpty ? nil : "\(app.extensions.records.count)"
        case .loginItems:
            return app.loginItems.records.isEmpty ? nil : "\(app.loginItems.records.count)"
        case .health:
            return app.health.activeAlerts.isEmpty ? nil : "\(app.health.activeAlerts.count)"
        case .security:
            let count = app.security.snapshot?.attentionCount ?? 0
            return count > 0 ? "\(count)" : nil
        case .power, .permanentDelete:
            return nil
        }
    }
}

struct SidebarRow: View {
    var module: ModuleID
    var badge: String?
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.58))
                Text(module.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.14) : (hovering ? Color.white.opacity(0.06) : Color.clear))
                    .overlay(alignment: .leading) {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Palette.accentBright)
                                .frame(width: 2.5, height: 16)
                                .padding(.leading, 1)
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ModuleDetailView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch app.selectedModule {
            case .overview:
                OverviewView(health: app.health)
            case .health:
                HealthView(model: app.health)
            case .disk:
                DiskCleanupView(model: app.disk)
            case .maintenance:
                MaintenanceView(model: app.maintenance)
            case .uninstaller:
                UninstallerView(model: app.uninstaller)
            case .updater:
                UpdaterView(model: app.updater)
            case .power:
                PowerView(model: app.power)
            case .security:
                SecurityView(model: app.security)
            case .extensions:
                ExtensionsView(model: app.extensions)
            case .loginItems:
                LoginItemsView(model: app.loginItems)
            case .privacy:
                PrivacyView(model: app.privacy)
            case .permanentDelete:
                PermanentDeleteView(model: app.permanentDelete)
            }
        }
        .environmentObject(app)
    }
}

// MARK: - About, Help, Drive prompt

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(size: 74)
                .padding(.top, 6)
            VStack(spacing: 4) {
                Text("Fettle").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("A calm, local Mac care utility.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                Text(L("Version %@ (%@)", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 8) {
                bullet("lock.shield.fill", L("Fettle keeps scans on your Mac, starts with nothing selected, and asks before every change."))
                bullet("waveform.path.ecg", L("Mac Health shows live CPU, memory, disk, battery and network readings, with a menu bar popover for quick actions."))
                bullet("arrow.triangle.2.circlepath", L("App Updater reads each app's own update feed and opens the vendor's page; Fettle never installs an update itself."))
                bullet("internaldrive.fill", L("Scans only read file names, sizes and dates. No file contents are uploaded."))
                bullet("applelogo", L("Made for Apple silicon."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            Text(L("Fettle is an original, independent utility for keeping your Mac in good shape."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Close")) { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Palette.accent).frame(width: 16)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Notification.Name {
    static let fettleShowHelp = Notification.Name("fettle.showHelp")
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Help & Safety")).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(L("How Fettle works")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    helpSection(icon: "shield.lefthalf.filled", title: L("Every destructive action shows what will change, asks for confirmation, and rechecks each path right before acting. Items that changed are skipped."))
                    helpSection(icon: "trash", title: L("Routine cleanup and app removal use the Trash. Emptying the Trash and Permanent Delete are separate, explicit actions."))
                    helpSection(icon: "lock", title: L("Fettle never asks for an administrator password and never bypasses macOS privacy protections."))
                    helpSection(icon: "waveform.path.ecg", title: L("Mac Health reads live values from Apple-supported interfaces. Quit Selected Apps asks apps to quit; it never forces a system-wide purge. The Accessibility check is opt-in and used only for the responsiveness check."))
                    helpSection(icon: "menubar.rectangle", title: L("The menu bar popover offers Scan, Quit Selected Apps, Eject All and live readings. Background mode keeps Fettle available after the window closes; Open at Login uses the supported macOS login-item API."))
                    helpSection(icon: "gearshape.2", title: L("System settings that macOS does not let apps change are opened in System Settings or in the browser. Fettle explains the limitation instead of pretending to change them."))
                    helpSection(icon: "arrow.triangle.2.circlepath", title: L("App Updater only reads the update feed each app publishes. It never downloads or runs an installer; App Store and Apple apps open their supported update pages."))
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: "keyboard", tint: Palette.violet, size: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("Keyboard")).font(.system(size: 12.5, weight: .semibold))
                            Text(L("⌘1–⌘9 switch modules, and ⌘0 opens Mac Health.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(L("⌘⇧U opens App Updater.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(L("⌘F searches the visible results.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(L("↑ and ↓ move through results. ⌘A selects all visible items.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(L("⌘R scans again. Escape cancels a scan or closes a sheet.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.violet.opacity(0.06)))
                    helpSection(icon: "exclamationmark.triangle", title: L("Some macOS data needs Full Disk Access, which Fettle never requests automatically. Browser passwords and protected site data are managed by the browser."))
                    helpSection(icon: "externaldrive.badge.xmark", title: L("Permanent deletion cannot defeat SSD wear levelling, APFS snapshots, backups or cloud copies."))
                    helpSection(icon: "signature", title: L("The app is signed to run locally, not notarised for distribution."))
                }
                .padding(22)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Got it")) { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 680)
    }

    private func helpSection(icon: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: icon, tint: Palette.accent, size: 30)
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DrivePromptView: View {
    var volume: VolumeInfo
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var askAlways = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "externaldrive.fill", tint: Palette.blue, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Would you like to scan %@?", volume.name)).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(L("Review external drive results")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Text(L("Items on an external drive are never selected automatically. Review the volume, Trash and temporary files before cleaning."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Label(Fmt.bytes(volume.available) + " " + L("free"), systemImage: "internaldrive")
                Label(Fmt.bytes(volume.total), systemImage: "externaldrive")
            }
            .font(.system(size: 11, weight: .medium))
            Toggle(L("Always ask for connected drives"), isOn: $askAlways)
                .onChange(of: askAlways) { _, value in app.settings.externalDrivePrompt = value }
                .font(.system(size: 11.5))
            Divider()
            HStack {
                Button(L("Not Now")) { dismiss() }
                Spacer()
                Button(L("Scan Drive")) {
                    app.select(.disk)
                    app.disk.startExternalScan(volume)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
