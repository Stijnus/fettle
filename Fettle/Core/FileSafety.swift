import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

enum SafetyError: Error, Equatable {
    case outsideScope
    case protectedPath
    case changed
    case missing
    case symbolicLink
    case ignored
    case running
    case accessDenied(String)
    case failed(String)

    var localizedDescription: String {
        switch self {
        case .outsideScope: return L("Outside approved folders")
        case .protectedPath: return L("This location is protected")
        case .changed: return L("Changed since scan")
        case .missing: return L("Already gone")
        case .symbolicLink: return L("Symbolic links")
        case .ignored: return L("This folder is on the ignore list.")
        case .running: return L("The app is still running.")
        case .accessDenied(let message): return message.isEmpty ? L("Permission denied") : message
        case .failed(let message): return message
        }
    }
}

struct VolumeInfo: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    var url: URL
    var name: String
    var total: Int64
    var available: Int64
    var isExternal: Bool
    var isRemovable: Bool

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum FileSafety {
    // MARK: Sizes

    /// lstat-based existence check so broken symbolic links are still seen.
    static func lstatInfo(_ url: URL) -> (exists: Bool, isSymlink: Bool, size: Int64, modified: Date?, isDirectory: Bool) {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard result == 0 else { return (false, false, 0, nil, false) }
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        let isDir = (info.st_mode & S_IFMT) == S_IFDIR
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (true, isLink, Int64(info.st_size), modified, isDir)
    }

    static func existsIncludingSymlink(_ url: URL) -> Bool {
        lstatInfo(url).exists
    }

    static func fingerprint(of url: URL) -> FileFingerprint? {
        let info = lstatInfo(url)
        guard info.exists else { return nil }
        if info.isSymlink {
            return FileFingerprint(size: info.size, modified: info.modified, isDirectory: false, childCount: nil)
        }
        let modified = info.modified
        if info.isDirectory {
            let measured = directorySize(url)
            return FileFingerprint(size: measured.size, modified: modified, isDirectory: true, childCount: measured.count)
        }
        return FileFingerprint(size: info.size, modified: modified, isDirectory: false, childCount: nil)
    }

    /// Walks a directory without following symbolic links. Returns allocated bytes
    /// and the number of regular files and folders seen.
    static func directorySize(_ url: URL, deadline: TimeInterval = 25) -> (size: Int64, count: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var count = 0
        let start = Date()
        for case let child as URL in enumerator {
            if Date().timeIntervalSince(start) > deadline { break }
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                count += 1
            } else if values?.isDirectory == true {
                count += 1
            }
            if count > 500_000 { break }
        }
        return (total, count)
    }

    static func allocatedSize(of url: URL) -> Int64 {
        if let fingerprint = fingerprint(of: url) { return fingerprint.size }
        return 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        lstatInfo(url).isSymlink
    }

    // MARK: Volumes

    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0))
            guard total > 0 else { return nil }
            let isInternal = values.volumeIsInternal ?? true
            return VolumeInfo(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: total,
                available: available,
                isExternal: !isInternal,
                isRemovable: values.volumeIsRemovable ?? false || (values.volumeIsEjectable ?? false)
            )
        }
        .sorted { $0.isExternal == $1.isExternal ? $0.name < $1.name : !$0.isExternal }
    }

    static func rootVolume() -> VolumeInfo? {
        volumes().first { $0.url.path == "/" } ?? volumes().first
    }

    static func freeSpace(at url: URL = URL(fileURLWithPath: "/")) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            return Int64(values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0))
        }
        return 0
    }

    static func volumeInfo(for url: URL) -> VolumeInfo? {
        // A mount notification passes the volume's own root, so match the root
        // itself as well as paths inside it. The longest match wins, so a
        // volume under /Volumes is never mistaken for the startup disk.
        let path = url.standardizedFileURL.path
        return volumes()
            .filter { volume in
                let root = volume.url.standardizedFileURL.path
                return root == "/" || path == root || path.hasPrefix(root + "/")
            }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }

    // MARK: Scope

    static func allowedRoots(for scope: ActionScope, extra: [URL] = []) -> [URL] {
        var roots: [URL] = extra
        switch scope {
        case .none:
            return []
        case .diskCleanup:
            roots += [AppPaths.caches, AppPaths.logs, AppPaths.crashReporter, AppPaths.temporaryItems, AppPaths.tmpDirectory]
        case .trash:
            roots += [AppPaths.trash]
        case .maintenance:
            roots += [AppPaths.home, AppPaths.launchAgents, AppPaths.caches, AppPaths.logs, AppPaths.applicationSupport, AppPaths.preferences, AppPaths.savedState]
        case .uninstaller:
            roots += [URL(fileURLWithPath: "/Applications"), AppPaths.applications, AppPaths.caches, AppPaths.logs, AppPaths.applicationSupport, AppPaths.preferences, AppPaths.savedState, AppPaths.containers, AppPaths.webKit, AppPaths.httpStorages, AppPaths.cookies, AppPaths.launchAgents]
        case .privacy:
            roots += [AppPaths.safari, AppPaths.safariCaches, AppPaths.caches, AppPaths.applicationSupport, AppPaths.cookies, AppPaths.webKit, AppPaths.httpStorages, AppPaths.containers, AppPaths.sharedFileLists]
        case .permanentDelete:
            roots += [AppPaths.home, URL(fileURLWithPath: "/Volumes"), URL(fileURLWithPath: "/Users/Shared")]
        }
        return roots.map { $0.standardizedFileURL }
    }

    private static let forbiddenPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/dev", "/cores", "/private/etc", "/private/var/db",
        "/Library", "/Applications", "/Library/Keychains", "/System/Volumes"
    ]

    private static let forbiddenUserPrefixes: [String] = [
        "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Safari/Databases",
        "Library/Safari/Bookmarks.plist",
        "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/com.apple.sharedfilelist", "Library/IdentityServices",
        "Library/PersonalizationPortrait", "Library/Suggestions", "Library/Accounts"
    ]

    static func isPathAllowed(_ url: URL, scope: ActionScope, extraRoots: [URL] = []) -> Bool {
        let rawPath = url.standardizedFileURL.path
        guard rawPath != "/" else { return false }
        let roots = allowedRoots(for: scope, extra: extraRoots)
        let canonicalRoots = roots.map { canonicalPath($0.path) }
        // Keep the last path component intact so a symlink is judged as a link,
        // not as its target; canonicalise the parent chain instead.
        let path = canonicalPathPreservingLastComponent(rawPath)
        guard canonicalRoots.contains(where: { isInside(path, root: $0) }) else { return false }

        let parent = canonicalPath(url.deletingLastPathComponent().path)
        guard canonicalRoots.contains(where: { isInside(parent, root: $0) }) else {
            return false
        }

        if scope != .uninstaller && scope != .permanentDelete {
            for forbidden in forbiddenPrefixes where isInside(path, root: canonicalPath(forbidden)) { return false }
        }
        let home = canonicalPath(AppPaths.home.path)
        for relative in forbiddenUserPrefixes {
            let forbidden = home + "/" + relative
            if isInside(path, root: forbidden) { return false }
        }
        // Never touch our own app bundle or its data.
        let own = canonicalPath(Bundle.main.bundleURL.standardizedFileURL.path)
        if isInside(path, root: own) { return false }
        if path == home { return false }
        if scope == .permanentDelete {
            // Applications may be removed through the Uninstaller, never through the shredder.
            if isInside(path, root: "/Applications") { return false }
            if path == "/Users" || path == "/Volumes" || path == "/Users/Shared" { return false }
            if path.hasPrefix("/Volumes/") && path.split(separator: "/").count <= 2 { return false }
        }
        return true
    }

    /// realpath(3) resolves /var -> /private/var, which Foundation's
    /// resolvingSymlinksInPath leaves alone at the volume root.
    static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if path.withCString({ realpath($0, &buffer) }) != nil {
            return String(cString: buffer)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        if parent == path { return path }
        let canonicalParent = canonicalPath(parent)
        return name.isEmpty ? canonicalParent : canonicalParent + "/" + name
    }

    static func canonicalPathPreservingLastComponent(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if path == "/" { return "/" }
        let parent = canonicalPath(url.deletingLastPathComponent().path)
        return parent.hasSuffix("/") ? parent + url.lastPathComponent : parent + "/" + url.lastPathComponent
    }

    static func isInside(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path.hasPrefix(normalizedRoot + "/")
    }

    static func validate(_ item: ScanItem, scope: ActionScope, extraRoots: [URL] = [], ignoreList: [String] = []) -> SafetyError? {
        if item.isProtected { return .protectedPath }
        if item.isInformational { return .protectedPath }
        let url = item.url
        for ignored in ignoreList {
            let normalized = (ignored as NSString).expandingTildeInPath
            if item.path == normalized || item.path.hasPrefix(normalized + "/") { return .ignored }
        }
        guard isPathAllowed(url, scope: scope, extraRoots: extraRoots) else { return .outsideScope }
        guard existsIncludingSymlink(url) else { return .missing }
        if isSymbolicLink(url) && scope != .permanentDelete && scope != .maintenance { return .symbolicLink }
        if item.category == .app && SystemActions.isRunning(appAt: url) { return .running }
        guard let current = fingerprint(of: url) else { return .accessDenied(L("Permission denied")) }
        // App bundles are large and their metadata changes whenever the app
        // updates. Existence, scope and the running check are the meaningful
        // safeguards for moving a whole bundle; comparing a recursive size
        // would make every launch look like a change.
        if item.category == .app {
            if let before = item.fingerprint.modified, let after = current.modified, after.timeIntervalSince(before) > 86_400 {
                return .changed
            }
            return nil
        }
        if current.size != item.fingerprint.size { return .changed }
        if let before = item.fingerprint.modified, let after = current.modified, abs(before.timeIntervalSince(after)) > 0.5 {
            return .changed
        }
        if let before = item.fingerprint.childCount, let after = current.childCount, before != after {
            return .changed
        }
        return nil
    }

    // MARK: Trash and delete

    static func moveToTrash(_ items: [ScanItem], scope: ActionScope, extraRoots: [URL] = [], ignoreList: [String] = [], progress: ((Int, Int) -> Void)? = nil) -> OperationOutcome {
        var results: [ItemResult] = []
        let spaceURL = volumeInfo(for: items.first?.url ?? URL(fileURLWithPath: "/"))?.url ?? URL(fileURLWithPath: "/")
        let before = freeSpace(at: spaceURL)
        for (index, item) in items.enumerated() {
            progress?(index, items.count)
            let itemScope: ActionScope = item.scope == .none ? scope : item.scope
            if let error = validate(item, scope: itemScope, extraRoots: extraRoots, ignoreList: ignoreList) {
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: error.localizedDescription, bytes: 0))
                continue
            }
            do {
                if ProcessInfo.processInfo.environment["FETTLE_TRASH_DIR"] != nil {
                    try? FileManager.default.createDirectory(at: AppPaths.trash, withIntermediateDirectories: true)
                    var destination = AppPaths.trash.appendingPathComponent(item.url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        destination = AppPaths.trash.appendingPathComponent("\(UUID().uuidString)-\(item.url.lastPathComponent)")
                    }
                    try FileManager.default.moveItem(at: item.url, to: destination)
                } else {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                }
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: true, message: nil, bytes: item.size))
            } catch {
                let nsError = error as NSError
                let message = nsError.code == NSFileWriteNoPermissionError ? L("Permission denied") : nsError.localizedDescription
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: false, message: message, bytes: 0))
            }
        }
        let after = freeSpace(at: spaceURL)
        let outcome = OperationOutcome(
            title: L("Moved to Trash"),
            message: L("%d items moved to the Trash.", results.filter { $0.success }.count),
            results: results,
            bytes: results.filter { $0.success }.reduce(0) { $0 + $1.bytes },
            freeSpaceBefore: before,
            freeSpaceAfter: after
        )
        return outcome
    }

    /// Permanently erases the reviewed Trash items, and only those. Each one is
    /// revalidated against its scan, so anything trashed after the review stays.
    /// This is a separate action from moving items there, and is only ever
    /// called after confirmation.
    static func emptyTrash(_ items: [ScanItem], ignoreList: [String] = [], progress: ((Int, Int) -> Void)? = nil) -> OperationOutcome {
        let spaceURL = volumeInfo(for: AppPaths.trash)?.url ?? URL(fileURLWithPath: "/")
        let before = freeSpace(at: spaceURL)
        let fm = FileManager.default
        var results: [ItemResult] = []
        for (index, item) in items.enumerated() {
            progress?(index, items.count)
            let url = item.url
            let path = item.path
            if let error = validate(item, scope: .trash, ignoreList: ignoreList) {
                results.append(ItemResult(path: path, name: item.name, category: .trash, success: false, skipped: true, message: error.localizedDescription, bytes: 0))
                continue
            }
            let size = allocatedSize(of: url)
            do {
                try fm.removeItem(at: url)
                results.append(ItemResult(path: path, name: url.lastPathComponent, category: .trash, success: true, bytes: size))
            } catch {
                results.append(ItemResult(path: path, name: url.lastPathComponent, category: .trash, success: false, skipped: false, message: (error as NSError).localizedDescription, bytes: 0))
            }
        }
        let after = freeSpace(at: spaceURL)
        return OperationOutcome(
            title: L("Trash emptied"),
            message: L("%d items were permanently erased.", results.filter { $0.success }.count),
            results: results,
            bytes: results.filter { $0.success }.reduce(0) { $0 + $1.bytes },
            freeSpaceBefore: before,
            freeSpaceAfter: after
        )
    }

    static func permanentlyDelete(_ items: [ScanItem], progress: ((Int, Int) -> Void)? = nil) -> OperationOutcome {
        let spaceURL = volumeInfo(for: items.first?.url ?? URL(fileURLWithPath: "/"))?.url ?? URL(fileURLWithPath: "/")
        let before = freeSpace(at: spaceURL)
        var results: [ItemResult] = []
        for (index, item) in items.enumerated() {
            progress?(index, items.count)
            if let error = validate(item, scope: .permanentDelete) {
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: true, message: error.localizedDescription, bytes: 0))
                continue
            }
            let url = item.url
            do {
                try FileManager.default.removeItem(at: url)
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: true, bytes: item.size))
            } catch {
                results.append(ItemResult(path: item.path, name: item.name, category: item.category, success: false, skipped: false, message: (error as NSError).localizedDescription, bytes: 0))
            }
        }
        let after = freeSpace(at: spaceURL)
        return OperationOutcome(
            title: L("Deleted permanently"),
            message: L("%d items were permanently deleted.", results.filter { $0.success }.count),
            results: results,
            bytes: results.filter { $0.success }.reduce(0) { $0 + $1.bytes },
            freeSpaceBefore: before,
            freeSpaceAfter: after
        )
    }

    // MARK: Discovery helpers

    static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey], options: [])) ?? []
    }

    static func isOlderThan(_ url: URL, days: Double) -> Bool {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) else { return false }
        return Date().timeIntervalSince(date) > days * 86_400
    }

    static func isBundleIdentifierLike(_ name: String) -> Bool {
        let pattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+){2,}$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func isAppleIdentifier(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") || name.hasPrefix("com.apple")
    }

    static func appBundleInfo(at url: URL) -> (id: String, name: String, version: String)? {
        guard let bundle = Bundle(url: url) else { return nil }
        let id = bundle.bundleIdentifier ?? ""
        guard !id.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "—"
        return (id, name, version)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
