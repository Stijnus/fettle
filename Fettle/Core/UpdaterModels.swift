import Foundation

// MARK: - App update model

/// Where an update for an installed app comes from. Fettle only reads the
/// source the app itself publishes; it never invents an update.
enum AppUpdateSource: String, Codable, Sendable {
    case sparkle
    case appStore
    case appleSoftwareUpdate
    case none

    var title: String {
        switch self {
        case .sparkle: return L("App's own update feed")
        case .appStore: return L("App Store")
        case .appleSoftwareUpdate: return L("Apple Software Update")
        case .none: return L("No update feed")
        }
    }

    var shortTitle: String {
        switch self {
        case .sparkle: return L("Sparkle feed")
        case .appStore: return L("App Store")
        case .appleSoftwareUpdate: return L("macOS Software Update")
        case .none: return L("No feed")
        }
    }

    var symbol: String {
        switch self {
        case .sparkle: return "arrow.triangle.2.circlepath"
        case .appStore: return "storefront.fill"
        case .appleSoftwareUpdate: return "applelogo"
        case .none: return "questionmark.circle"
        }
    }
}

enum AppUpdateStatus: String, Codable, Sendable {
    case available
    case upToDate
    case appStore
    case appleSoftwareUpdate
    case noChannel
    case incompatible
    case failed

    var title: String {
        switch self {
        case .available: return L("Update available")
        case .upToDate: return L("Up to date")
        case .appStore: return L("Managed by App Store")
        case .appleSoftwareUpdate: return L("Managed by macOS")
        case .noChannel: return L("No update feed")
        case .incompatible: return L("Requires a newer macOS")
        case .failed: return L("Check failed")
        }
    }

    var isActionable: Bool {
        self == .available || self == .appStore || self == .appleSoftwareUpdate
    }

    var sortRank: Int {
        switch self {
        case .available: return 0
        case .appStore: return 2
        case .appleSoftwareUpdate: return 3
        case .incompatible: return 4
        case .failed: return 5
        case .upToDate: return 6
        case .noChannel: return 7
        }
    }
}

struct AppUpdateRecord: Identifiable, Hashable, Codable, Sendable {
    var id: String { bundleURL.path }
    var bundleURL: URL
    var appName: String
    var bundleID: String
    var currentVersion: String
    var currentBuild: String
    var latestVersion: String?
    var latestBuild: String?
    var status: AppUpdateStatus
    var source: AppUpdateSource
    var feedURL: URL?
    var downloadURL: URL?
    var releaseNotes: String?
    var releaseDate: Date?
    var updateSize: Int64?
    var minimumSystemVersion: String?
    var errorMessage: String?
    var isRunning: Bool = false
    var isSystem: Bool = false
    var checkedAt: Date?
    var openedAt: Date?

    var hasNewerVersion: Bool {
        guard let latestVersion, !latestVersion.isEmpty else { return false }
        return VersionOrder.compare(latestVersion, currentVersion) == .orderedDescending
    }

    var versionComparison: String {
        guard let latestVersion, !latestVersion.isEmpty else { return currentVersion }
        return "\(currentVersion) → \(latestVersion)"
    }

    /// The page Fettle opens. It never runs an installer. Sparkle apps go to
    /// the enclosure or feed the vendor published; App Store and Apple apps go
    /// to their supported management pages.
    var actionURL: URL? {
        switch status {
        case .available:
            guard let url = downloadURL ?? feedURL,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                return nil
            }
            return url
        case .appStore:
            return URL(string: "macappstore://showUpdatesPage")
        case .appleSoftwareUpdate:
            return URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        default:
            return nil
        }
    }

    var actionTitle: String {
        switch status {
        case .available: return L("Open Update Page")
        case .appStore: return L("Open App Store")
        case .appleSoftwareUpdate: return L("Open Software Update")
        default: return L("Open")
        }
    }
}

// MARK: - Appcast

struct AppcastEntry: Sendable {
    var shortVersion: String?
    var buildVersion: String?
    var title: String?
    var link: URL?
    var downloadURL: URL?
    var releaseNotes: String?
    var releaseDate: Date?
    var updateSize: Int64?
    var minimumSystemVersion: String?
}

enum AppcastError: LocalizedError, Sendable {
    case empty
    case malformed(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .empty: return L("The update feed was empty.")
        case .malformed(let reason): return reason
        case .tooLarge: return L("The update feed was too large to read.")
        }
    }
}

// MARK: - Version ordering

enum VersionOrder {
    /// A component-wise version comparison. Numeric components compare as
    /// numbers, a missing component is zero, and a pre-release suffix sorts
    /// before the release it belongs to.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : .missing
            let r = index < right.count ? right[index] : .missing
            switch (l, r) {
            case (.number(let a), .number(let b)):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case (.word(let a), .word(let b)):
                let result = a.localizedCaseInsensitiveCompare(b)
                if result != .orderedSame { return result }
            case (.number, .word):
                // A numeric component is newer than a pre-release word.
                return .orderedDescending
            case (.word, .number):
                return .orderedAscending
            case (.missing, .missing):
                continue
            case (.missing, .number(let b)):
                if b != 0 { return .orderedAscending }
            case (.number(let a), .missing):
                if a != 0 { return .orderedDescending }
            case (.missing, .word):
                return .orderedDescending
            case (.word, .missing):
                return .orderedAscending
            }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private enum Component: Equatable {
        case number(Int)
        case word(String)
        case missing
    }

    private static func components(_ version: String) -> [Component] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        var result: [Component] = []
        var digits = ""
        var letters = ""
        func flush() {
            if !digits.isEmpty {
                result.append(.number(Int(digits) ?? 0))
                digits = ""
            }
            if !letters.isEmpty {
                result.append(.word(letters.lowercased()))
                letters = ""
            }
        }
        for character in text {
            if character.isNumber {
                if !letters.isEmpty { flush() }
                digits.append(character)
            } else if character.isLetter {
                if !digits.isEmpty { flush() }
                letters.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}

// MARK: - OS requirement helper

enum MacOSVersion {
    static var current: String {
        ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
            .replacingOccurrences(of: " (", with: " ")
            .components(separatedBy: " ").first ?? "14.0"
    }

    static func isAtLeast(_ required: String) -> Bool {
        guard !required.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return VersionOrder.compare(current, required) != .orderedAscending
    }
}
