import Foundation
import AppKit

enum BrowserKind: String, Codable, CaseIterable, Sendable {
    case safari, chrome, firefox, edge, opera

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .opera: return "Opera"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .opera: return "com.operasoftware.Opera"
        }
    }

    var passwordURL: String {
        switch self {
        case .safari: return "x-apple.systempreferences:com.apple.Passwords-Settings.extension"
        case .chrome: return "chrome://settings/passwords"
        case .firefox: return "about:logins"
        case .edge: return "edge://settings/passwords"
        case .opera: return "opera://settings/passwords"
        }
    }

    var extensionsURL: String {
        switch self {
        case .safari: return "safari"
        case .chrome: return "chrome://extensions"
        case .firefox: return "about:addons"
        case .edge: return "edge://extensions"
        case .opera: return "opera://extensions"
        }
    }
}

struct BrowserProfileSummary: Identifiable, Hashable, Sendable {
    var id: String
    var browser: BrowserKind
    var profileName: String
    var root: URL
    var isRunning: Bool
}

struct RecentItemSummary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var count: Int
    var path: String
}

enum PrivacyScanner {
    struct Result: Sendable {
        var report: ScanReport
        var profiles: [BrowserProfileSummary]
        var recentItems: [RecentItemSummary]
        var notes: [String]
    }

    static func scan(
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> Result {
        let started = Date()
        var items: [ScanItem] = []
        var skipped: [SkippedItem] = []
        var profiles: [BrowserProfileSummary] = []
        var notes: [String] = []

        let browsers = BrowserKind.allCases
        for (index, browser) in browsers.enumerated() {
            if cancelled() { break }
            progress(ScanProgress(fraction: 0.05 + 0.8 * Double(index) / Double(browsers.count), message: L("Scanning %@…", browser.displayName)))
            switch browser {
            case .safari:
                let safari = scanSafari(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                items += safari.items
                if let profile = safari.profile { profiles.append(profile) }
            case .chrome, .edge, .opera:
                let chromium = scanChromium(
                    browser: browser,
                    ignoreList: ignoreList,
                    skipped: &skipped,
                    cancelled: cancelled
                )
                items += chromium.items
                profiles += chromium.profiles
            case .firefox:
                let firefox = scanFirefox(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                items += firefox.items
                profiles += firefox.profiles
            }
        }

        let knownBrowsers = Set(profiles.map { $0.browser })
        for browser in BrowserKind.allCases where !knownBrowsers.contains(browser) && SystemActions.isInstalled(browser.bundleID) {
            profiles.append(BrowserProfileSummary(
                id: "\(browser.rawValue)|no-profile",
                browser: browser,
                profileName: L("No profile yet"),
                root: URL(fileURLWithPath: "/"),
                isRunning: SystemActions.isRunning(bundleID: browser.bundleID)
            ))
        }

        progress(ScanProgress(fraction: 0.9, message: L("Scanning %@…", L("Recent items"))))
        let recents = recentItemSummaries()
        if !recents.isEmpty {
            for recent in recents {
                var item = ScanItem.make(
                    url: URL(fileURLWithPath: recent.path),
                    category: .recentItems,
                    size: 0,
                    fingerprint: FileFingerprint(size: 0, modified: nil, isDirectory: false),
                    location: PathDisplay.short(recent.path),
                    detail: L("Recent items are managed by macOS. Open Finder or the Apple menu to review and clear them."),
                    informational: true,
                    scope: .none
                )
                item.name = recent.name
                items.append(item)
            }
        }

        notes.append(L("Cookies and site data sign you out"))
        notes.append(L("Clearing cache does not sign you out."))
        notes.append(L("Downloaded files are kept. Only the list of downloads is cleared."))
        notes.append(L("Close the browser before clearing history or cookies."))
        notes.append(L("Passwords, autofill data and payment cards are never touched by Fettle."))
        notes.append(L("Browsers are read where their profiles are available. Safari data is protected by macOS and may require permission."))

        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        items.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            if lhs.category != rhs.category { return categoryOrder(lhs.category) < categoryOrder(rhs.category) }
            return lhs.size > rhs.size
        }
        skipped.append(contentsOf: [])
        return Result(
            report: ScanReport(scannedAt: Date(), items: items, skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started)),
            profiles: profiles,
            recentItems: recents,
            notes: notes
        )
    }

    static func categoryOrder(_ category: ItemCategory) -> Int {
        switch category {
        case .browserCache: return 0
        case .cookies: return 1
        case .websiteData: return 2
        case .browsingHistory: return 3
        case .downloadHistory: return 4
        case .recentItems: return 5
        default: return 9
        }
    }

    // MARK: Safari

    static func scanSafari(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> (items: [ScanItem], profile: BrowserProfileSummary?) {
        let running = SystemActions.isRunning(bundleID: BrowserKind.safari.bundleID)
        var items: [ScanItem] = []
        let root = AppPaths.safari
        let container = AppPaths.containers.appendingPathComponent("com.apple.Safari/Data", isDirectory: true)
        let profile = BrowserProfileSummary(
            id: "safari|default",
            browser: .safari,
            profileName: "Safari",
            root: root,
            isRunning: running
        )
        let safariLocation = "Safari"

        items += add(file: root.appendingPathComponent("History.db"), category: .browsingHistory, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Clearing history removes the list of sites you visited. You stay signed in."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        items += add(file: root.appendingPathComponent("Downloads.plist"), category: .downloadHistory, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Downloaded files are kept. Only the list of downloads is cleared."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        items += add(file: container.appendingPathComponent("Library/Cookies/Cookies.binarycookies"), category: .cookies, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Cookies and site data sign you out"), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        items += add(file: AppPaths.safariCaches, category: .browserCache, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Clearing cache does not sign you out."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        items += add(file: AppPaths.caches.appendingPathComponent("com.apple.Safari.SafeBrowsing"), category: .browserCache, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Clearing cache does not sign you out."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        for name in ["LocalStorage", "Databases", "WebsiteData"] {
            items += add(file: root.appendingPathComponent(name), category: .websiteData, browser: .safari, profile: "Safari", running: running, location: safariLocation, detail: L("Clearing this data will sign you out of websites."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        }
        let hasProfile = !items.isEmpty || FileManager.default.fileExists(atPath: root.path) || FileManager.default.fileExists(atPath: container.path)
        return (items, hasProfile ? profile : nil)
    }

    // MARK: Chromium

    static func scanChromium(
        browser: BrowserKind,
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> (items: [ScanItem], profiles: [BrowserProfileSummary]) {
        let roots: [URL]
        switch browser {
        case .chrome:
            roots = [AppPaths.applicationSupport.appendingPathComponent("Google/Chrome", isDirectory: true)]
        case .edge:
            roots = [AppPaths.applicationSupport.appendingPathComponent("Microsoft Edge", isDirectory: true)]
        case .opera:
            roots = [AppPaths.applicationSupport.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)]
        default:
            roots = []
        }
        var items: [ScanItem] = []
        var profiles: [BrowserProfileSummary] = []
        let running = SystemActions.isRunning(bundleID: browser.bundleID)
        for root in roots where readableProfileDirectory(root, skipped: &skipped) {
            for profileURL in ExtensionsScanner.discoverChromiumProfiles(root: root) {
                if cancelled() { break }
                let profileName = profileURL.standardizedFileURL == root.standardizedFileURL ? "Default" : profileURL.lastPathComponent
                profiles.append(BrowserProfileSummary(
                    id: "\(browser.rawValue)|\(profileURL.path)",
                    browser: browser,
                    profileName: profileName,
                    root: profileURL,
                    isRunning: running
                ))
                let location = "\(browser.displayName) — \(profileName)"
                let caches = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "DawnCache"]
                for cache in caches {
                    items += add(file: profileURL.appendingPathComponent(cache), category: .browserCache, browser: browser, profile: profileName, running: running, location: location, detail: L("Clearing cache does not sign you out."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                }
                let cookies = ["Cookies", "Network/Cookies"]
                for cookie in cookies {
                    items += add(file: profileURL.appendingPathComponent(cookie), category: .cookies, browser: browser, profile: profileName, running: running, location: location, detail: L("Clearing this data will sign you out of websites."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                }
                for website in ["Local Storage", "Session Storage", "IndexedDB", "WebSQL", "Service Worker", "CacheStorage", "File System"] {
                    items += add(file: profileURL.appendingPathComponent(website), category: .websiteData, browser: browser, profile: profileName, running: running, location: location, detail: L("Clearing this data will sign you out of websites."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                }
                for history in ["History", "Top Sites", "Visited Links"] {
                    items += add(file: profileURL.appendingPathComponent(history), category: .browsingHistory, browser: browser, profile: profileName, running: running, location: location, detail: L("Clearing history removes the list of sites you visited. You stay signed in."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
                }
                items += add(file: profileURL.appendingPathComponent("History"), category: .downloadHistory, browser: browser, profile: profileName, running: running, location: location, detail: L("Downloaded files are kept. Only the list of downloads is cleared."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            }
        }
        return (items, profiles)
    }

    // MARK: Firefox

    private static func readableProfileDirectory(_ url: URL, skipped: inout [SkippedItem]) -> Bool {
        guard access(url.path, R_OK | X_OK) != 0 else { return true }
        if errno == EACCES || errno == EPERM {
            skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Permission denied"), category: nil, unreadable: true))
        }
        return false
    }

    static func scanFirefox(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> (items: [ScanItem], profiles: [BrowserProfileSummary]) {
        let root = AppPaths.applicationSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        guard readableProfileDirectory(root, skipped: &skipped) else { return ([], []) }
        let running = SystemActions.isRunning(bundleID: BrowserKind.firefox.bundleID)
        var items: [ScanItem] = []
        var profiles: [BrowserProfileSummary] = []
        for profileURL in FileSafety.children(of: root) where FileSafety.isDirectory(profileURL) {
            if cancelled() { break }
            let profileName = profileURL.lastPathComponent
            profiles.append(BrowserProfileSummary(
                id: "firefox|\(profileURL.path)",
                browser: .firefox,
                profileName: profileName,
                root: profileURL,
                isRunning: running
            ))
            let location = "Firefox — \(profileName)"
            items += add(file: profileURL.appendingPathComponent("cache2"), category: .browserCache, browser: .firefox, profile: profileName, running: running, location: location, detail: L("Clearing cache does not sign you out."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            items += add(file: profileURL.appendingPathComponent("cookies.sqlite"), category: .cookies, browser: .firefox, profile: profileName, running: running, location: location, detail: L("Clearing this data will sign you out of websites."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            items += add(file: profileURL.appendingPathComponent("places.sqlite"), category: .browsingHistory, browser: .firefox, profile: profileName, running: running, location: location, detail: L("Clearing history removes the list of sites you visited. You stay signed in."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            items += add(file: profileURL.appendingPathComponent("places.sqlite"), category: .downloadHistory, browser: .firefox, profile: profileName, running: running, location: location, detail: L("Downloaded files are kept. Only the list of downloads is cleared."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            for website in ["storage", "IndexedDB", "sessionstore-backups"] {
                items += add(file: profileURL.appendingPathComponent(website), category: .websiteData, browser: .firefox, profile: profileName, running: running, location: location, detail: L("Clearing this data will sign you out of websites."), ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            }
        }
        return (items, profiles)
    }

    // MARK: Item helper

    static func add(
        file: URL,
        category: ItemCategory,
        browser: BrowserKind,
        profile: String,
        running: Bool,
        location: String,
        detail: String,
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        guard !cancelled() else { return [] }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            if errno == EACCES || errno == EPERM {
                skipped.append(SkippedItem(path: PathDisplay.short(file.path), reason: L("Permission denied"), category: category, unreadable: true))
            }
            return []
        }
        if FileSafety.isSymbolicLink(file) {
            skipped.append(SkippedItem(path: PathDisplay.short(file.path), reason: L("Symbolic links"), category: category))
            return []
        }
        if DiskCleanupScanner.isIgnored(file, ignoreList) {
            skipped.append(SkippedItem(path: PathDisplay.short(file.path), reason: L("This folder is on the ignore list."), category: category))
            return []
        }
        guard FileManager.default.isReadableFile(atPath: file.path), let fingerprint = FileSafety.fingerprint(of: file) else {
            skipped.append(SkippedItem(path: PathDisplay.short(file.path), reason: L("Permission denied"), category: category, unreadable: true))
            return []
        }
        var item = ScanItem.make(
            url: file,
            category: category,
            size: fingerprint.size,
            fingerprint: fingerprint,
            location: location,
            detail: detail,
            evidence: [L("Profile: %@", profile)],
            bundleID: browser.bundleID,
            appName: browser.displayName,
            scope: .privacy
        )
        item.isRunningApp = running
        if category == .browsingHistory || category == .cookies || category == .websiteData {
            item.isProtected = running
        }
        // The download-history row shares a database file with history. Keep a
        // distinct identity so the review can show both actions separately.
        if category == .downloadHistory {
            item.id = "\(category.rawValue)|downloads|\(file.path)"
            // Clearing download records does not free the database's bytes;
            // the downloaded files are deliberately kept.
            item.size = 0
        }
        return [item]
    }

    /// SQLite write-ahead logs are part of the same browser database. They are
    /// included in the confirmation so clearing history/cookies does not leave
    /// a WAL behind with the old records.
    static func sidecarItems(for item: ScanItem) -> [ScanItem] {
        guard item.category == .cookies || item.category == .browsingHistory || item.category == .websiteData else { return [] }
        // Firefox history is cleared in place with SQL; places.sqlite and its
        // WAL also hold bookmarks, so they are never moved.
        if isFirefoxHistory(item) { return [] }
        var result: [ScanItem] = []
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: item.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path), !FileSafety.isSymbolicLink(url) else { continue }
            guard let fp = FileSafety.fingerprint(of: url) else { continue }
            var side = ScanItem.make(
                url: url,
                category: item.category,
                size: fp.size,
                fingerprint: fp,
                location: item.location,
                detail: item.detail,
                bundleID: item.bundleID,
                appName: item.appName,
                scope: .privacy
            )
            side.isProtected = item.isProtected
            side.isRunningApp = item.isRunningApp
            result.append(side)
        }
        return result
    }

    // MARK: Recent items

    static func recentItemSummaries() -> [RecentItemSummary] {
        let root = AppPaths.sharedFileLists
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let mapping: [(prefix: String, name: String)] = [
            ("com.apple.LSSharedFileList.RecentApplications", L("Recent applications")),
            ("com.apple.LSSharedFileList.RecentDocuments", L("Recent documents")),
            ("com.apple.LSSharedFileList.RecentServers", L("Recent servers")),
            ("com.apple.LSSharedFileList.RecentHosts", L("Recent servers")),
            ("com.apple.LSSharedFileList.RecentFolders", L("Recent items")),
        ]
        var seenNames = Set<String>()
        var summaries: [RecentItemSummary] = []
        for url in FileSafety.children(of: root) {
            guard let match = mapping.first(where: { url.lastPathComponent.hasPrefix($0.prefix) }) else { continue }
            guard seenNames.insert(match.name).inserted else { continue }
            var count = 0
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                if let array = plist as? [Any] { count = array.count }
                if let dict = plist as? [String: Any], let items = dict["items"] as? [Any] { count = items.count }
            }
            summaries.append(RecentItemSummary(id: match.name, name: match.name, count: count, path: url.path))
        }
        return summaries.sorted { $0.name < $1.name }
    }

    // MARK: Clearing Firefox history

    static func isFirefoxHistory(_ item: ScanItem) -> Bool {
        item.category == .browsingHistory && item.bundleID == BrowserKind.firefox.bundleID
    }

    /// Clears visits and unbookmarked places inside places.sqlite. The file is
    /// never moved, because it also holds the person's bookmarks.
    static func clearFirefoxHistory(item: ScanItem) -> ItemResult {
        if SystemActions.isRunning(bundleID: BrowserKind.firefox.bundleID) {
            return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("This browser is running. Quit it and rescan before clearing history or cookies."), bytes: 0)
        }
        // The database is edited in place, so a change made by clearing download
        // records just before is expected; every other check still applies.
        if let error = FileSafety.validate(item, scope: .privacy), error != .changed {
            return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: error.localizedDescription, bytes: 0)
        }
        let sql = "PRAGMA busy_timeout=3000; BEGIN; DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; DELETE FROM moz_places WHERE foreign_count = 0 AND id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL); COMMIT;"
        let run = Shell.run(FsTool.sqlitePath, [item.path, sql], timeout: 12)
        return ItemResult(path: item.path, name: item.name, category: item.category, success: run.succeeded, skipped: !run.succeeded, message: run.succeeded ? nil : run.stderr, bytes: 0)
    }

    // MARK: Clearing download history

    static func clearDownloadHistory(item: ScanItem) -> ItemResult {
        guard let browser = BrowserKind.allCases.first(where: { $0.bundleID == item.bundleID }) else {
            return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("Unsupported"), bytes: 0)
        }
        if SystemActions.isRunning(bundleID: browser.bundleID) {
            return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("This browser is running. Quit it and rescan before clearing history or cookies."), bytes: 0)
        }
        if let error = FileSafety.validate(item, scope: .privacy) {
            return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: error.localizedDescription, bytes: 0)
        }
        switch browser {
        case .chrome, .edge, .opera:
            let statements = [
                "PRAGMA busy_timeout=3000; DELETE FROM downloads_url_chains;",
                "PRAGMA busy_timeout=3000; DELETE FROM downloads_slices;",
                "PRAGMA busy_timeout=3000; DELETE FROM downloads;"
            ]
            var success = false
            for statement in statements {
                let run = Shell.run(FsTool.sqlitePath, [item.path, statement], timeout: 12)
                if run.succeeded { success = true }
            }
            if !success {
                let fallback = Shell.run(FsTool.sqlitePath, [item.path, "PRAGMA busy_timeout=3000; DELETE FROM downloads;"], timeout: 12)
                success = fallback.succeeded
            }
            return ItemResult(path: item.path, name: item.name, category: item.category, success: success, skipped: !success, message: success ? nil : L("One or more browser files could not be cleared. Quit the browser and try again."), bytes: 0)
        case .firefox:
            let sql = "PRAGMA busy_timeout=3000; DELETE FROM moz_annos WHERE anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%');"
            let run = Shell.run(FsTool.sqlitePath, [item.path, sql], timeout: 12)
            return ItemResult(path: item.path, name: item.name, category: item.category, success: run.succeeded, skipped: !run.succeeded, message: run.succeeded ? nil : run.stderr, bytes: 0)
        case .safari:
            guard let data = try? Data(contentsOf: item.url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("Safari data was not readable. Grant Full Disk Access only if you want Safari history and cookies included."), bytes: 0)
            }
            // Downloads.plist is a dictionary with the list under DownloadHistory;
            // keep every other key and empty only that list.
            let cleared: Any
            if var dict = plist as? [String: Any] {
                dict["DownloadHistory"] = [Any]()
                cleared = dict
            } else if plist is [Any] {
                cleared = [Any]()
            } else {
                return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("Unsupported"), bytes: 0)
            }
            guard let newData = try? PropertyListSerialization.data(fromPropertyList: cleared, format: .binary, options: 0) else {
                return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: L("One or more browser files could not be cleared. Quit the browser and try again."), bytes: 0)
            }
            do {
                try newData.write(to: item.url, options: .atomic)
                return ItemResult(path: item.path, name: item.name, category: item.category, success: true, bytes: 0)
            } catch {
                return ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: false, message: (error as NSError).localizedDescription, bytes: 0)
            }
        }
    }
}
