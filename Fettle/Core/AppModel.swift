import Foundation
import SwiftUI
import AppKit
import Combine

enum UpdateUIState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(UpdateFeed)
    case notConfigured
    case failed(String)

    var message: String {
        switch self {
        case .idle: return ""
        case .checking: return L("Checking…")
        case .upToDate: return L("You are up to date.")
        case .available(let feed): return L("A newer version is available.") + " \(feed.version)"
        case .notConfigured: return L("No signed release feed is configured. Add a feed URL and its Ed25519 public key to enable update checks.")
        case .failed(let reason): return reason
        }
    }

    static func == (lhs: UpdateUIState, rhs: UpdateUIState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.notConfigured, .notConfigured): return true
        case (.upToDate(let a), .upToDate(let b)): return a == b
        case (.available(let a), .available(let b)): return a.version == b.version && a.url == b.url
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let ignoreList: IgnoreListStore
    let history: HistoryStore

    let disk: DiskCleanupModel
    let maintenance: MaintenanceModel
    let uninstaller: UninstallerModel
    let updater: UpdaterModel
    let power: PowerModel
    let extensions: ExtensionsModel
    let loginItems: LoginItemsModel
    let privacy: PrivacyModel
    let permanentDelete: PermanentDeleteModel
    let health: HealthModel
    let menuBar: MenuBarController

    static weak var current: AppModel?
    var openMainWindowHandler: (() -> Void)?

    @Published var selectedModule: ModuleID = .overview
    @Published var searchText = ""
    @Published var searchFocusRequest = UUID()
    @Published var showSettings = false
    @Published var showAbout = false
    @Published var showHelp = false
    @Published var isGlobalScanning = false
    @Published var globalProgress: Double = 0
    @Published var globalPhase = ""
    @Published var lastGlobalScan: Date?
    @Published var drivePrompt: VolumeInfo?
    @Published var toast: ToastMessage?
    @Published var updateState: UpdateUIState = .idle
    @Published var diskUsage: VolumeInfo?
    @Published var trashBytesLive: Int64 = 0
    @Published var hasScannedThisSession = false
    @Published var loginItemStatus: String = ""
    @Published var loginItemError: String?

    private var globalTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var trashTask: Task<Void, Never>?
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = AppSettings()
        let ignore = IgnoreListStore()
        let history = HistoryStore()
        self.settings = settings
        self.ignoreList = ignore
        self.history = history
        self.disk = DiskCleanupModel(settings: settings, ignoreList: ignore, history: history)
        self.maintenance = MaintenanceModel(settings: settings, ignoreList: ignore, history: history)
        self.uninstaller = UninstallerModel(settings: settings, ignoreList: ignore, history: history)
        self.updater = UpdaterModel(settings: settings, ignoreList: ignore, history: history)
        self.power = PowerModel()
        self.extensions = ExtensionsModel(settings: settings, ignoreList: ignore)
        self.loginItems = LoginItemsModel(settings: settings, history: history)
        self.privacy = PrivacyModel(settings: settings, ignoreList: ignore, history: history)
        self.permanentDelete = PermanentDeleteModel(settings: settings, history: history)
        self.health = HealthModel(settings: settings, cleanupHistory: history, activity: HealthHistoryStore())
        self.menuBar = MenuBarController()
        self.diskUsage = FileSafety.rootVolume()
        AppModel.current = self
        self.loginItemStatus = LoginItemManager.statusText
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async {
                    self?.menuBar.sync()
                    self?.health.applySettings()
                }
            }
            .store(in: &cancellables)

        history.objectWillChange
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshDiskUsage()
                Task { await self.refreshLiveTrashSize() }
            }
            .store(in: &cancellables)

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in
                await self.health.refreshNow(rescanDisks: true)
                guard self.settings.externalDrivePrompt else { return }
                if let info = FileSafety.volumeInfo(for: url), info.isExternal || info.isRemovable {
                    self.drivePrompt = info
                }
            }
        }

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.health.refreshNow(rescanDisks: true)
            }
        }

        menuBar.attach(app: self)
        if settings.healthMonitoring { health.startMonitoring() }
        startTrashRefreshLoop()
        refreshLoginItemStatus()
        if settings.autoCheckUpdates {
            Task { await autoCheckForUpdates() }
        }
        if settings.autoCheckAppUpdates {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await updater.autoCheckIfNeeded()
            }
        }
    }

    deinit {
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        if let unmountObserver { NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver) }
        trashTask?.cancel()
    }

    // MARK: Navigation

    func select(_ module: ModuleID) {
        selectedModule = module
        searchText = ""
        if module == .health, health.snapshot == nil {
            Task { await health.refreshNow() }
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openMainWindowHandler?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        }
    }

    func focusSearch() {
        searchFocusRequest = UUID()
    }

    func scanCurrentOrAll() {
        if selectedModule == .overview {
            startGlobalScan()
            return
        }
        switch selectedModule {
        case .disk: disk.startScan()
        case .maintenance: maintenance.startScan()
        case .uninstaller: uninstaller.startScan()
        case .updater: updater.startScan()
        case .privacy: privacy.startScan()
        case .extensions: extensions.startScan()
        case .loginItems: loginItems.startScan()
        case .health: Task { await health.refreshNow() }
        case .power: Task { await power.refresh() }
        case .permanentDelete: permanentDelete.toast(L("Permanent Delete has no scan. Add files to review them."))
        case .overview: startGlobalScan()
        }
    }

    func cancelCurrentScan() {
        if isGlobalScanning { cancelGlobalScan(); return }
        switch selectedModule {
        case .disk: disk.cancel()
        case .maintenance: maintenance.cancel()
        case .uninstaller: uninstaller.cancel()
        case .updater: updater.cancel()
        case .privacy: privacy.cancel()
        case .extensions: extensions.cancel()
        case .loginItems: loginItems.cancel()
        default: break
        }
    }

    // MARK: Global scan

    var isAnyModuleScanning: Bool {
        disk.isScanning || maintenance.isScanning || uninstaller.isScanning || updater.isScanning || privacy.isScanning || extensions.isScanning || loginItems.isScanning
    }

    func startGlobalScan() {
        guard !isGlobalScanning else { return }
        isGlobalScanning = true
        globalProgress = 0
        globalPhase = L("Getting things ready…")
        disk.startScan()
        maintenance.startScan()
        uninstaller.startScan()
        if settings.appUpdatesInGlobalScan { updater.startScan() }
        privacy.startScan()
        extensions.startScan()
        loginItems.startScan()
        Task { await power.refresh() }
        Task { await health.refreshNow() }
        globalTask?.cancel()
        globalTask = Task {
            while isAnyModuleScanning {
                if Task.isCancelled { break }
                let phases = [disk.isScanning ? disk.phase : "", maintenance.isScanning ? maintenance.phase : "", uninstaller.isScanning ? uninstaller.phase : "", updater.isScanning ? updater.phase : "", privacy.isScanning ? privacy.phase : "", extensions.isScanning ? extensions.phase : "", loginItems.isScanning ? loginItems.phase : ""].filter { !$0.isEmpty }
                let values: [Double] = [disk.isScanning ? disk.progress : 1, maintenance.isScanning ? maintenance.progress : 1, uninstaller.isScanning ? uninstaller.progress : 1, updater.isScanning ? updater.progress : 1, privacy.isScanning ? privacy.progress : 1, extensions.isScanning ? extensions.progress : 1, loginItems.isScanning ? loginItems.progress : 1]
                globalProgress = values.reduce(0, +) / Double(max(1, values.count))
                if let current = phases.first { globalPhase = current }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            // cancelGlobalScan already reset the state; don't report completion.
            if Task.isCancelled { return }
            globalProgress = 1
            globalPhase = L("Scan complete")
            isGlobalScanning = false
            lastGlobalScan = Date()
            settings.lastScan = Date()
            hasScannedThisSession = true
            await refreshLiveTrashSize()
            if settings.notificationsEnabled {
                if settings.cleanupReminders {
                    NotificationService.shared.notifyScanComplete(bytes: estimatedRemovableBytes)
                }
                // Continuous thresholds are evaluated by the Mac Health monitor,
                // so a scan does not duplicate a memory, CPU, Trash or disk alert.
            }
            if let volume = FileSafety.rootVolume() { diskUsage = volume }
        }
    }

    func cancelGlobalScan() {
        disk.cancel()
        maintenance.cancel()
        uninstaller.cancel()
        updater.cancel()
        privacy.cancel()
        extensions.cancel()
        loginItems.cancel()
        globalTask?.cancel()
        isGlobalScanning = false
        globalProgress = 0
        globalPhase = L("Scan cancelled")
        toast(L("Scan cancelled"))
    }

    // MARK: Overview metrics

    var estimatedRemovableBytes: Int64 {
        disk.estimatedBytes + maintenance.estimatedBytes + privacy.items.filter { !$0.isInformational && !$0.isProtected }.reduce(0) { $0 + $1.size }
    }

    var estimatedRemovableCount: Int {
        disk.items.filter { !$0.isInformational && !$0.isProtected && $0.category != .trash }.count
            + maintenance.items.filter { !$0.isInformational && !$0.isProtected }.count
            + privacy.items.filter { !$0.isInformational && !$0.isProtected && $0.category != .recentItems }.count
    }

    var bytesMovedToTrash: Int64 {
        history.events.filter { event in
            [ModuleID.disk, .maintenance, .uninstaller, .privacy].contains(event.module) && event.movedToTrash != false
        }.reduce(0) { $0 + $1.bytes }
    }

    var lastScanDate: Date? {
        let dates = [disk.lastScan, maintenance.lastScan, uninstaller.lastScan, updater.lastScan, privacy.lastScan, extensions.lastScan, loginItems.lastScan, lastGlobalScan, settings.lastScan].compactMap { $0 }
        return dates.max()
    }

    var summaries: [ModuleSummary] {
        [
            ModuleSummary(id: .disk, bytes: disk.estimatedBytes, itemCount: disk.items.filter { $0.category != .trash && !$0.isInformational && !$0.isProtected }.count, lastScan: disk.lastScan, note: disk.report == nil ? L("No scan results yet.") : nil),
            ModuleSummary(id: .maintenance, bytes: maintenance.estimatedBytes, itemCount: maintenance.items.filter { !$0.isInformational }.count, lastScan: maintenance.lastScan, note: maintenance.report == nil ? L("No scan results yet.") : nil),
            ModuleSummary(id: .uninstaller, bytes: uninstaller.apps.reduce(0) { $0 + $1.size }, itemCount: uninstaller.apps.count, lastScan: uninstaller.lastScan, note: uninstaller.apps.isEmpty ? L("No scan results yet.") : nil),
            ModuleSummary(id: .updater, bytes: 0, itemCount: updater.availableRecords.count, lastScan: updater.lastScan, note: updater.lastScan == nil ? L("No scan results yet.") : (updater.availableRecords.isEmpty ? L("Up to date") : L("%d updates available", updater.availableRecords.count))),
            ModuleSummary(id: .privacy, bytes: privacy.items.filter { !$0.isInformational && !$0.isProtected }.reduce(0) { $0 + $1.size }, itemCount: privacy.items.filter { $0.category != .recentItems && !$0.isInformational }.count, lastScan: privacy.lastScan, note: privacy.report == nil ? L("No scan results yet.") : nil),
            ModuleSummary(id: .health, bytes: 0, itemCount: health.activeAlerts.count, lastScan: health.snapshot?.readAt, note: health.snapshot == nil ? L("Reading this Mac…") : (health.activeAlerts.isEmpty ? L("All clear") : health.statusHeadline)),
            ModuleSummary(id: .extensions, bytes: 0, itemCount: extensions.records.count, lastScan: extensions.lastScan, note: extensions.lastScan == nil ? L("No scan results yet.") : nil),
            ModuleSummary(id: .loginItems, bytes: 0, itemCount: loginItems.records.count, lastScan: loginItems.lastScan, note: loginItems.lastScan == nil ? L("No scan results yet.") : nil),
            ModuleSummary(id: .power, bytes: 0, itemCount: power.snapshot?.settings.count ?? 0, lastScan: power.snapshot?.readAt, note: power.snapshot == nil ? L("Read-only") : nil),
        ]
    }

    func summary(for module: ModuleID) -> ModuleSummary {
        summaries.first { $0.id == module } ?? ModuleSummary(id: module, bytes: 0, itemCount: 0, lastScan: nil, note: nil)
    }

    func refreshLiveTrashSize() async {
        let measured = await Task.detached(priority: .utility) {
            FileSafety.directorySize(AppPaths.trash).size
        }.value
        trashBytesLive = measured
        health.trashBytes = measured
    }

    private func startTrashRefreshLoop() {
        trashTask?.cancel()
        trashTask = Task { [weak self] in
            await self?.refreshLiveTrashSize()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshLiveTrashSize()
            }
        }
    }

    // MARK: - Menu bar / login item

    func setBackgroundMode(_ enabled: Bool) {
        settings.backgroundMode = enabled
        if enabled && !settings.menuBarEnabled {
            settings.menuBarEnabled = true
        }
        menuBar.sync()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            settings.openAtLogin = enabled
            refreshLoginItemStatus()
            toast(enabled ? L("Fettle will open at login.") : L("Fettle will no longer open at login."))
        } catch {
            settings.openAtLogin = LoginItemManager.isEnabled
            loginItemError = error.localizedDescription
            refreshLoginItemStatus()
            toast(L("The login item could not be changed. %@", error.localizedDescription))
        }
    }

    func refreshLoginItemStatus() {
        let status = LoginItemManager.status
        switch status {
        case .enabled:
            settings.openAtLogin = true
            loginItemError = nil
        case .notRegistered, .notFound:
            settings.openAtLogin = false
            loginItemError = nil
        case .requiresApproval:
            settings.openAtLogin = true
        @unknown default:
            break
        }
        loginItemStatus = LoginItemManager.statusText
    }

    func openLoginItemsSettings() {
        LoginItemManager.openLoginItemsSettings()
    }

    func refreshDiskUsage() {
        diskUsage = FileSafety.rootVolume()
    }

    // MARK: Notifications

    func updateNotificationSchedule(requestAuthorization: Bool) async {
        if requestAuthorization {
            let granted = await NotificationService.shared.requestAuthorization()
            settings.notificationsEnabled = granted
            if !granted { toast(L("Notifications are off until you allow them.")) }
        }
        NotificationService.shared.scheduleReminders(
            cleanup: settings.cleanupReminders,
            trash: settings.trashReminder,
            intervalDays: settings.reminderIntervalDays,
            trashThresholdMB: settings.trashThresholdMB
        )
    }

    // MARK: Updates

    func autoCheckForUpdates() async {
        guard settings.autoCheckUpdates, !settings.feedURL.isEmpty else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        await checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) async {
        updateState = .checking
        let result = await UpdateChecker.check(feedURL: settings.feedURL, publicKeyBase64: settings.publicKey)
        settings.lastUpdateCheck = Date()
        switch result {
        case .notConfigured:
            updateState = .notConfigured
            if manual { toast(L("No signed release feed is configured. Add a feed URL and its Ed25519 public key to enable update checks.")) }
        case .upToDate(let version):
            updateState = .upToDate(version)
            if manual { toast(L("You are up to date.")) }
        case .available(let feed):
            updateState = .available(feed)
            toast(L("A newer version is available.") + " \(feed.version)")
        case .invalidSignature:
            updateState = .failed(L("The update feed could not be verified."))
        case .unreachable(let reason):
            updateState = .failed(L("The update feed could not be reached.") + " " + reason)
        case .invalidFeed:
            updateState = .failed(L("The update feed could not be verified."))
        }
    }

    // MARK: Ignore list

    func ignore(_ item: ScanItem) {
        ignoreList.add(item.url)
        disk.removeFromReport(item)
        maintenance.removeFromReport(item)
        privacy.removeFromReport(item)
        toast(L("Add to Ignore List") + ": " + item.name)
    }

    // MARK: Toast

    func toast(_ message: String) {
        toast = ToastMessage(text: message)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
}

extension BaseScanModel {
    func removeFromReport(_ item: ScanItem) {
        guard var current = report else { return }
        current.items.removeAll { $0.id == item.id }
        report = current
        selectedIDs.remove(item.id)
    }
}

extension PrivacyModel {
    func removeFromReport(_ item: ScanItem) {
        guard var current = report else { return }
        current.items.removeAll { $0.id == item.id }
        report = current
        selectedIDs.remove(item.id)
    }
}
