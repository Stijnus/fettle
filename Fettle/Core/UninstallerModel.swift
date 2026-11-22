import Foundation
import SwiftUI
import AppKit

@MainActor
final class UninstallerModel: ObservableObject {
    let settings: AppSettings
    let ignoreList: IgnoreListStore
    let history: HistoryStore

    @Published var apps: [AppRecord] = []
    @Published var skipped: [SkippedItem] = []
    @Published var notes: [String] = []
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var selectedAppIDs: Set<String> = []
    @Published var showReview = false
    @Published var reviewApps: [AppRecord] = []
    @Published var reviewAssociations: [ScanItem] = []
    @Published var reviewAppIDs: Set<String> = []
    @Published var reviewAssociationIDs: Set<String> = []
    @Published var confirmation: ConfirmationRequest?
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var errorMessage: String?
    @Published var appFolders: [String] = []
    @Published var leftoverReport: ScanReport?
    @Published var leftoverSelectedIDs: Set<String> = []
    @Published var isScanningLeftovers = false
    @Published var leftoverProgress: Double = 0
    @Published var leftoverPhase = ""
    @Published var lastScan: Date?

    private var scanTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var leftoverCancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        self.settings = settings
        self.ignoreList = ignoreList
        self.history = history
        self.appFolders = settings.extraAppFolders
    }

    var runningApps: [AppRecord] { apps.filter { $0.isRunning } }
    var selectedApps: [AppRecord] { apps.filter { selectedAppIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedApps.reduce(0) { $0 + $1.size } }
    var availableApps: [AppRecord] { apps.filter { !$0.isSystem && $0.accessError == nil } }

    func isSelectable(_ app: AppRecord) -> Bool {
        !app.isSystem && app.accessError == nil
    }

    func toggle(_ app: AppRecord) {
        guard isSelectable(app) else { return }
        if selectedAppIDs.contains(app.id) { selectedAppIDs.remove(app.id) } else { selectedAppIDs.insert(app.id) }
    }

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    func runScan() async {
        // Each run owns its flag; stopping the previous run cannot be undone.
        cancelFlag.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        isScanning = true
        progress = 0
        phase = L("Preparing…")
        errorMessage = nil
        let extra = appFolders
        let ignore = ignoreList.paths
        let relay = ScanProgressRelay { update in
            Task { @MainActor in
                guard !flag.isCancelled else { return }
                self.progress = max(0.01, min(0.99, update.fraction))
                self.phase = update.message
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            UninstallerScanner.scan(extraFolders: extra, ignoreList: ignore, progress: { relay.send($0) }, cancelled: { flag.isCancelled })
        }.value
        // A newer run replaced this one; it owns the state now.
        guard flag === cancelFlag else { return }
        guard !flag.isCancelled else {
            isScanning = false
            phase = L("Scan cancelled")
            toast(L("Scan cancelled"))
            return
        }
        apps = result.apps
        settings.lastScan = Date()
        skipped = result.skipped
        notes = result.notes
        selectedAppIDs = selectedAppIDs.intersection(Set(apps.filter { isSelectable($0) }.map { $0.id }))
        isScanning = false
        progress = 1
        phase = L("Scan complete")
        lastScan = Date()
    }

    func cancel() {
        guard isScanning else { return }
        cancelFlag.cancel()
        scanTask?.cancel()
        isScanning = false
        phase = L("Scan cancelled")
        toast(L("Scan cancelled"))
    }

    func beginReview() {
        let chosen = selectedApps
        guard !chosen.isEmpty else {
            toast(L("Nothing is selected. Tick one or more apps, then review."))
            return
        }
        reviewApps = chosen
        reviewAppIDs = Set(chosen.map { $0.id })
        var associations: [ScanItem] = []
        var preSelected = Set<String>()
        for app in chosen {
            for item in app.associations {
                associations.append(item)
                if !item.isAppData { preSelected.insert(item.id) }
            }
        }
        reviewAssociations = associations
        reviewAssociationIDs = preSelected
        showReview = true
    }

    func toggleReviewApp(_ app: AppRecord) {
        if reviewAppIDs.contains(app.id) { reviewAppIDs.remove(app.id) } else { reviewAppIDs.insert(app.id) }
    }

    func toggleReviewAssociation(_ item: ScanItem) {
        if reviewAssociationIDs.contains(item.id) { reviewAssociationIDs.remove(item.id) } else { reviewAssociationIDs.insert(item.id) }
    }

    func selectAllAssociations(includeData: Bool) {
        reviewAssociationIDs = Set(reviewAssociations.filter { includeData || !$0.isAppData }.map { $0.id })
    }

    func requestRemoval() {
        let chosenApps = reviewApps.filter { reviewAppIDs.contains($0.id) }
        guard !chosenApps.isEmpty else {
            toast(L("Select the app and the associated items you want to remove."))
            return
        }
        var items: [ScanItem] = []
        for app in chosenApps {
            if let item = appItem(app) { items.append(item) }
        }
        items += reviewAssociations.filter { reviewAssociationIDs.contains($0.id) }
        let bytes = items.reduce(0) { $0 + $1.size }
        let running = chosenApps.filter { $0.isRunning }
        var message = L("The apps and the items you selected will be moved to the Trash. Shared containers and files that do not exactly match an app's bundle identifier are left in place.")
        if !running.isEmpty {
            message += "\n\n" + L("This app is still running. Quit it and rescan before removing it.")
        }
        confirmation = ConfirmationRequest(
            title: L("Remove %d apps and %d associated items?", chosenApps.count, items.count - chosenApps.count),
            message: message,
            actionLabelKey: "Remove",
            isPermanent: false,
            itemCount: items.count,
            byteCount: bytes,
            items: items,
            action: .removeApps
        )
    }

    func appItem(_ app: AppRecord) -> ScanItem? {
        guard let fingerprint = app.fingerprint else { return nil }
        var item = ScanItem.make(
            url: app.bundleURL,
            category: .app,
            size: app.size,
            fingerprint: fingerprint,
            location: app.source,
            detail: L("Version %@ · %@", app.version, app.bundleID),
            evidence: [L("Exact identifier match"), app.bundleID],
            bundleID: app.bundleID,
            appName: app.name,
            scope: .uninstaller
        )
        item.isRunningApp = app.isRunning
        return item
    }

    func performConfirmed(_ request: ConfirmationRequest) {
        guard case .removeApps = request.action else { return }
        confirmation = nil
        let roots = UninstallerScanner.roots(extraFolders: appFolders) + reviewApps.map { $0.bundleURL.deletingLastPathComponent() }
        let ignore = ignoreList.paths
        let chosenApps = reviewApps.filter { reviewAppIDs.contains($0.id) }
        isWorking = true
        Task {
            // Check now, not the flag captured at scan time.
            let runningApps = chosenApps.filter { SystemActions.isRunning(appAt: $0.bundleURL) || SystemActions.isRunning(bundleID: $0.bundleID) }
            for app in runningApps {
                _ = SystemActions.quit(bundleID: app.bundleID)
            }
            if !runningApps.isEmpty {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            // An app that is still running keeps its bundle and all of its files.
            let stillRunning = Set(runningApps.filter { SystemActions.isRunning(appAt: $0.bundleURL) || SystemActions.isRunning(bundleID: $0.bundleID) }.map { $0.bundleID })
            let movable = request.items.filter { item in
                guard let id = item.bundleID else { return true }
                return !stillRunning.contains(id)
            }
            let held = request.items.filter { item in
                guard let id = item.bundleID else { return false }
                return stillRunning.contains(id)
            }.map { ItemResult(path: $0.path, name: $0.name, category: $0.category, success: false, skipped: true, message: SafetyError.running.localizedDescription, bytes: 0) }
            var outcome = await Task.detached(priority: .userInitiated) {
                FileSafety.moveToTrash(movable, scope: .uninstaller, extraRoots: roots, ignoreList: ignore)
            }.value
            outcome.results += held
            self.isWorking = false
            self.outcome = outcome
            let succeeded = Set(outcome.results.filter { $0.success }.map { $0.path })
            self.apps.removeAll { app in succeeded.contains(app.bundleURL.path) }
            for index in self.apps.indices {
                self.apps[index].associations.removeAll { succeeded.contains($0.path) }
            }
            self.reviewApps.removeAll { succeeded.contains($0.bundleURL.path) }
            self.reviewAssociations.removeAll { succeeded.contains($0.path) }
            self.reviewAppIDs = self.reviewAppIDs.filter { id in self.reviewApps.contains(where: { $0.id == id }) }
            self.reviewAssociationIDs = self.reviewAssociationIDs.filter { id in self.reviewAssociations.contains(where: { $0.id == id }) }
            if self.reviewApps.isEmpty { self.showReview = false }
            self.history.record(module: .uninstaller, actionKey: "Remove apps", outcome: outcome)
            SoundPlayer.playSuccess(enabled: self.settings.soundEnabled, name: self.settings.soundName)
            if outcome.failureCount > 0 { self.toast(L("Some items could not be removed")) }
        }
    }

    func selectAllApps(_ apps: [AppRecord]? = nil) {
        let pool = apps ?? availableApps
        selectedAppIDs = Set(pool.filter { isSelectable($0) }.map { $0.id })
    }

    func cancelLeftoverScan() {
        guard isScanningLeftovers else { return }
        leftoverCancelFlag.cancel()
        leftoverTask?.cancel()
        isScanningLeftovers = false
        leftoverPhase = L("Scan cancelled")
    }

    func quitApp(_ app: AppRecord) {
        _ = SystemActions.quit(bundleID: app.bundleID)
        toast(L("Quit App"))
    }

    func quitRunningApps() {
        for app in runningApps { _ = SystemActions.quit(bundleID: app.bundleID) }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            startScan()
        }
    }

    func openVendorUninstaller(_ app: AppRecord) {
        guard let url = app.vendorUninstaller else { return }
        SystemActions.openVendorUninstaller(url)
        toast(L("This app includes its own uninstaller. Use it, then rescan."))
    }

    func addAppFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !settings.extraAppFolders.contains(path) {
            settings.extraAppFolders.append(path)
        }
        appFolders = settings.extraAppFolders
        startScan()
    }

    func removeAppFolder(_ path: String) {
        settings.extraAppFolders.removeAll { $0 == path }
        appFolders = settings.extraAppFolders
        startScan()
    }

    // MARK: Leftovers

    func startLeftoverScan() {
        leftoverTask?.cancel()
        leftoverTask = Task {
            isScanningLeftovers = true
            leftoverProgress = 0
            leftoverPhase = L("Preparing…")
            let ignore = ignoreList.paths
            leftoverCancelFlag.cancel()
            let flag = CancelFlag()
            leftoverCancelFlag = flag
            let relay = ScanProgressRelay { update in
                Task { @MainActor in
                    self.leftoverProgress = update.fraction
                    self.leftoverPhase = update.message
                }
            }
            let report = await Task.detached(priority: .userInitiated) {
                UninstallerScanner.scanRemovedAppLeftovers(ignoreList: ignore, progress: { relay.send($0) }, cancelled: { flag.isCancelled })
            }.value
            guard flag === leftoverCancelFlag else { return }
            guard !flag.isCancelled else {
                isScanningLeftovers = false
                leftoverPhase = L("Scan cancelled")
                return
            }
            isScanningLeftovers = false
            leftoverProgress = 1
            leftoverReport = report
            leftoverSelectedIDs = []
        }
    }

    func requestLeftoverRemoval() {
        guard let report = leftoverReport else { return }
        let chosen = report.items.filter { leftoverSelectedIDs.contains($0.id) }
        guard !chosen.isEmpty else {
            toast(L("Select at least one item first."))
            return
        }
        confirmation = ConfirmationRequest(
            title: L("Move %d items to the Trash?", chosen.count),
            message: L("These items will be moved to the Trash. You can restore them from the Trash until you empty it."),
            actionLabelKey: "Move to Trash",
            isPermanent: false,
            itemCount: chosen.count,
            byteCount: chosen.reduce(0) { $0 + $1.size },
            items: chosen,
            action: .moveSelectedToTrash
        )
    }

    func performLeftoverRemoval(_ request: ConfirmationRequest) {
        confirmation = nil
        let ignore = ignoreList.paths
        let roots = UninstallerScanner.roots(extraFolders: [])
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                FileSafety.moveToTrash(request.items, scope: .maintenance, extraRoots: roots, ignoreList: ignore)
            }.value
            self.isWorking = false
            self.outcome = outcome
            let succeeded = Set(outcome.results.filter { $0.success }.map { $0.path })
            if var report = self.leftoverReport {
                report.items.removeAll { succeeded.contains($0.path) }
                self.leftoverReport = report
            }
            self.leftoverSelectedIDs = []
            self.history.record(module: .uninstaller, actionKey: "Leftovers from removed apps", outcome: outcome)
            SoundPlayer.playSuccess(enabled: self.settings.soundEnabled, name: self.settings.soundName)
        }
    }

    func toast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
}
