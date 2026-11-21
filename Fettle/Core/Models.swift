import Foundation

// MARK: - Modules

enum ModuleID: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview, health, disk, maintenance, uninstaller, updater, extensions, power, loginItems, privacy, permanentDelete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("Overview")
        case .health: return L("Mac Health")
        case .disk: return L("Disk Cleanup")
        case .maintenance: return L("Maintenance")
        case .uninstaller: return L("Uninstaller")
        case .updater: return L("App Updater")
        case .power: return L("Sleep & Power")
        case .extensions: return L("Extensions")
        case .loginItems: return L("Login Items")
        case .privacy: return L("Privacy")
        case .permanentDelete: return L("Permanent Delete")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return L("Your Mac at a glance")
        case .health: return L("Live CPU, memory, disk, battery and network readings")
        case .disk: return L("Caches, logs, crash reports, temporary files and Trash")
        case .maintenance: return L("Aliases, startup definitions and confirmed leftovers")
        case .uninstaller: return L("Apps and the files they leave behind")
        case .updater: return L("Available app updates and the Review step")
        case .power: return L("Sleep, battery and power settings, read-only")
        case .extensions: return L("System extensions and browser add-ons")
        case .loginItems: return L("Login items and background agents")
        case .privacy: return L("Browser data and recent items")
        case .permanentDelete: return L("Erase chosen files without the Trash")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "circle.grid.2x2.fill"
        case .health: return "waveform.path.ecg"
        case .disk: return "internaldrive.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .uninstaller: return "trash.square.fill"
        case .updater: return "arrow.triangle.2.circlepath"
        case .power: return "bolt.batteryblock.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .loginItems: return "person.badge.key.fill"
        case .privacy: return "hand.raised.fill"
        case .permanentDelete: return "xmark.bin.fill"
        }
    }

    var section: SidebarSection {
        switch self {
        case .overview: return .home
        case .health: return .monitor
        case .disk, .maintenance: return .care
        case .uninstaller, .updater, .extensions: return .apps
        case .power, .loginItems, .privacy: return .control
        case .permanentDelete: return .tools
        }
    }

    var shortcutNumber: Int? {
        switch self {
        case .overview: return 1
        case .health: return 0
        case .disk: return 2
        case .maintenance: return 3
        case .uninstaller: return 4
        case .updater: return nil
        case .power: return 5
        case .extensions: return 6
        case .loginItems: return 7
        case .privacy: return 8
        case .permanentDelete: return 9
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case home, monitor, care, apps, control, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return L("Start")
        case .monitor: return L("Monitor")
        case .care: return L("Care")
        case .apps: return L("Applications")
        case .control: return L("Control")
        case .tools: return L("Tools")
        }
    }
}

// MARK: - Categories

enum ItemCategory: String, Codable, CaseIterable, Sendable {
    case cache
    case logs
    case crashReports
    case temporary
    case trash
    case largeFile

    case brokenAlias
    case invalidLaunchAgent
    case brokenPreference
    case leftover

    case app
    case appCache
    case appLogs
    case appPreferences
    case appSupport
    case appData
    case appLaunchAgent
    case sharedContainer

    case browserCache
    case cookies
    case browsingHistory
    case downloadHistory
    case websiteData
    case recentItems

    case systemExtension
    case browserExtension
    case loginItem

    var title: String {
        switch self {
        case .cache: return L("User caches")
        case .logs: return L("Logs")
        case .crashReports: return L("Crash reports")
        case .temporary: return L("Temporary files")
        case .trash: return L("Trash")
        case .largeFile: return L("Large files")
        case .brokenAlias: return L("Broken aliases")
        case .invalidLaunchAgent: return L("Invalid startup agents")
        case .brokenPreference: return L("Broken preferences")
        case .leftover: return L("Confirmed leftovers")
        case .app: return L("Applications")
        case .appCache: return L("App caches")
        case .appLogs: return L("App logs")
        case .appPreferences: return L("Preferences")
        case .appSupport: return L("Application Support")
        case .appData: return L("App data")
        case .appLaunchAgent: return L("Startup agents")
        case .sharedContainer: return L("Shared containers")
        case .browserCache: return L("Browser caches")
        case .cookies: return L("Cookies & site data")
        case .browsingHistory: return L("Browsing history")
        case .downloadHistory: return L("Download history")
        case .websiteData: return L("Website data")
        case .recentItems: return L("Recent items")
        case .systemExtension: return L("System extensions")
        case .browserExtension: return L("Browser add-ons")
        case .loginItem: return L("Login items")
        }
    }

    var symbol: String {
        switch self {
        case .cache, .appCache, .browserCache: return "shippingbox.fill"
        case .logs, .appLogs: return "doc.text.fill"
        case .crashReports: return "exclamationmark.triangle.fill"
        case .temporary: return "clock.badge.xmark.fill"
        case .trash: return "trash.fill"
        case .largeFile: return "doc.zipper"
        case .brokenAlias: return "link.badge.plus"
        case .invalidLaunchAgent: return "bolt.slash.fill"
        case .brokenPreference: return "doc.badge.gearshape"
        case .leftover: return "questionmark.folder.fill"
        case .app: return "app.fill"
        case .appPreferences: return "slider.horizontal.3"
        case .appSupport: return "folder.fill"
        case .appData: return "externaldrive.fill.badge.person.crop"
        case .appLaunchAgent: return "person.badge.key.fill"
        case .sharedContainer: return "person.2.fill"
        case .cookies: return "circle.grid.cross.fill"
        case .browsingHistory: return "clock.arrow.circlepath"
        case .downloadHistory: return "arrow.down.circle.fill"
        case .websiteData: return "globe"
        case .recentItems: return "clock.fill"
        case .systemExtension: return "puzzlepiece.fill"
        case .browserExtension: return "puzzlepiece.extension.fill"
        case .loginItem: return "person.fill"
        }
    }

    var isBrowserData: Bool {
        [.browserCache, .cookies, .browsingHistory, .downloadHistory, .websiteData].contains(self)
    }
}

// MARK: - Scan items

struct FileFingerprint: Codable, Hashable, Sendable {
    var size: Int64
    var modified: Date?
    var isDirectory: Bool
    var childCount: Int? = nil
}

struct ScanItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var url: URL
    var name: String
    var category: ItemCategory
    var size: Int64
    var fingerprint: FileFingerprint
    var location: String
    var detail: String?
    var evidence: [String] = []
    var bundleID: String?
    var appName: String?
    var isInformational: Bool = false
    var isProtected: Bool = false
    var isAppData: Bool = false
    var isRunningApp: Bool = false
    var isExternal: Bool = false
    var canReveal: Bool = true
    var scope: ActionScope = .none

    var path: String { url.path }
    var displayPath: String { PathDisplay.short(url.path) }

    static func make(
        url: URL,
        category: ItemCategory,
        size: Int64,
        fingerprint: FileFingerprint,
        location: String,
        detail: String? = nil,
        evidence: [String] = [],
        bundleID: String? = nil,
        appName: String? = nil,
        informational: Bool = false,
        isProtected: Bool = false,
        isAppData: Bool = false,
        scope: ActionScope = .none
    ) -> ScanItem {
        ScanItem(
            id: "\(category.rawValue)|\(url.path)",
            url: url,
            name: url.lastPathComponent,
            category: category,
            size: size,
            fingerprint: fingerprint,
            location: location,
            detail: detail,
            evidence: evidence,
            bundleID: bundleID,
            appName: appName,
            isInformational: informational,
            isProtected: isProtected,
            isAppData: isAppData,
            scope: scope
        )
    }
}

enum ActionScope: String, Codable, Sendable {
    case none
    case diskCleanup
    case trash
    case maintenance
    case uninstaller
    case privacy
    case permanentDelete
}

struct SkippedItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(path)|\(reason)" }
    var path: String
    var reason: String
    var category: ItemCategory?
}

struct ScanReport: Codable, Sendable {
    var scannedAt: Date
    var items: [ScanItem]
    var skipped: [SkippedItem]
    var notes: [String] = []
    var duration: TimeInterval = 0

    var estimatedBytes: Int64 { items.filter { !$0.isInformational && !$0.isProtected }.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func items(in category: ItemCategory) -> [ScanItem] {
        items.filter { $0.category == category }
    }

    static func empty() -> ScanReport {
        ScanReport(scannedAt: .now, items: [], skipped: [], notes: [])
    }
}

// MARK: - Confirmation and outcomes

enum PendingDestructiveAction: Equatable, Sendable {
    case moveSelectedToTrash
    case emptyTrash
    case removeApps
    case repairFindings
    case clearBrowserData
    case permanentDelete
    case deleteExternalTrash
    case toggleLoginItem(id: String, enable: Bool)
    case custom(title: String, message: String, label: String, isPermanent: Bool)
}

struct ConfirmationRequest: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var actionLabel: String
    var isPermanent: Bool
    var requiresTyping: String?
    var itemCount: Int
    var byteCount: Int64
    var items: [ScanItem]
    var action: PendingDestructiveAction
}

struct ItemResult: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var path: String
    var name: String
    var category: ItemCategory?
    var success: Bool
    var skipped: Bool = false
    var message: String?
    var bytes: Int64 = 0
}

struct OperationOutcome: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var message: String
    var results: [ItemResult]
    var bytes: Int64
    var cancelled: Bool = false
    var startedAt: Date = .now
    var finishedAt: Date = .now
    var freeSpaceBefore: Int64?
    var freeSpaceAfter: Int64?

    var successCount: Int { results.filter { $0.success }.count }
    var skippedCount: Int { results.filter { $0.skipped }.count }
    var failureCount: Int { results.filter { !$0.success && !$0.skipped }.count }
    var touchedBytes: Int64 { results.filter { $0.success }.reduce(0) { $0 + $1.bytes } }
}

// MARK: - History

struct HistoryEvent: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var module: ModuleID
    var action: String
    var itemCount: Int
    var bytes: Int64
    var outcome: String
    var detail: String?
    var movedToTrash: Bool? = true
}

// MARK: - Apps and associations

struct AppRecord: Identifiable, Hashable, Sendable {
    var id: String { bundleURL.path }
    var bundleURL: URL
    var name: String
    var version: String
    var bundleID: String
    var size: Int64
    var isSystem: Bool
    var isRunning: Bool
    var vendorUninstaller: URL?
    var accessError: String?
    var fingerprint: FileFingerprint?
    var associations: [ScanItem]
    var source: String
    var iconPath: String?
    var teamID: String?
    var sharedContainers: [String] = []

    var removableAssociations: [ScanItem] { associations.filter { !$0.isProtected } }
}

struct ExtensionRecord: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case system, safari, chromium, firefox }
    var id: String
    var name: String
    var provider: String
    var host: String
    var version: String
    var enabled: Bool?
    var kind: Kind
    var path: String?
    var managementURL: String?
    var note: String?
}

struct LoginRecord: Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case userLaunchAgent, backgroundItem }
    enum Manageability: String, Codable, Sendable { case manageable, systemManaged }
    var id: String
    var name: String
    var publisher: String
    var source: Source
    var manageability: Manageability
    var status: String
    var path: String?
    var identifier: String
    var detail: String?
    var enabled: Bool?
}

struct PowerSetting: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var label: String
    var batteryValue: String?
    var acValue: String?
    var explanation: String
}

struct PowerSnapshot: Sendable {
    var settings: [PowerSetting]
    var differences: [PowerSetting]
    var batteryDescription: String
    var batteryTimeRemaining: String?
    var batteryPercent: String?
    var hibernationFile: String?
    var hibernationFileSize: Int64?
    var swapUsed: String?
    var readAt: Date
    var notes: [String]
}

// MARK: - Progress

struct ScanProgress: Sendable {
    var fraction: Double
    var message: String
}

struct ModuleSummary: Identifiable, Sendable {
    var id: ModuleID
    var bytes: Int64
    var itemCount: Int
    var lastScan: Date?
    var note: String?
}
