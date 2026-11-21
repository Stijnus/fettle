import Foundation

enum DiskCleanupScanner {
    struct Options: Sendable {
        var includeTrash = true
        var externalVolume: URL? = nil
        var includeTemporary = true
    }

    static let logAgeDays: Double = 7
    static let crashAgeDays: Double = 3
    static let temporaryAgeDays: Double = 3

    static func scan(
        options: Options = Options(),
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> ScanReport {
        let started = Date()
        var items: [ScanItem] = []
        var skipped: [SkippedItem] = []
        var notes: [String] = []

        if let volume = options.externalVolume {
            scanExternal(volume: volume, ignoreList: ignoreList, items: &items, skipped: &skipped, notes: &notes, progress: progress, cancelled: cancelled)
        } else {
            let caches = scanCaches(ignoreList: ignoreList, skipped: &skipped, progress: progress, cancelled: cancelled)
            items += caches
            progress(ScanProgress(fraction: 0.35, message: L("Scanning %@…", L("Logs"))))
            if cancelled() { return report(started: started, items: items, skipped: skipped, notes: notes) }
            items += scanLogs(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)

            progress(ScanProgress(fraction: 0.5, message: L("Scanning %@…", L("Crash reports"))))
            if cancelled() { return report(started: started, items: items, skipped: skipped, notes: notes) }
            items += scanCrashReports(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)

            if options.includeTemporary {
                progress(ScanProgress(fraction: 0.62, message: L("Scanning %@…", L("Temporary files"))))
                if cancelled() { return report(started: started, items: items, skipped: skipped, notes: notes) }
                items += scanTemporary(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            }

            if options.includeTrash {
                progress(ScanProgress(fraction: 0.75, message: L("Scanning %@…", L("Trash"))))
                if cancelled() { return report(started: started, items: items, skipped: skipped, notes: notes) }
                items += scanTrash(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            }

            // Record protected areas that were deliberately not traversed.
            let backups = AppPaths.applicationSupport.appendingPathComponent("MobileSync/Backup", isDirectory: true)
            if FileManager.default.fileExists(atPath: backups.path) {
                skipped.append(SkippedItem(path: PathDisplay.short(backups.path), reason: L("Backups"), category: nil))
            }
            for personal in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"] {
                let url = AppPaths.home.appendingPathComponent(personal, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Personal documents"), category: nil))
                }
            }
            notes.append(L("This scan is limited to your own cache, log, crash report and temporary file folders. It does not read other users' data."))
        }

        progress(ScanProgress(fraction: 0.95, message: L("Preparing…")))
        items.sort { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return report(started: started, items: items, skipped: skipped, notes: notes)
    }

    private static func report(started: Date, items: [ScanItem], skipped: [SkippedItem], notes: [String]) -> ScanReport {
        ScanReport(scannedAt: Date(), items: dedupe(items), skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started))
    }

    private static func dedupe(_ items: [ScanItem]) -> [ScanItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func categoryOrder(_ category: ItemCategory) -> Int {
        switch category {
        case .cache: return 0
        case .logs: return 1
        case .crashReports: return 2
        case .temporary: return 3
        case .largeFile: return 4
        case .trash: return 5
        default: return 9
        }
    }

    // MARK: User caches

    static func scanCaches(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        let root = AppPaths.caches
        let children = FileSafety.children(of: root)
        var items: [ScanItem] = []
        let total = max(1, children.count)
        for (index, url) in children.enumerated() {
            if cancelled() { break }
            progress(ScanProgress(fraction: 0.05 + 0.3 * Double(index) / Double(total), message: L("Scanning caches…")))
            let name = url.lastPathComponent
            if name == "TemporaryItems" { continue }
            if name == "com.fettle.app" || name.hasPrefix("com.fettle.") { continue }
            if name == "CloudKit" { continue }
            if isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .cache))
                continue
            }
            if FileSafety.isSymbolicLink(url) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .cache))
                continue
            }
            guard let fingerprint = FileSafety.fingerprint(of: url), fingerprint.size > 0 else { continue }
            items.append(ScanItem.make(
                url: url,
                category: .cache,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(root.path),
                detail: L("Regenerated automatically by macOS or the app."),
                scope: .diskCleanup
            ))
        }
        return items
    }

    // MARK: Logs

    static func scanLogs(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        let root = AppPaths.logs
        var items: [ScanItem] = []
        var permissionSkips: [SkippedItem] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { url, error in
                permissionSkips.append(SkippedItem(path: PathDisplay.short(url.path), reason: permissionReason(error), category: .logs))
                return true
            }
        ) else { return [] }

        for case let url as URL in enumerator {
            if cancelled() || items.count > 2_000 { break }
            if url.path.contains("/DiagnosticReports") { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if url.lastPathComponent.hasSuffix(".app") { enumerator.skipDescendants() }
                continue
            }
            guard let modified = values?.contentModificationDate,
                  Date().timeIntervalSince(modified) > logAgeDays * 86_400 else { continue }
            if isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .logs))
                continue
            }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            // The fingerprint uses the logical size, as FileSafety.fingerprint(of:)
            // does at validation; the allocated size is only for display.
            let fingerprint = FileFingerprint(size: Int64(values?.fileSize ?? 0), modified: modified, isDirectory: false)
            items.append(ScanItem.make(
                url: url,
                category: .logs,
                size: size,
                fingerprint: fingerprint,
                location: PathDisplay.short(url.deletingLastPathComponent().path),
                detail: L("Older than 7 days"),
                scope: .diskCleanup
            ))
        }
        skipped.append(contentsOf: permissionSkips)
        return items
    }

    // MARK: Crash reports

    static func scanCrashReports(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        let roots = [AppPaths.diagnosticReports, AppPaths.crashReporter]
        for root in roots {
            for url in FileSafety.children(of: root) {
                if cancelled() { break }
                if isIgnored(url, ignoreList) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .crashReports))
                    continue
                }
                if FileSafety.isSymbolicLink(url) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .crashReports))
                    continue
                }
                guard FileSafety.isOlderThan(url, days: crashAgeDays),
                      let fingerprint = FileSafety.fingerprint(of: url), fingerprint.size > 0 else { continue }
                items.append(ScanItem.make(
                    url: url,
                    category: .crashReports,
                    size: fingerprint.size,
                    fingerprint: fingerprint,
                    location: PathDisplay.short(root.path),
                    detail: L("Older than %d days", Int(crashAgeDays)),
                    scope: .diskCleanup
                ))
            }
        }
        return items
    }

    // MARK: Temporary files

    static func scanTemporary(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        let temporaryRoots = [AppPaths.temporaryItems, AppPaths.tmpDirectory]
        let interestingExtensions: Set<String> = ["tmp", "temp", "partial", "crdownload", "download"]
        for root in temporaryRoots {
            for url in FileSafety.children(of: root) {
                if cancelled() { break }
                let name = url.lastPathComponent
                if name.hasPrefix("fettle-") { continue }
                if isIgnored(url, ignoreList) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .temporary))
                    continue
                }
                if FileSafety.isSymbolicLink(url) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .temporary))
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let isRecognised = root == AppPaths.temporaryItems || interestingExtensions.contains(ext)
                guard isRecognised, FileSafety.isOlderThan(url, days: temporaryAgeDays) else { continue }
                guard let fingerprint = FileSafety.fingerprint(of: url), fingerprint.size > 0 else { continue }
                items.append(ScanItem.make(
                    url: url,
                    category: .temporary,
                    size: fingerprint.size,
                    fingerprint: fingerprint,
                    location: PathDisplay.short(root.path),
                    detail: L("Older than 1 day"),
                    scope: .diskCleanup
                ))
            }
        }
        return items
    }

    // MARK: Trash

    static func scanTrash(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        scanTrash(at: AppPaths.trash, ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
    }

    static func scanTrash(
        at root: URL,
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        for url in FileSafety.children(of: root) {
            if cancelled() { break }
            if isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .trash))
                continue
            }
            if FileSafety.isSymbolicLink(url) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .trash))
                continue
            }
            guard let fingerprint = FileSafety.fingerprint(of: url), fingerprint.size > 0 else { continue }
            items.append(ScanItem.make(
                url: url,
                category: .trash,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(root.path),
                detail: L("Emptying the Trash is its own confirmed action and is never part of routine cleanup."),
                scope: .trash
            ))
        }
        return items
    }

    // MARK: External drives

    static func scanExternal(
        volume: URL,
        ignoreList: [String],
        items: inout [ScanItem],
        skipped: inout [SkippedItem],
        notes: inout [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) {
        progress(ScanProgress(fraction: 0.15, message: L("Scanning external drive…")))
        let trashes = volume.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
        var trashItems: [ScanItem] = []
        if FileManager.default.fileExists(atPath: trashes.path) {
            trashItems = scanTrash(at: trashes, ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
            for index in trashItems.indices {
                trashItems[index].id = "external-trash|\(trashItems[index].path)"
                trashItems[index].category = .trash
                trashItems[index].scope = .trash
                trashItems[index].isExternal = true
            }
        }
        items += trashItems

        progress(ScanProgress(fraction: 0.55, message: L("Scanning %@…", L("Temporary files"))))
        let temporary = volume.appendingPathComponent(".TemporaryItems", isDirectory: true)
        if FileManager.default.fileExists(atPath: temporary.path) {
            var tempSkipped: [SkippedItem] = []
            var tempItems = scanTemporary(at: temporary, ignoreList: ignoreList, skipped: &tempSkipped, cancelled: cancelled)
            for index in tempItems.indices {
                tempItems[index].id = "external-temp|\(tempItems[index].path)"
                tempItems[index].isExternal = true
            }
            items += tempItems
            skipped += tempSkipped
        }
        notes.append(L("Items on an external drive are never selected automatically. Review the volume, Trash and temporary files before cleaning."))
        notes.append(L("External volume details"))
    }

    static func scanTemporary(
        at root: URL,
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        for url in FileSafety.children(of: root) {
            if cancelled() { break }
            if isIgnored(url, ignoreList) { continue }
            if FileSafety.isSymbolicLink(url) { skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .temporary)); continue }
            guard FileSafety.isOlderThan(url, days: temporaryAgeDays), let fingerprint = FileSafety.fingerprint(of: url), fingerprint.size > 0 else { continue }
            items.append(ScanItem.make(
                url: url,
                category: .temporary,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(root.path),
                detail: L("Older than 1 day"),
                scope: .diskCleanup
            ))
        }
        return items
    }

    // MARK: Large files

    static func scanLargeFiles(
        root: URL,
        minimumSize: Int64,
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> ScanReport {
        let started = Date()
        var items: [ScanItem] = []
        var skipped: [SkippedItem] = []
        var permissionSkips: [SkippedItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                permissionSkips.append(SkippedItem(path: PathDisplay.short(url.path), reason: permissionReason(error), category: .largeFile))
                return true
            }
        ) else {
            return ScanReport(scannedAt: Date(), items: [], skipped: [], notes: [L("No large files found in this folder.")], duration: 0)
        }

        var seen = 0
        for case let url as URL in enumerator {
            if cancelled() || items.count >= 500 { break }
            seen += 1
            if seen % 250 == 0 {
                progress(ScanProgress(fraction: min(0.9, Double(seen) / 50_000), message: L("Scanning %@…", root.lastPathComponent)))
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Symbolic links"), category: .largeFile))
                continue
            }
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                let protected: Set<String> = ["Library", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", "Backups.backupdb"]
                if name.hasSuffix(".app") || name.hasSuffix(".bundle") || name.hasSuffix(".framework") || name.hasSuffix(".photoslibrary") || name.hasSuffix(".musiclibrary") {
                    enumerator.skipDescendants()
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("App resources"), category: .largeFile))
                    continue
                }
                if protected.contains(name) || (root.path == AppPaths.home.path && name == "Library") {
                    enumerator.skipDescendants()
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("System files are out of scope"), category: .largeFile))
                    continue
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .largeFile))
                continue
            }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            guard size >= minimumSize else { continue }
            // Logical size, matching FileSafety.fingerprint(of:) at validation.
            let fp = FileFingerprint(size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate, isDirectory: false)
            items.append(ScanItem.make(
                url: url,
                category: .largeFile,
                size: size,
                fingerprint: fp,
                location: PathDisplay.short(url.deletingLastPathComponent().path),
                detail: L("Large files in %@", root.lastPathComponent),
                scope: .diskCleanup
            ))
        }
        skipped.append(contentsOf: permissionSkips)
        items.sort { $0.size > $1.size }
        progress(ScanProgress(fraction: 0.95, message: L("Preparing…")))
        return ScanReport(scannedAt: Date(), items: items, skipped: skipped, notes: [L("Large files in %@", root.lastPathComponent)], duration: Date().timeIntervalSince(started))
    }

    // MARK: Helpers

    static func isIgnored(_ url: URL, _ ignoreList: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return ignoreList.contains { ignored in
            let entry = (ignored as NSString).expandingTildeInPath
            return path == entry || path.hasPrefix(entry + "/")
        }
    }

    static func permissionReason(_ error: Error?) -> String {
        let nsError = error as NSError?
        if nsError?.code == NSFileReadNoPermissionError || nsError?.code == 257 {
            return L("Permission denied")
        }
        return nsError?.localizedDescription ?? L("Permission denied")
    }
}
