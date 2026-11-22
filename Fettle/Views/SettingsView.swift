import SwiftUI
import AppKit
import UserNotifications

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @State private var tab: SettingsTab = .general
    @State private var notificationDenied = false
    @State private var showReset = false
    @State private var showHelpSheet = false
    @State private var showAboutSheet = false
    @State private var showClearActivity = false

    init(app: AppModel, initialTab: SettingsTab = .general) {
        self._app = ObservedObject(wrappedValue: app)
        self._settings = ObservedObject(wrappedValue: app.settings)
        self._tab = State(initialValue: initialTab)
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, menuBar, ignore, notifications, updates, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("General")
            case .menuBar: return L("Menu Bar")
            case .ignore: return L("Ignore list")
            case .notifications: return L("Notifications")
            case .updates: return L("Updates")
            case .about: return L("About")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .menuBar: return "menubar.rectangle"
            case .ignore: return "eye.slash"
            case .notifications: return "bell"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationDenied = status == .denied
        settings.notificationsEnabled = status == .authorized || status == .provisional
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    BrandMark(size: 26)
                    Text("Fettle").font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)
                ForEach(SettingsTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol).font(.system(size: 11.5, weight: .medium)).frame(width: 16)
                            Text(item.title).font(.system(size: 11.5, weight: tab == item ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(tab == item ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tab == item ? Color.primary.opacity(0.07) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 9)).foregroundStyle(Palette.accent)
                        Text(L("Scan data stays on this Mac")).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Button(L("Reset") + "…") { showReset = true }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .frame(width: 180)
            .background(Color.primary.opacity(0.025))
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .menuBar: menuBar
                    case .ignore: ignoreList
                    case .notifications: notifications
                    case .updates: updates
                    case .about: about
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.background(scheme))
        .task(id: tab) { if tab == .notifications { await refreshNotificationPermission() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshLoginItemStatus()
            if tab == .notifications { Task { await refreshNotificationPermission() } }
        }
        .sheet(isPresented: $showHelpSheet) {
            HelpView().environmentObject(app)
        }
        .sheet(isPresented: $showAboutSheet) {
            AboutView().environmentObject(app)
        }
        .alert(L("Reset all settings?"), isPresented: $showReset) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Reset"), role: .destructive) {
                if settings.openAtLogin || LoginItemManager.isEnabled {
                    app.setOpenAtLogin(false)
                }
                settings.reset()
                app.ignoreList.clear()
                app.history.clear()
                app.health.clearActivity()
            }
        } message: {
            Text(L("This clears preferences, the ignore list, cleanup history and activity history."))
        }
        .confirmationDialog(L("Clear activity history?"), isPresented: $showClearActivity, titleVisibility: .visible) {
            Button(L("Clear"), role: .destructive) { app.health.clearActivity() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Only the numeric readings kept by Mac Health are removed. Cleanup history is separate."))
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsTitle(L("General"), L("Appearance, language and scan limits."))
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Appearance")).font(.system(size: 12, weight: .semibold))
                            Text(L("Light and dark appearance, or follow macOS.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 190, alignment: .trailing)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Language")).font(.system(size: 12, weight: .semibold))
                            Text(L("English and Dutch interface strings.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.language) {
                            ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 190, alignment: .trailing)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Large files")).font(.system(size: 12, weight: .semibold))
                            Text(L("Minimum size")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.largeFileThresholdMB) {
                            ForEach([10, 50, 100, 500, 1_000], id: \.self) { value in Text("\(value) MB").tag(value) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 190, alignment: .trailing)
                    }
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $settings.healthMonitoring) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Live Mac Health readings")).font(.system(size: 12, weight: .semibold))
                            Text(L("Read CPU, memory, disk, battery and network activity in the background.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Reading interval")).font(.system(size: 11))
                            Text(L("Shorter intervals are more detailed but use a little more energy.")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.sampleIntervalSeconds) {
                            ForEach([2, 3, 5, 10], id: \.self) { value in Text(L("%d seconds", value)).tag(value) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 190, alignment: .trailing)
                    }
                    Divider()
                    Toggle(isOn: $settings.activityHistoryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Keep activity history")).font(.system(size: 11.5))
                            Text(L("One numeric reading per minute, kept for seven days on this Mac.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(L("Activity history is separate from cleanup history.")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Spacer()
                        Button(L("Clear Activity History…")) { showClearActivity = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9.5))
                            .disabled(app.health.activity.samples.isEmpty)
                    }
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Local only")).font(.system(size: 12, weight: .semibold))
                    Text(L("Fettle has no account and sends no scan data anywhere. Update checks contact only Fettle's own release feed and, when you run App Updater, each app's own update feed."))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Label(L("Read-only scans"), systemImage: "eye")
                        Label(L("No admin password"), systemImage: "lock")
                        Label(L("Trash first"), systemImage: "trash")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsTitle(L("Menu Bar"), L("Live readings and quick actions without opening the window."))
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $settings.menuBarEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Show Fettle in the menu bar")).font(.system(size: 12, weight: .semibold))
                            Text(L("Click the icon for live readings, Scan, Quit Selected Apps and Eject All.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Show CPU percentage")).font(.system(size: 11))
                            Text(L("Adds the current CPU reading next to the menu bar icon.")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.menuBarShowsCPU).labelsHidden()
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { settings.backgroundMode }, set: { app.setBackgroundMode($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Keep running when the window closes")).font(.system(size: 11.5))
                            Text(L("Fettle stays in the menu bar instead of quitting. The Dock icon remains available.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity)
                    Toggle(isOn: Binding(get: { settings.openAtLogin }, set: { app.setOpenAtLogin($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Open at login")).font(.system(size: 11.5))
                            Text(app.loginItemStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity)
                    if let error = app.loginItemError {
                        Text(error).font(.system(size: 9.5)).foregroundStyle(Palette.coral).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button(L("Open Login Items Settings")) { app.openLoginItemsSettings() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text(L("Login items are managed by macOS. Fettle uses the supported login-item API."))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Menu bar privacy")).font(.system(size: 11, weight: .semibold))
                    Text(L("The menu bar shows the same local readings as Mac Health. Nothing is sent anywhere, and no process names are shown there."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var ignoreList: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsTitle(L("Ignore list"), L("Paths and folders on this list are skipped by scans and cannot be cleaned."))
            HStack(spacing: 8) {
                Button(L("Add Folder…")) { addIgnoreFolder() }
                    .buttonStyle(.bordered)
                Button(L("Add File…")) { addIgnoreFile() }
                    .buttonStyle(.bordered)
                Spacer()
                if !app.ignoreList.paths.isEmpty {
                    Button(L("Clear")) { app.ignoreList.clear() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            if app.ignoreList.paths.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "eye.slash").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("Ignore list is empty.")).font(.system(size: 12, weight: .medium))
                    Text(L("Ignore lists are stored only on this Mac.")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            } else {
                VStack(spacing: 0) {
                    ForEach(app.ignoreList.paths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Palette.accent)
                            Text(PathDisplay.short(path)).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                app.ignoreList.remove(path)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 7)
                        Divider().opacity(0.35)
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
            }
        }
    }

    private func reminderLabel(_ days: Int) -> String {
        switch days {
        case 3: return L("Every 3 days")
        case 7: return L("Every 7 days")
        case 14: return L("Every 14 days")
        case 30: return L("Every 30 days")
        default: return L("Every %d days", days)
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsTitle(L("Notifications"), L("Reminders, health alerts and sound."))
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $settings.cleanupReminders) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Cleanup reminders")).font(.system(size: 12, weight: .semibold))
                            Text(L("Remind me when it has been a while since the last scan.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.cleanupReminders) { _, _ in reschedule() }
                    HStack {
                        Text(L("Reminder interval")).font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $settings.reminderIntervalDays) {
                            ForEach(Rules.Reminder.optionDays, id: \.self) { days in
                                Text(reminderLabel(days)).tag(days)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 150, alignment: .trailing)
                        .onChange(of: settings.reminderIntervalDays) { _, _ in reschedule() }
                    }
                    Divider()
                    Toggle(isOn: $settings.trashReminder) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Trash reminder")).font(.system(size: 12, weight: .semibold))
                            Text(L("Tell me when the Trash is getting large.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.trashReminder) { _, _ in reschedule() }
                    HStack {
                        Text(L("Trash size threshold")).font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $settings.trashThresholdMB) {
                            ForEach(Rules.trashAlertThresholdBytes, id: \.self) { bytes in
                                Text(Fmt.bytes(bytes)).tag(Int(bytes / 1_000_000))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 130, alignment: .trailing)
                    }
                    Divider()
                    Toggle(isOn: $settings.diskSpaceAlert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Low disk space alert")).font(.system(size: 12, weight: .semibold))
                            Text(L("Tell me when free space is running low.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    if settings.diskSpaceAlert {
                        HStack {
                            Text(L("Alert when free space is below")).font(.system(size: 11))
                            Spacer()
                            Picker("", selection: $settings.diskSpaceThresholdGB) {
                                Text(L("Automatic (10% of free space)")).tag(0)
                                ForEach(Rules.diskSpaceAlertThresholdBytes, id: \.self) { bytes in
                                    Text(Fmt.bytes(bytes)).tag(Rules.diskSpaceThresholdGB(forOption: bytes))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(width: 190, alignment: .trailing)
                        }
                    }
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Mac health alerts")).font(.system(size: 12, weight: .semibold))
                    Text(L("In-app alerts are always visible in Mac Health. Notifications are only delivered after you allow them below."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $settings.memoryPressureAlert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Memory pressure")).font(.system(size: 11.5))
                            Text(L("Warn when macOS reports elevated or critical memory pressure.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Toggle(isOn: $settings.highCPUAlert) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("High CPU use")).font(.system(size: 11.5))
                                Text(L("Warn after the processor stays busy for several readings.")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("", selection: $settings.highCPUThreshold) {
                            ForEach([70, 80, 85, 90, 95], id: \.self) { value in Text("\(value)%").tag(value) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 82, alignment: .trailing)
                        .disabled(!settings.highCPUAlert)
                    }
                    Toggle(isOn: $settings.driveHealthAlert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Drive health")).font(.system(size: 11.5))
                            Text(L("Warn when a drive reports a failing or unverified SMART status.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.externalDriveAlert) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("External drive connected")).font(.system(size: 11.5))
                            Text(L("Show a reminder to review a newly connected removable drive.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Allow Notifications…")).font(.system(size: 12, weight: .semibold))
                            Text(settings.notificationsEnabled ? L("Notifications are on.") : L("Notifications are off until you allow them."))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(notificationDenied ? L("Open Notification Settings") : L("Allow Notifications…")) {
                            if notificationDenied {
                                SystemActions.openSettings(.notifications)
                            } else {
                                Task {
                                    await app.updateNotificationSchedule(requestAuthorization: true)
                                    await refreshNotificationPermission()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider()
                    Toggle(isOn: $settings.soundEnabled) {
                        Text(L("Play a sound when an action finishes")).font(.system(size: 11.5))
                    }
                    HStack {
                        Text(L("Sound")).font(.system(size: 11))
                        Spacer()
                        Picker("", selection: $settings.soundName) {
                            ForEach(["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Tink"], id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 140, alignment: .trailing)
                        Button {
                            SoundPlayer.playSuccess(enabled: true, name: settings.soundName)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                    Toggle(isOn: $settings.externalDrivePrompt) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Prompt to scan a connected drive")).font(.system(size: 11.5))
                            Text(L("Show a prompt when a removable drive is connected.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsTitle(L("Updates"), L("Manual and opt-in automatic update checks when a signed release feed is configured."))
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("App update checks")).font(.system(size: 12, weight: .semibold))
                            Text(L("Check the update feed each installed app publishes. Fettle never installs an update."))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            app.select(.updater)
                            app.updater.startScan()
                        } label: {
                            Label(L("Open App Updater"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                    }
                    Toggle(isOn: $settings.autoCheckAppUpdates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Check app updates automatically")).font(.system(size: 11.5))
                            Text(L("Once a day at launch. Only the app’s own update feed is contacted.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.appUpdatesInGlobalScan) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Include app updates in Scan")).font(.system(size: 11.5))
                            Text(L("Add the read-only app update check to the Overview Scan button. This contacts each app's own feed.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(L("Last app update check")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.lastAppUpdateCheck.map { Fmt.dateTime($0) } ?? L("Never checked"))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    Text(L("Only app names, versions and the feed addresses those apps publish are used. Your documents, passwords and browsing data are never read."))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $settings.autoCheckUpdates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Automatic update checks")).font(.system(size: 11.5))
                            Text(L("Check for a newer release once a day when a signed feed is configured.")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    TextField(L("Release feed URL"), text: $settings.feedURL)
                        .textFieldStyle(.roundedBorder)
                    TextField(L("Public signing key"), text: $settings.publicKey)
                        .textFieldStyle(.roundedBorder)
                    Text(L("Updates are verified with an Ed25519 signature before a version is offered."))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            Task { await app.checkForUpdates(manual: true) }
                        } label: {
                            Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.updateState == .checking)
                        if case .available(let feed) = app.updateState, let url = URL(string: feed.url) {
                            Button(L("Open Download Page")) { SystemActions.open(url) }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accent)
                        }
                        Spacer()
                        Text(app.updateState.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if case .available(let feed) = app.updateState {
                settingsCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(L("Version")) \(feed.version)").font(.system(size: 12, weight: .semibold))
                        if let notes = feed.notes {
                            Text(notes).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(L("No signed release feed is configured. Add a feed URL and its Ed25519 public key to enable update checks."))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BrandMark(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fettle").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(L("A calm, local Mac care utility.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(L("Version %@ (%@)", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("How Fettle works")).font(.system(size: 12, weight: .semibold))
                    Text(L("Fettle keeps scans on your Mac, starts with nothing selected, and asks before every change. Mac Health adds live readings and a menu bar popover; Quit Selected Apps only asks apps to quit."))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("Fettle is an original, independent utility for keeping your Mac in good shape."))
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(L("Open Help")) { showHelpSheet = true }
                    .buttonStyle(.bordered)
                Button(L("About Fettle")) { showAboutSheet = true }
                    .buttonStyle(.bordered)
                Spacer()
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Acknowledgements")).font(.system(size: 11, weight: .semibold))
                    Text(L("Built with SwiftUI and AppKit. No third-party runtime dependencies.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(L("The app is signed to run locally, not notarised for distribution.")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func settingsTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
    }

    private func reschedule() {
        Task { await app.updateNotificationSchedule(requestAuthorization: false) }
    }

    private func addIgnoreFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach { app.ignoreList.add($0) }
        }
    }

    private func addIgnoreFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach { app.ignoreList.add($0) }
        }
    }
}
