import Foundation
import SwiftUI

// MARK: - Cancellation and progress

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func reset() { lock.lock(); value = false; lock.unlock() }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Base scan module

@MainActor
class BaseScanModel: ObservableObject {
    typealias ScanClosure = @Sendable ([String], @escaping @Sendable (ScanProgress) -> Void, @escaping @Sendable () -> Bool) -> ScanReport

    let module: ModuleID
    let settings: AppSettings
    let ignoreList: IgnoreListStore
    let history: HistoryStore

    @Published var report: ScanReport?
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var selectedIDs: Set<String> = []
    @Published var confirmation: ConfirmationRequest?
    @Published var outcome: OperationOutcome?
    @Published var toast: String?
    @Published var showSkipped = false
    @Published var errorMessage: String?

    var extraRoots: [URL] = []
    var defaultActionScope: ActionScope = .none
    var actionTitleKey = "Move to Trash"
    var scanTask: Task<Void, Never>?
    private(set) var cancelFlag = CancelFlag()
    private var toastTask: Task<Void, Never>?

    init(module: ModuleID, settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        self.module = module
        self.settings = settings
        self.ignoreList = ignoreList
        self.history = history
    }

    func makeScanClosure() -> ScanClosure {
        { _, _, _ in ScanReport.empty() }
    }

    var items: [ScanItem] { report?.items ?? [] }
    var skipped: [SkippedItem] { report?.skipped ?? [] }

    var estimatedBytes: Int64 {
        items.filter { $0.category != .trash && !$0.isInformational && !$0.isProtected }
            .reduce(0) { $0 + $1.size }
    }

    var trashItems: [ScanItem] { items.filter { $0.category == .trash } }
    var trashBytes: Int64 { trashItems.reduce(0) { $0 + $1.size } }

    func isSelectable(_ item: ScanItem) -> Bool {
        !item.isInformational && !item.isProtected && (item.category != .trash || item.isExternal)
    }

    func selectedItems() -> [ScanItem] {
        items.filter { selectedIDs.contains($0.id) && isSelectable($0) }
    }

    func filteredItems(query: String) -> [ScanItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.name.localizedCaseInsensitiveContains(trimmed)
                || item.path.localizedCaseInsensitiveContains(trimmed)
                || item.category.title.localizedCaseInsensitiveContains(trimmed)
                || item.location.localizedCaseInsensitiveContains(trimmed)
                || (item.detail ?? "").localizedCaseInsensitiveContains(trimmed)
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
        errorMessage = nil
        let closure = makeScanClosure()
        let ignore = ignoreList.paths
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> ScanReport in
            closure(ignore, { update in
                Task { @MainActor in
                    guard !flag.isCancelled else { return }
                    self.progress = max(0.01, min(0.99, update.fraction))
                    self.phase = update.message
                }
            }, { flag.isCancelled })
        }.value
        // A newer run replaced this one; it owns the state now.
        guard flag === cancelFlag else { return }
        guard !flag.isCancelled else {
            isScanning = false
            phase = L("Scan cancelled")
            progress = 0
            toast(L("Scan cancelled"))
            return
        }
        var final = result
        if final.duration == 0 { final.duration = Date().timeIntervalSince(started) }
        report = final
        settings.lastScan = final.scannedAt
        selectedIDs = []
        isScanning = false
        progress = 1
        phase = L("Scan complete")
        didFinishScan(final)
    }

    func didFinishScan(_ report: ScanReport) {}

    func cancel() {
        guard isScanning else { return }
        cancelFlag.cancel()
        scanTask?.cancel()
        isScanning = false
        phase = L("Scan cancelled")
        progress = 0
        toast(L("Scan cancelled"))
    }

    func toggle(_ item: ScanItem) {
        guard isSelectable(item) else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func selectAll(query: String) {
        let ids = filteredItems(query: query).filter { isSelectable($0) }.map { $0.id }
        selectedIDs = Set(ids)
    }

    func deselectAll() {
        selectedIDs = []
    }

    func requestRemoveSelected(title: String? = nil, message: String? = nil, label: String? = nil) {
        let chosen = selectedItems()
        guard !chosen.isEmpty else {
            toast(L("Select at least one item first."))
            return
        }
        presentTrashConfirmation(items: chosen, title: title, message: message, label: label)
    }

    func presentTrashConfirmation(items chosen: [ScanItem], title: String? = nil, message: String? = nil, label: String? = nil) {
        let bytes = chosen.reduce(0) { $0 + $1.size }
        confirmation = ConfirmationRequest(
            title: title ?? L("Move %d items to the Trash?", chosen.count),
            message: message ?? L("These items will be moved to the Trash. You can restore them from the Trash until you empty it."),
            actionLabel: label ?? L("Move to Trash"),
            isPermanent: false,
            itemCount: chosen.count,
            byteCount: bytes,
            items: chosen,
            action: .moveSelectedToTrash
        )
    }

    func performConfirmed(_ request: ConfirmationRequest) {
        confirmation = nil
        guard case .moveSelectedToTrash = request.action else { return }
        isWorking = true
        let scope = defaultActionScope
        let roots = extraRoots
        let ignore = ignoreList.paths
        let items = request.items
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                FileSafety.moveToTrash(items, scope: scope, extraRoots: roots, ignoreList: ignore)
            }.value
            self.isWorking = false
            self.apply(outcome, action: request.actionLabel)
        }
    }

    func apply(_ outcome: OperationOutcome, action: String, movedToTrash: Bool = true) {
        self.outcome = outcome
        let succeededPaths = Set(outcome.results.filter { $0.success }.map { $0.path })
        let remainingFailed = items.filter { item in
            selectedIDs.contains(item.id) && !succeededPaths.contains(item.path)
                && outcome.results.contains(where: { $0.path == item.path })
        }.map { $0.id }
        if var current = report {
            current.items.removeAll { succeededPaths.contains($0.path) }
            report = current
        }
        selectedIDs = Set(remainingFailed)
        history.record(module: module, action: action, outcome: outcome, movedToTrash: movedToTrash)
        SoundPlayer.playSuccess(enabled: settings.soundEnabled, name: settings.soundName)
        if outcome.successCount == 0 && outcome.failureCount > 0 {
            toast(L("Some items could not be removed"))
        }
    }

    func toast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    var lastScan: Date? { report?.scannedAt }
    var hasResults: Bool { report != nil }
}

// MARK: - Disk cleanup

final class DiskCleanupModel: BaseScanModel {
    enum Mode: String { case cleanup, largeFiles, external }

    @Published var mode: Mode = .cleanup
    @Published var externalVolume: VolumeInfo?
    @Published var largeFileRoot: URL?
    @Published var minimumSizeMB: Int64 = 100
    @Published var driveChoices: [VolumeInfo] = []

    override init(module: ModuleID = .disk, settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        super.init(module: module, settings: settings, ignoreList: ignoreList, history: history)
        defaultActionScope = .diskCleanup
        actionTitleKey = "Remove selected"
        minimumSizeMB = Int64(settings.largeFileThresholdMB)
        driveChoices = FileSafety.volumes().filter { $0.isExternal || $0.isRemovable }
    }

    override func makeScanClosure() -> ScanClosure {
        let mode = self.mode
        let volume = externalVolume?.url
        let root = largeFileRoot
        let threshold = max(1, minimumSizeMB) * 1_000_000
        return { ignore, progress, cancelled in
            switch mode {
            case .cleanup:
                return DiskCleanupScanner.scan(options: DiskCleanupScanner.Options(), ignoreList: ignore, progress: progress, cancelled: cancelled)
            case .external:
                guard let volume else { return ScanReport.empty() }
                return DiskCleanupScanner.scan(options: DiskCleanupScanner.Options(includeTrash: true, externalVolume: volume), ignoreList: ignore, progress: progress, cancelled: cancelled)
            case .largeFiles:
                guard let root else { return ScanReport.empty() }
                return DiskCleanupScanner.scanLargeFiles(root: root, minimumSize: threshold, ignoreList: ignore, progress: progress, cancelled: cancelled)
            }
        }
    }

    override func runScan() async {
        if mode == .external, let volume = externalVolume {
            extraRoots = [volume.url]
        } else if mode == .largeFiles, let root = largeFileRoot {
            extraRoots = [root]
        } else {
            extraRoots = []
        }
        await super.runScan()
    }

    func startExternalScan(_ volume: VolumeInfo) {
        mode = .external
        externalVolume = volume
        startScan()
    }

    func startLargeFileScan(root: URL, minimumMB: Int64) {
        mode = .largeFiles
        largeFileRoot = root
        minimumSizeMB = minimumMB
        extraRoots = [root]
        startScan()
    }

    func switchToCleanup() {
        mode = .cleanup
        externalVolume = nil
        largeFileRoot = nil
        extraRoots = []
        startScan()
    }

    func refreshDrives() {
        driveChoices = FileSafety.volumes().filter { $0.isExternal || $0.isRemovable }
    }

    override func requestRemoveSelected(title: String? = nil, message: String? = nil, label: String? = nil) {
        if mode == .external {
            let chosen = selectedItems()
            guard !chosen.isEmpty else {
                toast(L("Select at least one item first."))
                return
            }
            confirmation = ConfirmationRequest(
                title: L("Permanently erase %d items (%@)?", chosen.count, Fmt.bytes(chosen.reduce(0) { $0 + $1.size })),
                message: L("These paths will be erased immediately. There is no Trash and no undo."),
                actionLabel: L("Delete Permanently"),
                isPermanent: true,
                itemCount: chosen.count,
                byteCount: chosen.reduce(0) { $0 + $1.size },
                items: chosen,
                action: .deleteExternalTrash
            )
            return
        }
        super.requestRemoveSelected(title: title, message: message, label: label)
    }

    override func performConfirmed(_ request: ConfirmationRequest) {
        if case .deleteExternalTrash = request.action {
            confirmation = nil
            isWorking = true
            let items = request.items
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    FileSafety.permanentlyDelete(items)
                }.value
                self.isWorking = false
                self.apply(outcome, action: L("Permanent Delete"), movedToTrash: false)
            }
            return
        }
        if case .emptyTrash = request.action {
            confirmation = nil
            isWorking = true
            let ignore = ignoreList.paths
            let reviewed = request.items
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    FileSafety.emptyTrash(reviewed, ignoreList: ignore)
                }.value
                self.isWorking = false
                self.apply(outcome, action: L("Empty Trash"), movedToTrash: false)
            }
            return
        }
        super.performConfirmed(request)
    }

    func requestEmptyTrash() {
        let trash = trashItems.filter { !$0.isExternal }
        guard !trash.isEmpty else {
            toast(L("The Trash is already empty."))
            return
        }
        confirmation = ConfirmationRequest(
            title: L("Empty %d Trash items permanently?", trash.count),
            message: L("This permanently erases the contents of your Trash. It cannot be undone."),
            actionLabel: L("Empty Trash"),
            isPermanent: true,
            itemCount: trash.count,
            byteCount: trash.reduce(0) { $0 + $1.size },
            items: trash,
            action: .emptyTrash
        )
    }

    var removableEstimate: Int64 {
        items.filter { $0.category != .trash && !$0.isInformational && !$0.isProtected }.reduce(0) { $0 + $1.size }
    }
}

// MARK: - Maintenance

final class MaintenanceModel: BaseScanModel {
    override init(module: ModuleID = .maintenance, settings: AppSettings, ignoreList: IgnoreListStore, history: HistoryStore) {
        super.init(module: module, settings: settings, ignoreList: ignoreList, history: history)
        defaultActionScope = .maintenance
    }

    override func makeScanClosure() -> ScanClosure {
        let apps = settings.extraAppFolders
        return { ignore, progress, cancelled in
            MaintenanceScanner.scan(
                options: MaintenanceScanner.Options(extraAppRoots: apps.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }),
                ignoreList: ignore,
                progress: progress,
                cancelled: cancelled
            )
        }
    }

    func repairSelected() {
        let chosen = selectedItems()
        guard !chosen.isEmpty else {
            toast(L("Nothing selected. Tick the findings you want to repair."))
            return
        }
        presentTrashConfirmation(
            items: chosen,
            title: L("Repair %d findings?", chosen.count),
            message: L("Repaired items are moved to the Trash, so you can put them back. System and live app data are never included."),
            label: L("Repair selected…")
        )
    }

    var brokenAliases: [ScanItem] { items.filter { $0.category == .brokenAlias } }
    var invalidAgents: [ScanItem] { items.filter { $0.category == .invalidLaunchAgent && !$0.isInformational } }
    var leftovers: [ScanItem] { items.filter { $0.category == .leftover && !$0.isInformational } }
    var uncertain: [ScanItem] { items.filter { $0.isInformational } }
}

final class ScanProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ScanProgress) -> Void)?

    init(_ handler: @escaping @Sendable (ScanProgress) -> Void) {
        self.handler = handler
    }

    func send(_ progress: ScanProgress) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(progress)
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
}
