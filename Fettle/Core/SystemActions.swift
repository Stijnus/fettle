import Foundation
import AppKit
import CryptoKit
import UserNotifications

enum SystemSettingsPane: String {
    case loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    case battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    case energySaver = "x-apple.systempreferences:com.apple.EnergySaver-Settings.extension"
    case privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    case desktopDock = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    case notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
}

enum SystemActions {
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func open(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func openSettings(_ pane: SystemSettingsPane) {
        _ = open(pane.rawValue)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFolder(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        appURL(for: bundleID) != nil
    }

    static func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    static func isRunning(bundleID: String) -> Bool {
        runningApplication(bundleID: bundleID) != nil
    }

    static func isRunning(appAt url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleURL = app.bundleURL else { return false }
            return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == target && !app.isTerminated
        }
    }

    @discardableResult
    static func quit(bundleID: String) -> Bool {
        guard let app = runningApplication(bundleID: bundleID) else { return true }
        return app.terminate()
    }

    /// Launches a browser with one of its internal URLs. If LaunchServices refuses
    /// the scheme, the app opens and the URL is copied so the person can paste it.
    static func openBrowserSettings(bundleID: String, urlString: String) -> Bool {
        guard let appURL = appURL(for: bundleID) else { return false }
        if let target = URL(string: urlString) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: configuration) { _, error in
                if error != nil {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                }
            }
            return true
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func openVendorUninstaller(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openFinderHome() {
        _ = NSWorkspace.shared.open(AppPaths.home)
    }

    static func openLoginItemsSettings() {
        openSettings(.loginItems)
    }

    static func openPrivacySettings() {
        openSettings(.privacy)
    }
}

// MARK: - Updates

struct UpdateFeed: Codable, Sendable {
    var version: String
    var build: String?
    var url: String
    var sha256: String?
    var signature: String
    var notes: String?
}

enum UpdateCheckResult: Sendable {
    case notConfigured
    case upToDate(String)
    case available(UpdateFeed)
    case invalidSignature
    case unreachable(String)
    case invalidFeed(String)
}

enum UpdateChecker {
    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static func check(feedURL: String, publicKeyBase64: String, session: URLSession = .shared) async -> UpdateCheckResult {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return .notConfigured
        }
        let keyString = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyString.isEmpty else { return .notConfigured }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unreachable("HTTP error")
            }
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            let payload = "\(feed.version)|\(feed.build ?? "")|\(feed.url)|\(feed.sha256 ?? "")"
            guard let signatureData = Data(base64Encoded: feed.signature, options: .ignoreUnknownCharacters),
                  let keyData = Data(base64Encoded: keyString, options: .ignoreUnknownCharacters),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
                return .invalidSignature
            }
            guard publicKey.isValidSignature(signatureData, for: Data(payload.utf8)) else {
                return .invalidSignature
            }
            if isNewer(feed.version, than: currentVersion) {
                return .available(feed)
            }
            return .upToDate(currentVersion)
        } catch is DecodingError {
            return .invalidFeed("Malformed feed")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}

// MARK: - Notifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private var didRequest = false

    private init() {
        registerCategories()
    }

    /// Registers the cleanup reminder category. No custom actions are added;
    /// tapping the reminder simply opens Fettle.
    private func registerCategories() {
        let category = UNNotificationCategory(
            identifier: Rules.Reminder.notificationCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            didRequest = true
            return granted
        } catch {
            return false
        }
    }

    func scheduleReminders(cleanup: Bool, trash: Bool, intervalDays: Int, trashThresholdMB: Int) {
        center.removePendingNotificationRequests(withIdentifiers: ["fettle.cleanup", "fettle.trash"])
        // The Trash reminder is sent by notifyTrashSize only when the measured
        // Trash is over the threshold, never on a blind weekly timer.
        guard cleanup else { return }
        if cleanup {
            let content = UNMutableNotificationContent()
            content.title = L("Fettle")
            content.body = L("It has been a while since your last checkup. A quick scan can keep things tidy.")
            content.sound = .default
            // Intervals come from the fixed option table in `Rules.Reminder`.
            let interval = Rules.Reminder.intervalSeconds(forDays: intervalDays)
            content.categoryIdentifier = Rules.Reminder.notificationCategory
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, interval),
                repeats: Rules.Reminder.notificationRepeats
            )
            center.add(UNNotificationRequest(identifier: "fettle.cleanup", content: content, trigger: trigger))
        }
    }

    func notifyTrashSize(bytes: Int64, thresholdMB: Int) {
        guard bytes > Int64(thresholdMB) * 1_000_000 else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Trash reminder")
        content.body = L("Your Trash is larger than %@. Review it in Disk Cleanup.", Fmt.bytes(bytes))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        center.add(UNNotificationRequest(identifier: "fettle.trash.now", content: content, trigger: trigger))
    }

    func notifyLowDiskSpace(freeSpace: Int64, thresholdBytes: Int64) {
        // A readable zero is a real free-space value: the automatic rule
        // maps it to the smallest 2 GB option, and 0 is below
        // every option, so it must still alert. Only the threshold itself has
        // to be positive.
        guard thresholdBytes > 0, freeSpace < thresholdBytes else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Low disk space")
        content.body = L("Only %@ is free, below the %@ alert level. Open Fettle to reclaim space.", Fmt.bytes(freeSpace), Fmt.bytes(thresholdBytes))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        center.add(UNNotificationRequest(identifier: "fettle.disk.now", content: content, trigger: trigger))
    }

    func notifyScanComplete(bytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = L("Scan complete")
        content.body = L("Fettle found %@ of estimated removable files. Nothing has been changed.", Fmt.bytes(bytes))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        center.add(UNNotificationRequest(identifier: "fettle.scan.done", content: content, trigger: trigger))
    }

    func notifyHealthAlert(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.5, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
