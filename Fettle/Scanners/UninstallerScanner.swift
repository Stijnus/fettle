import Foundation
import AppKit

enum UninstallerScanner {
    struct Result: Sendable {
        var apps: [AppRecord]
        var skipped: [SkippedItem]
        var notes: [String]
        var duration: TimeInterval
    }

    static func roots(extraFolders: [String]) -> [URL] {
        var roots: [URL]
        if let override = ProcessInfo.processInfo.environment["FETTLE_APPS_ROOT"], !override.isEmpty {
            roots = [URL(fileURLWithPath: override, isDirectory: true)]
        } else {
            roots = [URL(fileURLWithPath: "/Applications"), AppPaths.applications]
        }
        roots += extraFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        if let override = ProcessInfo.processInfo.environment["FETTLE_APPS_ROOT"], !override.isEmpty,
           let url = roots.first {
            _ = url
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func scan(
        extraFolders: [String] = [],
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> Result {
        let started = Date()
        var apps: [AppRecord] = []
        var skipped: [SkippedItem] = []
        var notes: [String] = []
        let scanRoots = roots(extraFolders: extraFolders)
        let appURLs = discoverApps(in: scanRoots, skipped: &skipped, cancelled: cancelled)
        let total = max(1, appURLs.count)
        let installedIDs = Set(appURLs.compactMap { FileSafety.appBundleInfo(at: $0)?.id })

        for (index, url) in appURLs.enumerated() {
            if cancelled() { break }
            progress(ScanProgress(fraction: 0.05 + 0.8 * Double(index) / Double(total), message: L("Scanning %@…", url.deletingPathExtension().lastPathComponent)))
            guard let info = FileSafety.appBundleInfo(at: url) else {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Could not read this app"), category: .app))
                continue
            }
            let fingerprint = appFingerprint(url)
            let isSystem = info.id.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
            let running = SystemActions.isRunning(appAt: url)
            let vendor = vendorUninstaller(in: url)
            let associations = associations(for: info.id, appName: info.name, ignoreList: ignoreList)
            let shared = sharedContainerNames(for: info.id, appName: info.name, installedIDs: installedIDs)
            let record = AppRecord(
                bundleURL: url,
                name: info.name,
                version: info.version,
                bundleID: info.id,
                size: fingerprint?.size ?? 0,
                isSystem: isSystem,
                isRunning: running,
                vendorUninstaller: vendor,
                accessError: fingerprint == nil ? L("Access denied while reading this app. It is not selected and cannot be removed.") : nil,
                fingerprint: fingerprint,
                associations: associations,
                source: PathDisplay.short(url.deletingLastPathComponent().path),
                teamID: nil,
                sharedContainers: shared
            )
            apps.append(record)
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        notes.append(L("Fettle lists apps and matches support files by exact bundle identifier. Shared containers and ambiguous matches are never removed."))
        if !skipped.isEmpty { notes.append(L("Uninstaller scan skipped some folders")) }
        progress(ScanProgress(fraction: 0.98, message: L("Preparing…")))
        return Result(apps: apps, skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started))
    }

    static func appFingerprint(_ url: URL) -> FileFingerprint? {
        let info = FileSafety.lstatInfo(url)
        guard info.exists, info.isDirectory, !info.isSymlink else { return nil }
        let du = Shell.run("/usr/bin/du", ["-sk", url.path], timeout: 45)
        var size: Int64 = 0
        if du.succeeded, let first = du.stdout.split(separator: "\t").first, let kb = Int64(first.trimmingCharacters(in: .whitespaces)) {
            size = kb * 1024
        } else {
            size = FileSafety.directorySize(url).size
        }
        return FileFingerprint(size: size, modified: info.modified, isDirectory: true, childCount: nil)
    }

    static func discoverApps(
        in roots: [URL],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for url in FileSafety.children(of: root) {
                if cancelled() { break }
                guard url.pathExtension.lowercased() == "app" else { continue }
                if FileSafety.isSymbolicLink(url) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .app))
                    continue
                }
                let canonical = url.standardizedFileURL.path
                if seen.insert(canonical).inserted {
                    result.append(url)
                }
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Associations

    static func associations(for bundleID: String, appName: String, ignoreList: [String]) -> [ScanItem] {
        let library = AppPaths.library
        var candidates: [(URL, ItemCategory, Bool)] = [
            (AppPaths.caches.appendingPathComponent(bundleID), .appCache, false),
            (AppPaths.logs.appendingPathComponent(bundleID), .appLogs, false),
            (AppPaths.preferences.appendingPathComponent(bundleID + ".plist"), .appPreferences, false),
            (AppPaths.applicationSupport.appendingPathComponent(bundleID), .appSupport, true),
            (AppPaths.savedState.appendingPathComponent(bundleID + ".savedState"), .appSupport, true),
            (AppPaths.containers.appendingPathComponent(bundleID), .appData, true),
            (AppPaths.webKit.appendingPathComponent(bundleID), .appSupport, false),
            (AppPaths.httpStorages.appendingPathComponent(bundleID), .appSupport, false),
            (AppPaths.cookies.appendingPathComponent(bundleID + ".binarycookies"), .appSupport, false),
            (library.appendingPathComponent("Application Scripts").appendingPathComponent(bundleID), .appSupport, false),
            (AppPaths.launchAgents.appendingPathComponent(bundleID + ".plist"), .appLaunchAgent, false),
        ]
        // Extra user-writable roots where apps leave per-bundle data
        // (see `Rules.Leftovers`).
        for root in Rules.Leftovers.userRoots where root.appendsBundleID {
            let url = AppPaths.library
                .appendingPathComponent(root.relativeToLibrary, isDirectory: true)
                .appendingPathComponent(bundleID)
            candidates.append((url, .appSupport, false))
        }
        var items: [ScanItem] = []
        for (url, category, isData) in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if FileSafety.isSymbolicLink(url) { continue }
            if DiskCleanupScanner.isIgnored(url, ignoreList) { continue }
            guard let fingerprint = FileSafety.fingerprint(of: url) else { continue }
            var item = ScanItem.make(
                url: url,
                category: category,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(url.deletingLastPathComponent().path),
                detail: category == .appData ? L("This item contains app data. Review it carefully.") : L("Exact identifier match"),
                evidence: [L("Matched bundle identifier %@.", bundleID)],
                bundleID: bundleID,
                appName: appName,
                isAppData: isData,
                scope: .uninstaller
            )
            item.isAppData = isData
            items.append(item)
        }
        return items.sorted { $0.size > $1.size }
    }

    static func sharedContainerNames(for bundleID: String, appName: String, installedIDs: Set<String>) -> [String] {
        let groupRoot = AppPaths.groupContainers
        let children = FileSafety.children(of: groupRoot)
        let vendorPrefix = bundleID.split(separator: ".").prefix(2).joined(separator: ".")
        var names: [String] = []
        for url in children {
            let name = url.lastPathComponent
            if name.contains(bundleID) || name.lowercased().contains(appName.lowercased().replacingOccurrences(of: " ", with: "")) {
                names.append(name)
                continue
            }
            // A group container likely shared by several apps is only noted when
            // another installed app also names its vendor prefix.
            if !vendorPrefix.isEmpty && name.lowercased().contains(vendorPrefix.lowercased()) {
                names.append(name)
            }
        }
        return Array(names.prefix(8))
    }

    // MARK: Vendor uninstaller

    static func vendorUninstaller(in appURL: URL) -> URL? {
        let fm = FileManager.default
        let candidates = ["Contents/Resources", "Contents/Helpers", "Contents/MacOS", "Contents/Library", ""]
        for relative in candidates {
            let directory = relative.isEmpty ? appURL : appURL.appendingPathComponent(relative, isDirectory: true)
            guard fm.fileExists(atPath: directory.path) else { continue }
            for child in FileSafety.children(of: directory) {
                let name = child.lastPathComponent.lowercased()
                if child.pathExtension.lowercased() == "app" && (name.contains("uninstall") || name.contains("remove")) {
                    return child
                }
            }
        }
        return nil
    }

    // MARK: Leftovers from removed apps

    static func scanRemovedAppLeftovers(
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> ScanReport {
        progress(ScanProgress(fraction: 0.2, message: L("Looking for %@…", L("Leftovers from removed apps"))))
        let options = MaintenanceScanner.Options(includeAliases: false, includeLaunchAgents: false)
        let report = MaintenanceScanner.scan(
            options: options,
            ignoreList: ignoreList,
            progress: { progress($0) },
            cancelled: cancelled
        )
        var items = report.items.filter { $0.category == .leftover }
        // Leftover scans only include confirmed groups here; uncertain items stay
        // visible in Maintenance.
        items = items.filter { !$0.isInformational }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        progress(ScanProgress(fraction: 0.95, message: L("Preparing…")))
        return ScanReport(scannedAt: Date(), items: items, skipped: [], notes: [L("Removed apps leave a receipt only if they were installed by an installer. Fettle confirms a leftover only when an identifier is clearly unowned and appears in two or more standard locations.")], duration: report.duration)
    }
}
