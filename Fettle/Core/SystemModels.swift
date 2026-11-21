import Foundation
import SwiftUI
import AppKit

// MARK: - Power

@MainActor
final class PowerModel: ObservableObject {
    @Published var snapshot: PowerSnapshot?
    @Published var isReading = false
    @Published var errorMessage: String?

    func refresh() async {
        isReading = true
        let result = await Task.detached(priority: .userInitiated) { PowerReader.read() }.value
        snapshot = result
        isReading = false
    }

    func openBatterySettings() { SystemActions.openSettings(.battery) }
    func openEnergySaver() {
        if !SystemActions.open(SystemSettingsPane.energySaver.rawValue) {
            SystemActions.openSettings(.battery)
        }
    }
}

// MARK: - Extensions

@MainActor
final class ExtensionsModel: ObservableObject {
    let settings: AppSettings
    let ignoreList: IgnoreListStore

    @Published var records: [ExtensionRecord] = []
    @Published var notes: [String] = []
    @Published var profiles: [String] = []
    @Published var skipped: [SkippedItem] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var lastScan: Date?

    private var scanTask: Task<Void, Never>?
    private let cancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, ignoreList: IgnoreListStore) {
        self.settings = settings
        self.ignoreList = ignoreList
    }

    func startScan() { scanTask = Task { await runScan() } }

    func runScan() async {
        cancelFlag.reset()
        isScanning = true
        progress = 0
        phase = L("Preparing…")
        let flag = cancelFlag
        let relay = ScanProgressRelay { update in
            Task { @MainActor in
                self.progress = update.fraction
                self.phase = update.message
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            ExtensionsScanner.scan(progress: { relay.send($0) }, cancelled: { flag.isCancelled })
        }.value
        guard !flag.isCancelled else {
            isScanning = false
            phase = L("Scan cancelled")
            return
        }
        records = result.records
        settings.lastScan = Date()
        notes = result.notes
        profiles = result.browserProfiles
        skipped = result.skipped
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
    }

    func open(_ record: ExtensionRecord) {
        switch record.kind {
        case .system:
            SystemActions.openSettings(.loginItems)
        case .safari:
            if let app = SystemActions.appURL(for: "com.apple.Safari") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            toast(L("Open Safari > Settings > Extensions to review or disable it."))
        case .chromium:
            let bundle: String
            switch record.host {
            case "Microsoft Edge": bundle = "com.microsoft.edgemac"
            case "Opera": bundle = "com.operasoftware.Opera"
            default: bundle = "com.google.Chrome"
            }
            _ = SystemActions.openBrowserSettings(bundleID: bundle, urlString: record.managementURL ?? "chrome://extensions")
        case .firefox:
            _ = SystemActions.openBrowserSettings(bundleID: "org.mozilla.firefox", urlString: "about:addons")
        }
    }

    func openLoginItemsSettings() { SystemActions.openSettings(.loginItems) }

    func toast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
}

// MARK: - Login items

@MainActor
final class LoginItemsModel: ObservableObject {
    let settings: AppSettings
    let history: HistoryStore

    @Published var records: [LoginRecord] = []
    @Published var notes: [String] = []
    @Published var skipped: [SkippedItem] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var readableBackgroundItems = false
    @Published var backgroundItemsTimedOut = false
    @Published var confirmation: ConfirmationRequest?
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var lastScan: Date?

    private var scanTask: Task<Void, Never>?
    private let cancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    var manageable: [LoginRecord] { records.filter { $0.manageability == .manageable } }
    var background: [LoginRecord] { records.filter { $0.source == .backgroundItem } }

    func startScan() { scanTask = Task { await runScan() } }

    func runScan() async {
        cancelFlag.reset()
        isScanning = true
        progress = 0
        phase = L("Preparing…")
        let flag = cancelFlag
        let relay = ScanProgressRelay { update in
            Task { @MainActor in
                self.progress = update.fraction
                self.phase = update.message
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            LoginItemsScanner.scan(progress: { relay.send($0) }, cancelled: { flag.isCancelled })
        }.value
        guard !flag.isCancelled else {
            isScanning = false
            phase = L("Scan cancelled")
            return
        }
        records = result.records
        settings.lastScan = Date()
        notes = result.notes
        skipped = result.skipped
        readableBackgroundItems = result.readableBackgroundItems
        backgroundItemsTimedOut = result.backgroundTimedOut
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
    }

    func requestToggle(_ record: LoginRecord) {
        guard record.manageability == .manageable, let enabled = record.enabled else { return }
        let target = !enabled
        confirmation = ConfirmationRequest(
            title: target ? L("Turn on %@?", record.name) : L("Turn off %@?", record.name),
            message: target
                ? L("This loads the agent now and lets it start at login.")
                : L("This stops the agent now and prevents it from starting at login. You can turn it back on here."),
            actionLabel: target ? L("Enable") : L("Disable"),
            isPermanent: false,
            itemCount: 1,
            byteCount: 0,
            items: [],
            action: .toggleLoginItem(id: record.id, enable: target)
        )
    }

    func performConfirmed(_ request: ConfirmationRequest) {
        guard case .toggleLoginItem(let id, let enable) = request.action,
              let record = records.first(where: { $0.id == id }) else { return }
        confirmation = nil
        let result = LoginItemsScanner.setEnabled(record, enabled: enable)
        let itemResult = ItemResult(path: record.path ?? record.identifier, name: record.name, category: .loginItem, success: result.0, skipped: !result.0, message: result.0 ? nil : result.1, bytes: 0)
        let outcome = OperationOutcome(title: L("Login item changed"), message: result.1, results: [itemResult], bytes: 0)
        self.outcome = outcome
        history.record(module: .loginItems, action: enable ? L("Enable") : L("Disable"), outcome: outcome)
        SoundPlayer.playSuccess(enabled: settings.soundEnabled, name: settings.soundName)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await runScan()
        }
    }

    func openSystemSettings() { SystemActions.openSettings(.loginItems) }

    func toast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }
}

// MARK: - Permanent delete

@MainActor
final class PermanentDeleteModel: ObservableObject {
    let settings: AppSettings
    let history: HistoryStore

    @Published var items: [ScanItem] = []
    @Published var isCalculating = false
    @Published var confirmation: ConfirmationRequest?
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var refusals: [String] = []
    @Published var lastScan: Date?

    private var toastTask: Task<Void, Never>?

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func add(urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        let unique = urls.filter { !existing.contains($0.standardizedFileURL.path) }
        guard !unique.isEmpty else { return }
        isCalculating = true
        Task {
            var accepted: [ScanItem] = []
            var refused: [String] = []
            for url in unique {
                let standardized = url.standardizedFileURL
                if !FileSafety.isPathAllowed(standardized, scope: .permanentDelete) {
                    refused.append("\(PathDisplay.short(standardized.path)) — \(L("This location is protected"))")
                    continue
                }
                if FileSafety.isSymbolicLink(standardized) {
                    let info = FileSafety.lstatInfo(standardized)
                    var item = ScanItem.make(
                        url: standardized,
                        category: .largeFile,
                        size: info.size,
                        fingerprint: FileFingerprint(size: info.size, modified: info.modified, isDirectory: false),
                        location: PathDisplay.short(standardized.deletingLastPathComponent().path),
                        detail: L("Symbolic links are removed as links. Their targets are never followed."),
                        scope: .permanentDelete
                    )
                    item.name = standardized.lastPathComponent
                    accepted.append(item)
                    continue
                }
                guard let fingerprint = FileSafety.fingerprint(of: standardized) else {
                    refused.append("\(PathDisplay.short(standardized.path)) — \(L("Permission denied"))")
                    continue
                }
                var item = ScanItem.make(
                    url: standardized,
                    category: .largeFile,
                    size: fingerprint.size,
                    fingerprint: fingerprint,
                    location: PathDisplay.short(standardized.deletingLastPathComponent().path),
                    detail: fingerprint.isDirectory ? L("Folders are removed with their contents.") : nil,
                    scope: .permanentDelete
                )
                item.name = standardized.lastPathComponent
                accepted.append(item)
            }
            self.items.append(contentsOf: accepted)
            self.refusals = refused
            self.isCalculating = false
            if !refused.isEmpty { self.toast(L("This location is protected")) }
        }
    }

    func remove(_ item: ScanItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items = []
        refusals = []
    }

    func requestDelete() {
        guard !items.isEmpty else {
            toast(L("No files were chosen."))
            return
        }
        let typing = L10n.languageCode == "nl" ? "VERWIJDER" : "DELETE"
        confirmation = ConfirmationRequest(
            title: L("Permanently delete %d items?", items.count),
            message: L("These paths will be erased immediately. There is no Trash and no undo.") + "\n\n" + L("On SSDs, APFS snapshots, Time Machine backups and cloud copies can retain data even after a file is removed. Fettle cannot guarantee physical erasure."),
            actionLabel: L("Delete Permanently"),
            isPermanent: true,
            requiresTyping: typing,
            itemCount: items.count,
            byteCount: totalBytes,
            items: items,
            action: .permanentDelete
        )
    }

    func performConfirmed(_ request: ConfirmationRequest) {
        guard case .permanentDelete = request.action else { return }
        confirmation = nil
        let chosen = request.items
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                FileSafety.permanentlyDelete(chosen)
            }.value
            self.outcome = outcome
            let succeeded = Set(outcome.results.filter { $0.success }.map { $0.path })
            self.items.removeAll { succeeded.contains($0.path) }
            self.history.record(module: .permanentDelete, action: L("Permanent Delete"), outcome: outcome, movedToTrash: false)
            SoundPlayer.playSuccess(enabled: self.settings.soundEnabled, name: self.settings.soundName)
            if outcome.failureCount > 0 { self.toast(L("Some items could not be deleted")) }
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
