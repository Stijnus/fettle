import Foundation
import SwiftUI

@MainActor
final class PrivacyModel: ObservableObject {
    let settings: AppSettings
    let ignoreList: IgnoreListStore
    let history: HistoryStore

    @Published var report: ScanReport?
    @Published var profiles: [BrowserProfileSummary] = []
    @Published var recentItems: [RecentItemSummary] = []
    @Published var notes: [String] = []
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var confirmation: ConfirmationRequest?
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var lastScan: Date?

    private var scanTask: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        self.settings = settings
        self.ignoreList = ignoreList
        self.history = history
    }

    var items: [ScanItem] { report?.items ?? [] }
    var skipped: [SkippedItem] { report?.skipped ?? [] }

    func isSelectable(_ item: ScanItem) -> Bool {
        !item.isInformational && !item.isProtected && item.category != .recentItems
    }

    func selectedItems() -> [ScanItem] {
        items.filter { selectedIDs.contains($0.id) && isSelectable($0) }
    }

    func filteredItems(query: String) -> [ScanItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.path.localizedCaseInsensitiveContains(trimmed)
                || $0.location.localizedCaseInsensitiveContains(trimmed)
                || $0.category.title.localizedCaseInsensitiveContains(trimmed)
        }
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
        let ignore = ignoreList.paths
        let relay = ScanProgressRelay { update in
            Task { @MainActor in
                guard !flag.isCancelled else { return }
                self.progress = max(0.01, min(0.99, update.fraction))
                self.phase = update.message
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            PrivacyScanner.scan(ignoreList: ignore, progress: { relay.send($0) }, cancelled: { flag.isCancelled })
        }.value
        // A newer run replaced this one; it owns the state now.
        guard flag === cancelFlag else { return }
        guard !flag.isCancelled else {
            isScanning = false
            phase = L("Scan cancelled")
            toast(L("Scan cancelled"))
            return
        }
        report = result.report
        settings.lastScan = result.report.scannedAt
        profiles = result.profiles
        recentItems = result.recentItems
        notes = result.notes
        selectedIDs = []
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

    func toggle(_ item: ScanItem) {
        guard isSelectable(item) else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func selectAll(query: String) {
        selectedIDs = Set(filteredItems(query: query).filter { isSelectable($0) }.map { $0.id })
    }

    func requestClear() {
        let selected = selectedItems()
        guard !selected.isEmpty else {
            toast(L("Clear at least one item."))
            return
        }
        var seen = Set<String>()
        let chosen = (selected + selected.flatMap { PrivacyScanner.sidecarItems(for: $0) })
            .filter { seen.insert($0.id).inserted }
        let includesCookies = chosen.contains { $0.category == .cookies || $0.category == .websiteData }
        var message = L("Selected caches, cookies, history and download records will be moved to the Trash or cleared with the browser's own database. Downloaded files are never deleted.")
        if includesCookies {
            message += "\n\n" + L("Clearing this data will sign you out of websites.")
        }
        confirmation = ConfirmationRequest(
            title: L("Clear %d browser items?", chosen.count),
            message: message,
            actionLabelKey: "Clear",
            isPermanent: false,
            itemCount: chosen.count,
            byteCount: chosen.reduce(0) { $0 + $1.size },
            items: chosen,
            action: .clearBrowserData
        )
    }

    func performClear(_ request: ConfirmationRequest) {
        confirmation = nil
        isWorking = true
        let ignore = ignoreList.paths
        let chosen = request.items
        Task {
            var results: [ItemResult] = []
            let ordered = chosen.sorted { lhs, rhs in
                if lhs.category == .downloadHistory && rhs.category != .downloadHistory { return true }
                if rhs.category == .downloadHistory && lhs.category != .downloadHistory { return false }
                return lhs.path < rhs.path
            }
            for item in ordered {
                if item.category == .downloadHistory {
                    results.append(await Task.detached(priority: .userInitiated) {
                        PrivacyScanner.clearDownloadHistory(item: item)
                    }.value)
                    continue
                }
                if PrivacyScanner.isFirefoxHistory(item) {
                    results.append(await Task.detached(priority: .userInitiated) {
                        PrivacyScanner.clearFirefoxHistory(item: item)
                    }.value)
                    continue
                }
                let requiresQuit = item.category == .cookies || item.category == .browsingHistory || item.category == .websiteData
                if requiresQuit, let bundleID = item.bundleID, SystemActions.isRunning(bundleID: bundleID) {
                    results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("This browser is running. Quit it and rescan before clearing history or cookies."), bytes: 0))
                    continue
                }
                let outcome = await Task.detached(priority: .userInitiated) {
                    FileSafety.moveToTrash([item], scope: .privacy, ignoreList: ignore)
                }.value
                results.append(contentsOf: outcome.results)
            }
            let before = FileSafety.freeSpace()
            let combined = OperationOutcome(
                title: L("Browser data cleared"),
                message: L("Selected browser data was cleared. You may need to sign in to websites again."),
                results: results,
                bytes: results.filter { $0.success }.reduce(0) { $0 + $1.bytes },
                freeSpaceBefore: before,
                freeSpaceAfter: FileSafety.freeSpace()
            )
            self.isWorking = false
            self.outcome = combined
            let succeeded = Set(results.filter { $0.success }.map { $0.path })
            if var current = self.report {
                current.items.removeAll { succeeded.contains($0.path) }
                self.report = current
            }
            self.selectedIDs = []
            self.history.record(module: .privacy, actionKey: "Clear browser data", outcome: combined)
            SoundPlayer.playSuccess(enabled: self.settings.soundEnabled, name: self.settings.soundName)
            if combined.failureCount > 0 { self.toast(L("One or more browser files could not be cleared. Quit the browser and try again.")) }
        }
    }

    func openPasswordSettings(_ browser: BrowserKind) {
        switch browser {
        case .safari:
            if !SystemActions.open(browser.passwordURL) {
                if let app = SystemActions.appURL(for: "com.apple.Safari") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
                toast(L("Open Safari > Settings > Passwords to review saved credentials."))
            }
        default:
            _ = SystemActions.openBrowserSettings(bundleID: browser.bundleID, urlString: browser.passwordURL)
        }
    }

    func openBrowserSettings(_ browser: BrowserKind) {
        _ = SystemActions.openBrowserSettings(bundleID: browser.bundleID, urlString: browser.extensionsURL)
    }

    func quitBrowser(_ browser: BrowserKind) {
        _ = SystemActions.quit(bundleID: browser.bundleID)
        toast(L("Quit %@", browser.displayName))
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
