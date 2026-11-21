import Foundation
import SwiftUI
import AppKit

@MainActor
final class UpdaterModel: ObservableObject {
    let settings: AppSettings
    let ignoreList: IgnoreListStore
    let history: HistoryStore

    @Published var records: [AppUpdateRecord] = []
    @Published var skipped: [SkippedItem] = []
    @Published var notes: [String] = []
    @Published var isScanning = false
    @Published var isOpening = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var showReview = false
    @Published var reviewRecords: [AppUpdateRecord] = []
    @Published var reviewIDs: Set<String> = []
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var lastScan: Date?
    @Published var errorMessage: String?

    private var scanTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        self.settings = settings
        self.ignoreList = ignoreList
        self.history = history
    }

    // MARK: Counts and filters

    var availableRecords: [AppUpdateRecord] {
        records.filter { $0.status == .available }
    }

    var appStoreRecords: [AppUpdateRecord] {
        records.filter { $0.status == .appStore }
    }

    var appleRecords: [AppUpdateRecord] {
        records.filter { $0.status == .appleSoftwareUpdate }
    }

    var upToDateRecords: [AppUpdateRecord] {
        records.filter { $0.status == .upToDate }
    }

    var otherRecords: [AppUpdateRecord] {
        records.filter { [.noChannel, .failed, .incompatible].contains($0.status) }
    }

    var selectedRecords: [AppUpdateRecord] {
        availableRecords.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedRecords.reduce(0) { $0 + ($1.updateSize ?? 0) }
    }

    func isActionable(_ record: AppUpdateRecord) -> Bool {
        record.status.isActionable
    }

    // MARK: Scan

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    func runScan() async {
        cancelFlag.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        isScanning = true
        isOpening = false
        progress = 0
        phase = L("Preparing…")
        errorMessage = nil
        showReview = false
        reviewRecords = []
        reviewIDs = []

        let extraFolders = settings.extraAppFolders
        let ignore = ignoreList.paths
        let relay = ScanProgressRelay { update in
            Task { @MainActor in
                guard !flag.isCancelled else { return }
                self.progress = max(0.01, min(0.99, update.fraction))
                self.phase = update.message
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            await UpdaterScanner.scan(
                extraFolders: extraFolders,
                ignoreList: ignore,
                progress: { relay.send($0) },
                cancelled: { flag.isCancelled }
            )
        }.value

        guard flag === cancelFlag else { return }
        guard !flag.isCancelled else {
            isScanning = false
            progress = 0
            phase = L("Scan cancelled")
            toast(L("Scan cancelled"))
            return
        }

        records = result.records
        skipped = result.skipped
        notes = result.notes
        isScanning = false
        progress = 1
        phase = L("Scan complete")
        lastScan = Date()
        settings.lastAppUpdateCheck = Date()
        settings.lastScan = Date()
        selectedIDs = selectedIDs.intersection(Set(availableRecords.map { $0.id }))
        if records.isEmpty, let error = errorMessage {
            toast(error)
        } else if availableRecords.isEmpty && !records.isEmpty {
            toast(L("No app updates were reported."))
        } else if !availableRecords.isEmpty {
            toast(L("%d app updates are ready to review.", availableRecords.count))
        }
    }

    func cancel() {
        guard isScanning else { return }
        cancelFlag.cancel()
        scanTask?.cancel()
        isScanning = false
        progress = 0
        phase = L("Scan cancelled")
        toast(L("Scan cancelled"))
    }

    func autoCheckIfNeeded() async {
        guard settings.autoCheckAppUpdates else { return }
        if let last = settings.lastAppUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        await runScan()
    }

    // MARK: Selection

    func toggle(_ record: AppUpdateRecord) {
        guard record.status == .available else { return }
        if selectedIDs.contains(record.id) {
            selectedIDs.remove(record.id)
        } else {
            selectedIDs.insert(record.id)
        }
    }

    func selectAll(_ records: [AppUpdateRecord]? = nil) {
        let pool = records ?? availableRecords
        selectedIDs = Set(pool.filter { $0.status == .available }.map { $0.id })
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    // MARK: Review

    func beginReview() {
        let chosen = selectedRecords
        guard !chosen.isEmpty else {
            toast(L("Nothing is selected. Tick one or more updates, then review."))
            return
        }
        reviewRecords = chosen
        reviewIDs = Set(chosen.map { $0.id })
        showReview = true
    }

    func toggleReview(_ record: AppUpdateRecord) {
        if reviewIDs.contains(record.id) {
            reviewIDs.remove(record.id)
        } else {
            reviewIDs.insert(record.id)
        }
    }

    func requestOpenSelected() {
        let chosen = reviewRecords.filter { reviewIDs.contains($0.id) }
        guard !chosen.isEmpty else {
            toast(L("Select at least one update to open."))
            return
        }
        showReview = false
        open(chosen, title: L("Update pages opened"))
    }

    func openSingle(_ record: AppUpdateRecord) {
        if record.status == .noChannel {
            openApp(record)
            return
        }
        open([record], title: L("Update page opened"))
    }

    private func open(_ chosen: [AppUpdateRecord], title: String) {
        isOpening = true
        var results: [ItemResult] = []
        var openedSystemPage: URL?
        for record in chosen {
            guard let url = record.actionURL else {
                results.append(ItemResult(
                    path: record.bundleURL.path,
                    name: record.appName,
                    category: .app,
                    success: false,
                    message: L("No update page is available for this app.")
                ))
                continue
            }
            if [AppUpdateSource.appStore, .appleSoftwareUpdate].contains(record.source), openedSystemPage == url {
                results.append(ItemResult(
                    path: record.bundleURL.path,
                    name: record.appName,
                    category: .app,
                    success: true,
                    message: L("The same system page is already open.")
                ))
                continue
            }
            let success = SystemActions.open(url)
            if success {
                if [AppUpdateSource.appStore, .appleSoftwareUpdate].contains(record.source) {
                    openedSystemPage = url
                }
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index].openedAt = Date()
                }
                results.append(ItemResult(
                    path: record.bundleURL.path,
                    name: record.appName,
                    category: .app,
                    success: true,
                    message: record.source == .sparkle ? L("Opened the vendor's update page.") : L("Opened the supported system page."),
                    bytes: 0
                ))
            } else {
                results.append(ItemResult(
                    path: record.bundleURL.path,
                    name: record.appName,
                    category: .app,
                    success: false,
                    message: L("macOS could not open this address.")
                ))
            }
        }
        isOpening = false
        let succeeded = results.filter { $0.success }.count
        let failure = results.filter { !$0.success }.count
        let message: String
        if failure == 0 {
            message = L("Your browser or the supported system page is now open. Fettle does not install updates itself; the vendor, the App Store or Software Update finishes the job.")
        } else if succeeded == 0 {
            message = L("No update page could be opened. Nothing was changed.")
        } else {
            message = L("Some update pages could not be opened. Nothing was changed for those apps.")
        }
        let operation = OperationOutcome(
            title: title,
            message: message,
            results: results,
            bytes: 0,
            startedAt: Date(),
            finishedAt: Date()
        )
        outcome = operation
        history.record(module: .updater, action: L("Open app updates"), outcome: operation, movedToTrash: false)
        if failure > 0 {
            toast(L("Some update pages could not be opened"))
        } else {
            SoundPlayer.playSuccess(enabled: settings.soundEnabled, name: settings.soundName)
        }
    }

    // MARK: Ignore and reveal

    func ignore(_ record: AppUpdateRecord) {
        ignoreList.add(record.bundleURL)
        records.removeAll { $0.id == record.id }
        selectedIDs.remove(record.id)
        reviewRecords.removeAll { $0.id == record.id }
        reviewIDs.remove(record.id)
        toast(L("Added to the ignore list") + ": " + record.appName)
    }

    func reveal(_ record: AppUpdateRecord) {
        SystemActions.reveal(record.bundleURL)
    }

    func openApp(_ record: AppUpdateRecord) {
        SystemActions.open(record.bundleURL)
    }

    func copyFeed(_ record: AppUpdateRecord) {
        guard let url = record.feedURL else {
            toast(L("This app has no update feed to copy."))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toast(L("Update feed address copied."))
    }

    func copyDownload(_ record: AppUpdateRecord) {
        guard let url = record.actionURL else {
            toast(L("This app has no update page to copy."))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toast(L("Update page address copied."))
    }

    // MARK: Toast

    func toast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
}
