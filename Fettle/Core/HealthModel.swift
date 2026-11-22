import Foundation
import AppKit
import Combine

@MainActor
final class HealthModel: ObservableObject {
    let settings: AppSettings
    let activity: HealthHistoryStore
    private let cleanupHistory: HistoryStore
    private let sampler = HealthSampler()

    @Published var snapshot: HealthSnapshot?
    @Published var page: HealthPage = .overview
    @Published private(set) var isSampling = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var liveSamples: [HealthHistorySample] = []
    @Published private(set) var activeAlerts: [HealthAlert] = []
    @Published private(set) var unresponsiveProcesses: [ProcessReading] = []
    @Published private(set) var lastResponsivenessCheck: Date?
    @Published var message: String?
    @Published var processConfirmation: ProcessConfirmation?
    @Published var showFreeMemory = false
    @Published var showEjectConfirmation = false
    @Published private(set) var isEjecting = false
    @Published var accessibilityPrompt: AccessibilityPrompt?
    @Published var trashBytes: Int64?

    private var monitorTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var lastHistoryAppend: Date?
    private var cpuHighStreak = 0
    private var memoryHighStreak = 0
    private var lastNotified: [HealthAlertKind: Date] = [:]
    private var lastNotifiedKinds: Set<HealthAlertKind> = []

    init(settings: AppSettings, cleanupHistory: HistoryStore, activity: HealthHistoryStore) {
        self.settings = settings
        self.cleanupHistory = cleanupHistory
        self.activity = activity
        self.lastHistoryAppend = activity.samples.last?.date
    }

    // MARK: - Monitoring

    func applySettings() {
        if settings.healthMonitoring {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        isMonitoring = true
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            // A second reading a second later makes CPU and per-process rates
            // available before the first visible interval.
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled, self.settings.healthMonitoring { await self.refreshNow() }
            while !Task.isCancelled {
                let seconds = max(1, min(30, self.settings.sampleIntervalSeconds))
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled { break }
                if !self.settings.healthMonitoring { break }
                await self.refreshNow()
            }
            self.isMonitoring = false
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    func refreshNow(rescanDisks: Bool = false) async {
        guard !isSampling else { return }
        isSampling = true
        let started = Date()
        if rescanDisks { await sampler.invalidateDiskCache() }
        let raw = await sampler.sample()
        let enriched = enrich(raw)
        snapshot = enriched
        isSampling = false
        recordLive(enriched)
        recordActivityIfNeeded(enriched)
        evaluateAlerts(enriched)
        if Date().timeIntervalSince(started) > 20 {
            appendNote(L("A reading took longer than expected. Some system tools may be busy."))
        }
    }

    private func enrich(_ raw: HealthSnapshot) -> HealthSnapshot {
        var snap = raw
        let running = NSWorkspace.shared.runningApplications
        var byPID: [pid_t: NSRunningApplication] = [:]
        for app in running { byPID[app.processIdentifier] = app }

        var applications: [ProcessReading] = []
        for index in snap.processes.indices {
            let pid = snap.processes[index].pid
            guard let app = byPID[pid] else { continue }
            snap.processes[index].name = app.localizedName ?? snap.processes[index].name
            snap.processes[index].bundleID = app.bundleIdentifier
            snap.processes[index].isApplication = app.activationPolicy == .regular
            snap.processes[index].isFrontmost = app.isActive
            if !app.isFinishedLaunching, let started = snap.processes[index].startedAt, Date().timeIntervalSince(started) > 20 {
                snap.processes[index].stillLaunching = true
            }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                snap.processes[index].isOwnProcess = true
                snap.processes[index].canManage = false
            }
            if snap.processes[index].isApplication {
                applications.append(snap.processes[index])
            }
        }

        snap.topCPU = Array(snap.processes.filter { $0.cpuPercent > 0.1 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10))
        snap.topMemory = Array(snap.processes.filter { $0.memoryBytes > 0 }.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(10))
        snap.applications = applications.sorted { lhs, rhs in
            if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
            return lhs.memoryBytes > rhs.memoryBytes
        }
        return snap
    }

    private func recordLive(_ snapshot: HealthSnapshot) {
        let sample = Self.historySample(from: snapshot)
        liveSamples.append(sample)
        if liveSamples.count > 120 { liveSamples.removeFirst(liveSamples.count - 120) }
    }

    private func recordActivityIfNeeded(_ snapshot: HealthSnapshot) {
        guard settings.activityHistoryEnabled else { return }
        if let last = lastHistoryAppend, snapshot.readAt.timeIntervalSince(last) < 60 { return }
        activity.append(snapshot: snapshot)
        lastHistoryAppend = snapshot.readAt
    }

    private static func historySample(from snapshot: HealthSnapshot) -> HealthHistorySample {
        let root = snapshot.rootVolume
        return HealthHistorySample(
            date: snapshot.readAt,
            cpuPercent: snapshot.cpu.usagePercent,
            memoryUsedBytes: snapshot.memory.usedBytes,
            memoryTotalBytes: snapshot.memory.totalBytes,
            memoryPressure: snapshot.memory.pressure,
            diskFreeBytes: root?.availableBytes ?? 0,
            diskTotalBytes: root?.totalBytes ?? 0,
            networkInBytesPerSecond: snapshot.network.receiveRate,
            networkOutBytesPerSecond: snapshot.network.sendRate,
            batteryPercent: snapshot.battery.isPresent ? snapshot.battery.percent : nil,
            thermalState: snapshot.thermalState
        )
    }

    // MARK: - Alerts

    private func evaluateAlerts(_ snapshot: HealthSnapshot) {
        var alerts: [HealthAlert] = []
        let now = Date()

        if settings.memoryPressureAlert, snapshot.memory.pressure == .warning || snapshot.memory.pressure == .critical {
            memoryHighStreak += 1
            if memoryHighStreak >= 2 {
                alerts.append(HealthAlert(
                    kind: .memoryPressure,
                    severity: snapshot.memory.pressure == .critical ? .critical : .warning,
                    title: L("Memory pressure is %@", snapshot.memory.pressure.title.lowercased()),
                    detail: L("%@ of %@ is in use and %@ is swapped.", Fmt.bytes(Int64(snapshot.memory.usedBytes)), Fmt.bytes(Int64(snapshot.memory.totalBytes)), Fmt.bytes(Int64(snapshot.memory.swapUsedBytes))),
                    date: now
                ))
            }
        } else {
            memoryHighStreak = 0
        }

        if settings.highCPUAlert, snapshot.cpu.warmedUp, snapshot.cpu.usagePercent >= Double(settings.highCPUThreshold) {
            cpuHighStreak += 1
            if cpuHighStreak >= 3 {
                alerts.append(HealthAlert(
                    kind: .highCPU,
                    severity: snapshot.cpu.usagePercent >= 95 ? .critical : .warning,
                    title: L("CPU use is above %d%%", settings.highCPUThreshold),
                    detail: L("The processor has stayed at %@ for several readings. Open CPU to see the busiest processes.", HealthFormat.percent(snapshot.cpu.usageFraction)),
                    date: now
                ))
            }
        } else {
            cpuHighStreak = 0
        }

        if settings.diskSpaceAlert, let root = snapshot.rootVolume {
            let threshold = settings.diskSpaceThresholdGB == 0
                ? Rules.defaultDiskSpaceThreshold(freeSpace: root.availableBytes)
                : Int64(settings.diskSpaceThresholdGB) * 1_000_000_000
            if root.availableBytes < threshold {
                alerts.append(HealthAlert(
                    kind: .lowDisk,
                    severity: .warning,
                    title: L("Low disk space"),
                    detail: L("Only %@ is free on %@, below the %@ alert level.", Fmt.bytes(root.availableBytes), root.name, Fmt.bytes(threshold)),
                    date: now
                ))
            }
        }

        if settings.trashReminder, let trashBytes {
            let threshold = Int64(settings.trashThresholdMB) * 1_000_000
            if trashBytes > threshold, threshold > 0 {
                alerts.append(HealthAlert(
                    kind: .largeTrash,
                    severity: trashBytes > threshold * 2 ? .warning : .info,
                    title: L("The Trash is getting large"),
                    detail: L("The Trash holds %@, above the %@ reminder level. Emptying it stays a separate confirmed action.", Fmt.bytes(trashBytes), Fmt.bytes(threshold)),
                    date: now
                ))
            }
        }

        if settings.externalDriveAlert {
            for volume in snapshot.externalVolumes {
                alerts.append(HealthAlert(
                    kind: .externalDrive,
                    severity: .info,
                    title: L("External drive connected: %@", volume.name),
                    detail: L("Review its files before cleaning. Items on an external drive are never selected automatically."),
                    date: now
                ))
            }
        }

        if settings.driveHealthAlert {
            for drive in snapshot.drives where drive.severity >= .critical {
                alerts.append(HealthAlert(
                    kind: .driveHealth,
                    severity: .critical,
                    title: L("Drive health needs attention: %@", drive.model),
                    detail: L("macOS reports SMART status \"%@\". Back up important files and check the drive with Disk Utility.", drive.smartLabel),
                    date: now
                ))
            }
        }

        activeAlerts = alerts.sorted { $0.severity > $1.severity }
        notifyNewAlerts(alerts, at: now)
    }

    private func notifyNewAlerts(_ alerts: [HealthAlert], at now: Date) {
        let kinds = Set(alerts.map(\.kind))
        defer { lastNotifiedKinds = kinds }
        guard settings.notificationsEnabled else { return }
        for alert in alerts where !lastNotifiedKinds.contains(alert.kind) {
            if let last = lastNotified[alert.kind], now.timeIntervalSince(last) < 1_800 { continue }
            lastNotified[alert.kind] = now
            NotificationService.shared.notifyHealthAlert(
                identifier: "fettle.health.\(alert.kind.rawValue)",
                title: alert.title,
                body: alert.detail
            )
        }
    }

    func evaluateForTesting(_ snapshot: HealthSnapshot) {
        evaluateAlerts(snapshot)
    }

    var highestSeverity: HealthSeverity? {
        activeAlerts.map(\.severity).max() ?? (snapshot == nil ? nil : .good)
    }

    var statusHeadline: String {
        if let alert = activeAlerts.first { return alert.title }
        if snapshot == nil { return L("Reading this Mac…") }
        return L("Everything looks calm.")
    }

    // MARK: - Process actions

    func requestQuit(_ process: ProcessReading, force: Bool) {
        guard process.canManage, !process.isOwnProcess else { return }
        processConfirmation = ProcessConfirmation(process: process, force: force)
    }

    func performQuit(_ request: ProcessConfirmation) {
        processConfirmation = nil
        let outcome = ProcessActions.quit(request.process, force: request.force)
        let item = ItemResult(
            path: request.process.path ?? "pid \(request.process.pid)",
            name: request.process.displayName,
            category: nil,
            success: outcome.0,
            skipped: false,
            message: outcome.0 ? nil : outcome.1,
            bytes: 0
        )
        let operation = OperationOutcome(
            title: request.force ? L("Force Quit") : L("Quit Process"),
            message: outcome.1,
            results: [item],
            bytes: 0
        )
        cleanupHistory.record(module: .health, actionKey: request.force ? "Force Quit" : "Quit Process", outcome: operation, detail: request.process.displayName, movedToTrash: false)
        setMessage(outcome.1)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await waitUntilNotSampling()
            await refreshNow()
        }
    }

    var freeMemoryCandidates: [ProcessReading] {
        guard let snapshot else { return [] }
        return snapshot.applications
            .filter { $0.canManage && !$0.isOwnProcess && $0.memoryBytes > 0 }
            .filter { $0.bundleID != "com.apple.finder" && $0.bundleID != "com.apple.dock" }
            .sorted { $0.memoryBytes > $1.memoryBytes }
    }

    func performFreeMemory(pids: Set<pid_t>) {
        showFreeMemory = false
        guard !pids.isEmpty, let initialMemory = snapshot?.memory else { return }
        let before = initialMemory.usedBytes
        let targets = (snapshot?.processes ?? []).filter { pids.contains($0.pid) }
        var results: [ItemResult] = []
        for target in targets {
            let outcome = ProcessActions.quit(target, force: false)
            results.append(ItemResult(
                path: target.path ?? "pid \(target.pid)",
                name: target.displayName,
                category: nil,
                success: outcome.0,
                message: outcome.0 ? nil : outcome.1,
                bytes: 0
            ))
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await waitUntilNotSampling()
            await refreshNow()
            let after = snapshot?.memory.usedBytes ?? before
            let freed = before > after ? before - after : 0
            let operation = OperationOutcome(
                title: L("Quit Selected Apps"),
                message: L("Memory pressure: %@ → %@. ", initialMemory.pressure.title, (snapshot?.memory.pressure ?? .unknown).title) + (freed > 0
                    ? L("Memory in use fell from %@ to %@. %@ was released.", Fmt.bytes(Int64(before)), Fmt.bytes(Int64(after)), Fmt.bytes(Int64(freed)))
                    : L("Memory in use is %@. macOS may reclaim the memory gradually; no administrator password was requested.", Fmt.bytes(Int64(after)))),
                results: results,
                bytes: Int64(freed)
            )
            cleanupHistory.record(module: .health, actionKey: "Quit Selected Apps", outcome: operation, detail: L("%d apps quit", results.filter { $0.success }.count), movedToTrash: false)
            setMessage(operation.message)
        }
    }

    // MARK: - Responsiveness

    func checkResponsiveness() {
        guard ProcessActions.accessibilityGranted else {
            accessibilityPrompt = AccessibilityPrompt()
            return
        }
        guard let snapshot else { return }
        let apps = snapshot.applications.filter { !$0.isOwnProcess }
        Task {
            var unresponsive: [ProcessReading] = []
            for app in apps {
                if let responding = await Task.detached(priority: .userInitiated, operation: { ProcessActions.responsiveness(of: app.pid) }).value {
                    if !responding { unresponsive.append(app) }
                }
            }
            unresponsiveProcesses = unresponsive.sorted { $0.name < $1.name }
            lastResponsivenessCheck = Date()
            if unresponsive.isEmpty {
                setMessage(L("No app was confirmed unresponsive."))
            } else {
                setMessage(L("%d apps did not respond. You can review them below.", unresponsive.count))
            }
        }
    }

    func requestAccessibility() {
        accessibilityPrompt = nil
        ProcessActions.requestAccessibility()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if ProcessActions.accessibilityGranted {
                checkResponsiveness()
            } else {
                setMessage(L("Accessibility access is still off. You can enable Fettle in System Settings, then return here."))
            }
        }
    }

    func openAccessibilitySettings() {
        accessibilityPrompt = nil
        ProcessActions.openAccessibilitySettings()
    }

    // MARK: - Eject

    func requestEjectAll() {
        if snapshot?.ejectableVolumes.isEmpty == true {
            setMessage(L("No ejectable drives are connected."))
            return
        }
        showEjectConfirmation = true
    }

    func ejectAll() {
        showEjectConfirmation = false
        let targets = snapshot?.ejectableVolumes ?? []
        guard !targets.isEmpty else {
            setMessage(L("No ejectable drives are connected."))
            return
        }
        isEjecting = true
        Task {
            let results = await Task.detached(priority: .userInitiated) { () -> [EjectResult] in
                var collected: [EjectResult] = []
                for volume in targets {
                    let result = Shell.run("/usr/sbin/diskutil", ["eject", volume.mountPath], timeout: 20)
                    let message = result.succeeded
                        ? L("%@ was ejected.", volume.name)
                        : (result.combined.isEmpty ? L("The drive could not be ejected.") : result.combined)
                    collected.append(EjectResult(volume: volume.name, success: result.succeeded, message: message))
                }
                return collected
            }.value
            isEjecting = false
            let successful = results.filter(\.success).count
            let outcome = OperationOutcome(
                title: L("Eject All"),
                message: L("Ejected %d of %d drives.", successful, results.count),
                results: results.map { ItemResult(path: $0.volume, name: $0.volume, category: nil, success: $0.success, message: $0.success ? nil : $0.message, bytes: 0) },
                bytes: 0
            )
            cleanupHistory.record(module: .health, actionKey: "Eject All", outcome: outcome, detail: nil, movedToTrash: false)
            setMessage(outcome.message)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshNow(rescanDisks: true)
        }
    }

    // MARK: - History

    func clearActivity() {
        activity.clear()
        liveSamples = []
        setMessage(L("Activity history cleared. New readings will start a fresh history."))
    }

    func trend(_ metric: HealthTrendMetric, from samples: [HealthHistorySample]) -> [TrendPoint] {
        samples.map { sample in
            TrendPoint(date: sample.date, value: metric.value(sample))
        }
    }

    // MARK: - Messaging

    func setMessage(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self.message = nil }
        }
    }

    private func waitUntilNotSampling() async {
        var attempts = 0
        while isSampling && attempts < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
    }

    private func appendNote(_ text: String) {
        guard var snapshot else { return }
        if !snapshot.notes.contains(text) { snapshot.notes.append(text) }
        self.snapshot = snapshot
    }
}

enum HealthTrendMetric: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return L("CPU")
        case .memory: return L("Memory")
        case .disk: return L("Free space")
        case .network: return L("Network")
        case .battery: return L("Battery")
        }
    }
    var unit: String {
        switch self {
        case .cpu, .memory, .battery: return "%"
        case .disk: return L("GB")
        case .network: return L("MB/s")
        }
    }
    func value(_ sample: HealthHistorySample) -> Double {
        switch self {
        case .cpu: return sample.cpuPercent
        case .memory: return sample.memoryTotalBytes > 0 ? Double(sample.memoryUsedBytes) / Double(sample.memoryTotalBytes) * 100 : 0
        case .disk: return Double(sample.diskFreeBytes) / 1_000_000_000
        case .network: return (sample.networkInBytesPerSecond + sample.networkOutBytesPerSecond) / 1_000_000
        case .battery: return Double(sample.batteryPercent ?? 0)
        }
    }
}
