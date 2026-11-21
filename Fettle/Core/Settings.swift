import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, english, dutch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Follow System Language")
        case .english: return L("English")
        case .dutch: return L("Dutch")
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("System default")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Small, observable preferences store. Values are kept in UserDefaults and never
/// sent anywhere. The ignore list and history live in separate JSON files.
@MainActor
final class AppSettings: ObservableObject {
    private static let bundledFeedURL = (Bundle.main.object(forInfoDictionaryKey: "FettleFeedURL") as? String) ?? ""
    private static let bundledPublicKey = (Bundle.main.object(forInfoDictionaryKey: "FettleFeedPublicKey") as? String) ?? ""
    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Keys.language); L10n.apply(language: language); objectWillChange.send() } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published var cleanupReminders: Bool { didSet { defaults.set(cleanupReminders, forKey: Keys.cleanupReminders) } }
    @Published var trashReminder: Bool { didSet { defaults.set(trashReminder, forKey: Keys.trashReminder) } }
    @Published var trashThresholdMB: Int { didSet { defaults.set(trashThresholdMB, forKey: Keys.trashThresholdMB) } }
    @Published var reminderIntervalDays: Int { didSet { defaults.set(reminderIntervalDays, forKey: Keys.reminderInterval) } }
    @Published var diskSpaceAlert: Bool { didSet { defaults.set(diskSpaceAlert, forKey: Keys.diskSpaceAlert) } }
    /// 0 selects the automatic threshold: the
    /// option nearest to 10% of current free space.
    @Published var diskSpaceThresholdGB: Int { didSet { defaults.set(diskSpaceThresholdGB, forKey: Keys.diskSpaceThresholdGB) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) } }
    @Published var soundName: String { didSet { defaults.set(soundName, forKey: Keys.soundName) } }
    @Published var externalDrivePrompt: Bool { didSet { defaults.set(externalDrivePrompt, forKey: Keys.externalDrivePrompt) } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) } }
    @Published var feedURL: String { didSet { defaults.set(feedURL, forKey: Keys.feedURL) } }
    @Published var publicKey: String { didSet { defaults.set(publicKey, forKey: Keys.publicKey) } }
    @Published var largeFileThresholdMB: Int { didSet { defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThreshold) } }
    @Published var extraAppFolders: [String] { didSet { defaults.set(extraAppFolders, forKey: Keys.extraAppFolders) } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Keys.lastUpdateCheck) } }
    @Published var lastAppUpdateCheck: Date? { didSet { defaults.set(lastAppUpdateCheck, forKey: Keys.lastAppUpdateCheck) } }
    @Published var autoCheckAppUpdates: Bool { didSet { defaults.set(autoCheckAppUpdates, forKey: Keys.autoCheckAppUpdates) } }
    @Published var appUpdatesInGlobalScan: Bool { didSet { defaults.set(appUpdatesInGlobalScan, forKey: Keys.appUpdatesInGlobalScan) } }
    @Published var lastScan: Date? { didSet { defaults.set(lastScan, forKey: Keys.lastScan) } }

    // Mac health and menu bar
    @Published var healthMonitoring: Bool { didSet { defaults.set(healthMonitoring, forKey: Keys.healthMonitoring) } }
    @Published var sampleIntervalSeconds: Int { didSet { defaults.set(sampleIntervalSeconds, forKey: Keys.sampleIntervalSeconds) } }
    @Published var activityHistoryEnabled: Bool { didSet { defaults.set(activityHistoryEnabled, forKey: Keys.activityHistoryEnabled) } }
    @Published var menuBarEnabled: Bool { didSet { defaults.set(menuBarEnabled, forKey: Keys.menuBarEnabled) } }
    @Published var menuBarShowsCPU: Bool { didSet { defaults.set(menuBarShowsCPU, forKey: Keys.menuBarShowsCPU) } }
    @Published var backgroundMode: Bool { didSet { defaults.set(backgroundMode, forKey: Keys.backgroundMode) } }
    @Published var openAtLogin: Bool { didSet { defaults.set(openAtLogin, forKey: Keys.openAtLogin) } }
    @Published var memoryPressureAlert: Bool { didSet { defaults.set(memoryPressureAlert, forKey: Keys.memoryPressureAlert) } }
    @Published var highCPUAlert: Bool { didSet { defaults.set(highCPUAlert, forKey: Keys.highCPUAlert) } }
    @Published var highCPUThreshold: Int { didSet { defaults.set(highCPUThreshold, forKey: Keys.highCPUThreshold) } }
    @Published var driveHealthAlert: Bool { didSet { defaults.set(driveHealthAlert, forKey: Keys.driveHealthAlert) } }
    @Published var externalDriveAlert: Bool { didSet { defaults.set(externalDriveAlert, forKey: Keys.externalDriveAlert) } }

    private enum Keys {
        static let language = "fettle.language"
        static let appearance = "fettle.appearance"
        static let cleanupReminders = "fettle.cleanupReminders"
        static let trashReminder = "fettle.trashReminder"
        static let trashThresholdMB = "fettle.trashThresholdMB"
        static let reminderInterval = "fettle.reminderInterval"
        static let diskSpaceAlert = "fettle.diskSpaceAlert"
        static let diskSpaceThresholdGB = "fettle.diskSpaceThresholdGB"
        static let notificationsEnabled = "fettle.notificationsEnabled"
        static let soundEnabled = "fettle.soundEnabled"
        static let soundName = "fettle.soundName"
        static let externalDrivePrompt = "fettle.externalDrivePrompt"
        static let autoCheckUpdates = "fettle.autoCheckUpdates"
        static let feedURL = "fettle.feedURL"
        static let publicKey = "fettle.publicKey"
        static let largeFileThreshold = "fettle.largeFileThresholdMB"
        static let extraAppFolders = "fettle.extraAppFolders"
        static let lastUpdateCheck = "fettle.lastUpdateCheck"
        static let lastAppUpdateCheck = "fettle.lastAppUpdateCheck"
        static let autoCheckAppUpdates = "fettle.autoCheckAppUpdates"
        static let appUpdatesInGlobalScan = "fettle.appUpdatesInGlobalScan"
        static let lastScan = "fettle.lastScan"
        static let healthMonitoring = "fettle.healthMonitoring"
        static let sampleIntervalSeconds = "fettle.sampleIntervalSeconds"
        static let activityHistoryEnabled = "fettle.activityHistoryEnabled"
        static let menuBarEnabled = "fettle.menuBarEnabled"
        static let menuBarShowsCPU = "fettle.menuBarShowsCPU"
        static let backgroundMode = "fettle.backgroundMode"
        static let openAtLogin = "fettle.openAtLogin"
        static let memoryPressureAlert = "fettle.memoryPressureAlert"
        static let highCPUAlert = "fettle.highCPUAlert"
        static let highCPUThreshold = "fettle.highCPUThreshold"
        static let driveHealthAlert = "fettle.driveHealthAlert"
        static let externalDriveAlert = "fettle.externalDriveAlert"
    }

    func reset() {
        language = .system
        appearance = .system
        cleanupReminders = false
        trashReminder = false
        trashThresholdMB = Rules.defaultTrashThresholdMB
        reminderIntervalDays = Rules.Reminder.defaultDays
        diskSpaceAlert = false
        diskSpaceThresholdGB = 0
        notificationsEnabled = false
        soundEnabled = true
        soundName = "Glass"
        externalDrivePrompt = false
        autoCheckUpdates = false
        feedURL = Self.bundledFeedURL
        publicKey = Self.bundledPublicKey
        largeFileThresholdMB = 100
        extraAppFolders = []
        lastUpdateCheck = nil
        lastAppUpdateCheck = nil
        autoCheckAppUpdates = false
        appUpdatesInGlobalScan = false
        lastScan = nil
        healthMonitoring = true
        sampleIntervalSeconds = 3
        activityHistoryEnabled = true
        menuBarEnabled = true
        menuBarShowsCPU = true
        backgroundMode = false
        openAtLogin = false
        memoryPressureAlert = true
        highCPUAlert = true
        highCPUThreshold = 85
        driveHealthAlert = true
        externalDriveAlert = false
    }

    init() {
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        cleanupReminders = defaults.object(forKey: Keys.cleanupReminders) as? Bool ?? false
        trashReminder = defaults.object(forKey: Keys.trashReminder) as? Bool ?? false
        trashThresholdMB = defaults.object(forKey: Keys.trashThresholdMB) as? Int ?? Rules.defaultTrashThresholdMB
        reminderIntervalDays = defaults.object(forKey: Keys.reminderInterval) as? Int ?? Rules.Reminder.defaultDays
        diskSpaceAlert = defaults.object(forKey: Keys.diskSpaceAlert) as? Bool ?? false
        diskSpaceThresholdGB = defaults.object(forKey: Keys.diskSpaceThresholdGB) as? Int ?? 0
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        soundName = defaults.string(forKey: Keys.soundName) ?? "Glass"
        externalDrivePrompt = defaults.object(forKey: Keys.externalDrivePrompt) as? Bool ?? false
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? false
        feedURL = defaults.string(forKey: Keys.feedURL) ?? Self.bundledFeedURL
        publicKey = defaults.string(forKey: Keys.publicKey) ?? Self.bundledPublicKey
        largeFileThresholdMB = defaults.object(forKey: Keys.largeFileThreshold) as? Int ?? 100
        extraAppFolders = defaults.stringArray(forKey: Keys.extraAppFolders) ?? []
        lastUpdateCheck = defaults.object(forKey: Keys.lastUpdateCheck) as? Date
        lastAppUpdateCheck = defaults.object(forKey: Keys.lastAppUpdateCheck) as? Date
        autoCheckAppUpdates = defaults.object(forKey: Keys.autoCheckAppUpdates) as? Bool ?? false
        appUpdatesInGlobalScan = defaults.object(forKey: Keys.appUpdatesInGlobalScan) as? Bool ?? false
        lastScan = defaults.object(forKey: Keys.lastScan) as? Date
        healthMonitoring = defaults.object(forKey: Keys.healthMonitoring) as? Bool ?? true
        sampleIntervalSeconds = defaults.object(forKey: Keys.sampleIntervalSeconds) as? Int ?? 3
        activityHistoryEnabled = defaults.object(forKey: Keys.activityHistoryEnabled) as? Bool ?? true
        menuBarEnabled = defaults.object(forKey: Keys.menuBarEnabled) as? Bool ?? true
        menuBarShowsCPU = defaults.object(forKey: Keys.menuBarShowsCPU) as? Bool ?? true
        backgroundMode = defaults.object(forKey: Keys.backgroundMode) as? Bool ?? false
        openAtLogin = defaults.object(forKey: Keys.openAtLogin) as? Bool ?? false
        memoryPressureAlert = defaults.object(forKey: Keys.memoryPressureAlert) as? Bool ?? true
        highCPUAlert = defaults.object(forKey: Keys.highCPUAlert) as? Bool ?? true
        highCPUThreshold = defaults.object(forKey: Keys.highCPUThreshold) as? Int ?? 85
        driveHealthAlert = defaults.object(forKey: Keys.driveHealthAlert) as? Bool ?? true
        externalDriveAlert = defaults.object(forKey: Keys.externalDriveAlert) as? Bool ?? false
        // Migrate values stored by earlier Fettle builds so the pickers
        // always have a matching tag.
        if !Rules.trashAlertThresholdBytes.contains(Int64(trashThresholdMB) * 1_000_000) {
            trashThresholdMB = Rules.defaultTrashThresholdMB
        }
        if !Rules.Reminder.optionDays.contains(reminderIntervalDays) {
            reminderIntervalDays = Rules.Reminder.defaultDays
        }
        if let forced = ProcessInfo.processInfo.environment["FETTLE_LANG"], let forcedLanguage = AppLanguage(rawValue: forced) {
            language = forcedLanguage
        }
        if let forced = ProcessInfo.processInfo.environment["FETTLE_APPEARANCE"], let forcedAppearance = AppearanceMode(rawValue: forced) {
            appearance = forcedAppearance
        }
        L10n.apply(language: language)
    }
}

@MainActor
final class IgnoreListStore: ObservableObject {
    @Published private(set) var paths: [String] = []
    private let fileURL: URL

    init(fileURL: URL = AppPaths.ignoreListFile) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            paths = []
            return
        }
        paths = decoded
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { ignored in
            let entry = (ignored as NSString).expandingTildeInPath
            return path == entry || path.hasPrefix(entry + "/")
        }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        paths.sort()
        save()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        save()
    }

    func clear() {
        paths.removeAll()
        save()
    }

    private func save() {
        try? AppPaths.ensureSupportDirectory()
        if let data = try? JSONEncoder().encode(paths) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var events: [HistoryEvent] = []
    private let fileURL: URL
    private let limit = 200

    init(fileURL: URL = AppPaths.historyFile) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEvent].self, from: data) else {
            events = []
            return
        }
        events = decoded.sorted { $0.date > $1.date }
    }

    func record(_ event: HistoryEvent) {
        events.insert(event, at: 0)
        if events.count > limit { events = Array(events.prefix(limit)) }
        save()
    }

    func record(module: ModuleID, action: String, outcome: OperationOutcome, detail: String? = nil, movedToTrash: Bool = true) {
        let state: String
        if outcome.cancelled {
            state = L("Cancelled")
        } else if outcome.failureCount > 0 && outcome.successCount == 0 {
            state = L("Failed")
        } else if outcome.failureCount > 0 {
            state = L("Some items could not be removed")
        } else {
            state = L("Completed")
        }
        record(HistoryEvent(
            date: outcome.finishedAt,
            module: module,
            action: action,
            itemCount: outcome.successCount,
            bytes: outcome.touchedBytes,
            outcome: state,
            detail: detail,
            movedToTrash: movedToTrash
        ))
    }

    func clear() {
        events = []
        save()
    }

    private func save() {
        try? AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum AppPaths {
    /// Tests run with FETTLE_HOME pointing at a disposable fixture. The app
    /// itself always uses the real home directory.
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["FETTLE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/Fettle", isDirectory: true)
    }

    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    static var ignoreListFile: URL { appSupport.appendingPathComponent("ignore-list.json") }
    static var historyFile: URL { appSupport.appendingPathComponent("history.json") }
    static var healthHistoryFile: URL { appSupport.appendingPathComponent("health-history.json") }
    static var exportsDirectory: URL { appSupport.appendingPathComponent("Exports", isDirectory: true) }

    static var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    static var caches: URL { library.appendingPathComponent("Caches", isDirectory: true) }
    static var logs: URL { library.appendingPathComponent("Logs", isDirectory: true) }
    static var diagnosticReports: URL { logs.appendingPathComponent("DiagnosticReports", isDirectory: true) }
    static var crashReporter: URL { library.appendingPathComponent("Application Support/CrashReporter", isDirectory: true) }
    static var temporaryItems: URL { caches.appendingPathComponent("TemporaryItems", isDirectory: true) }
    static var trash: URL {
        if let override = ProcessInfo.processInfo.environment["FETTLE_TRASH_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".Trash", isDirectory: true)
    }
    static var launchAgents: URL { library.appendingPathComponent("LaunchAgents", isDirectory: true) }
    static var preferences: URL { library.appendingPathComponent("Preferences", isDirectory: true) }
    static var applicationSupport: URL { library.appendingPathComponent("Application Support", isDirectory: true) }
    static var savedState: URL { library.appendingPathComponent("Saved Application State", isDirectory: true) }
    static var containers: URL { library.appendingPathComponent("Containers", isDirectory: true) }
    static var groupContainers: URL { library.appendingPathComponent("Group Containers", isDirectory: true) }
    static var webKit: URL { library.appendingPathComponent("WebKit", isDirectory: true) }
    static var httpStorages: URL { library.appendingPathComponent("HTTPStorages", isDirectory: true) }
    static var cookies: URL { library.appendingPathComponent("Cookies", isDirectory: true) }
    static var applications: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    static var safari: URL { library.appendingPathComponent("Safari", isDirectory: true) }
    static var safariCaches: URL { caches.appendingPathComponent("com.apple.Safari", isDirectory: true) }
    static var sharedFileLists: URL { applicationSupport.appendingPathComponent("com.apple.sharedfilelist", isDirectory: true) }

    static var tmpDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["FETTLE_TMP_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let path = NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}

enum PathDisplay {
    static func short(_ path: String) -> String {
        let home = AppPaths.home.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func abbreviated(_ url: URL) -> String { short(url.path) }
}

enum Fmt {
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        if value <= 0 { return "0 KB" }
        let units: [(String, Double)] = [("TB", 1_000_000_000_000), ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000)]
        var chosen = units.last!
        for unit in units {
            if Double(value) >= unit.1 { chosen = unit; break }
        }
        let amount = Double(value) / chosen.1
        let number: String
        if amount >= 100 { number = String(format: "%.0f", amount) }
        else if amount >= 10 { number = String(format: "%.1f", amount) }
        else { number = String(format: "%.2f", amount) }
        let localized = L10n.languageCode == "nl" ? number.replacingOccurrences(of: ".", with: ",") : number
        return "\(localized) \(chosen.0)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ interval: TimeInterval) -> String {
        if interval < 1 { return String(format: "%.0f ms", interval * 1000) }
        if interval < 60 { return String(format: "%.1f s", interval) }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }

    /// Joins names in the interface language: "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " " + L("and") + " " + last
    }

    static func associatedFiles(_ count: Int) -> String {
        count == 1 ? L("1 associated file") : L("%d associated files", count)
    }

    static func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return L("Just now") }
        if seconds < 120 { return L("1 minute ago") }
        if seconds < 3_600 { return L("%d minutes ago", Int(seconds / 60)) }
        if seconds < 7_200 { return L("1 hour ago") }
        if seconds < 86_400 { return L("%d hours ago", Int(seconds / 3_600)) }
        if seconds < 172_800 { return L("Yesterday") }
        if seconds < 604_800 { return L("%d days ago", max(2, Int(seconds / 86_400))) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode == "nl" ? "nl_NL" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode == "nl" ? "nl_NL" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
    }
}

enum SoundPlayer {
    static func playSuccess(enabled: Bool, name: String) {
        guard enabled else { return }
        let sound = NSSound(named: NSSound.Name(name)) ?? NSSound(named: "Glass")
        sound?.play()
    }
}
