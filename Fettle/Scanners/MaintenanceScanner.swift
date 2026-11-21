import Foundation
import AppKit

enum MaintenanceScanner {
    struct Options: Sendable {
        var includeLeftovers = true
        var includeAliases = true
        var includeLaunchAgents = true
        var includeBrokenPreferences = true
        var extraAppRoots: [URL] = []
        var installedBundleIDsOverride: Set<String>? = nil
    }

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

        if options.includeAliases {
            progress(ScanProgress(fraction: 0.15, message: L("Looking for %@…", L("Broken aliases"))))
            items += scanAliases(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        }
        if cancelled() { return finish(started: started, items: items, skipped: skipped, notes: notes) }

        if options.includeLaunchAgents {
            progress(ScanProgress(fraction: 0.45, message: L("Looking for %@…", L("Invalid startup agents"))))
            items += scanLaunchAgents(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        }
        if cancelled() { return finish(started: started, items: items, skipped: skipped, notes: notes) }

        if options.includeBrokenPreferences {
            progress(ScanProgress(fraction: 0.55, message: L("Looking for %@…", L("Broken preferences"))))
            items += scanBrokenPreferences(ignoreList: ignoreList, skipped: &skipped, cancelled: cancelled)
        }
        if cancelled() { return finish(started: started, items: items, skipped: skipped, notes: notes) }

        if options.includeLeftovers {
            progress(ScanProgress(fraction: 0.65, message: L("Looking for %@…", L("Confirmed leftovers"))))
            items += scanLeftovers(
                options: options,
                ignoreList: ignoreList,
                skipped: &skipped,
                cancelled: cancelled
            )
        }

        notes.append(L("Repair is limited to your own aliases, personal LaunchAgents and confirmed leftovers. System files, live preferences and security settings are never changed."))
        notes.append(L("Only one leftover location was found, so this stays informational."))
        return finish(started: started, items: items, skipped: skipped, notes: notes)
    }

    private static func finish(started: Date, items: [ScanItem], skipped: [SkippedItem], notes: [String]) -> ScanReport {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        return ScanReport(scannedAt: Date(), items: unique, skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started))
    }

    private static var scanRoots: [URL] {
        ["Desktop", "Documents", "Downloads", "Applications", "Movies", "Music", "Pictures"].map {
            AppPaths.home.appendingPathComponent($0, isDirectory: true)
        }
    }

    // MARK: Aliases / symlinks

    static func scanAliases(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        var permissionSkips: [SkippedItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        for root in scanRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    permissionSkips.append(SkippedItem(path: PathDisplay.short(url.path), reason: DiskCleanupScanner.permissionReason(error), category: .brokenAlias))
                    return true
                }
            ) else { continue }
            for case let url as URL in enumerator {
                if cancelled() { return items }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if relative.split(separator: "/").count > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let linkInfo = FileSafety.lstatInfo(url)
                if values?.isDirectory == true && !linkInfo.isSymlink {
                    let name = url.lastPathComponent
                    if name.hasSuffix(".app") || name.hasSuffix(".bundle") || name.hasSuffix(".framework") || name.hasSuffix(".photoslibrary") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if DiskCleanupScanner.isIgnored(url, ignoreList) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .brokenAlias))
                    continue
                }
                let isSymlink = linkInfo.isSymlink
                let isAlias = (values?.isAliasFile ?? false) || url.pathExtension.lowercased() == "alias"
                guard isSymlink || isAlias else { continue }

                var broken = false
                var evidence: [String] = []
                if isSymlink {
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "—"
                    broken = !FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().path)
                    evidence.append(L("This symbolic link points to a target that no longer exists."))
                    evidence.append(L("Target: %@", target))
                } else {
                    if let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]) {
                        broken = !FileManager.default.fileExists(atPath: target.path)
                        evidence.append(L("This alias points to a target that no longer exists."))
                        evidence.append(L("Target: %@", PathDisplay.short(target.path)))
                    } else {
                        broken = true
                        evidence.append(L("This alias points to a target that no longer exists."))
                    }
                }
                guard broken else { continue }
                guard let fingerprint = FileSafety.fingerprint(of: url) else { continue }
                items.append(ScanItem.make(
                    url: url,
                    category: .brokenAlias,
                    size: fingerprint.size,
                    fingerprint: fingerprint,
                    location: PathDisplay.short(url.deletingLastPathComponent().path),
                    detail: evidence.first,
                    evidence: evidence,
                    scope: .maintenance
                ))
            }
        }
        skipped.append(contentsOf: permissionSkips)
        return items
    }

    // MARK: Broken preferences

    /// Builds a property list from each file and asks whether it is valid. Unreadable or invalid files are reported, never
    /// silently deleted.
    static func scanBrokenPreferences(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        let root = AppPaths.preferences
        var examined = 0
        for url in FileSafety.children(of: root) {
            if cancelled() { break }
            guard url.pathExtension.lowercased() == "plist" else { continue }
            if examined >= Rules.Preferences.maxFilesPerScan { break }
            examined += 1

            let name = url.lastPathComponent
            // System-managed preferences are never Fettle's to judge.
            if name.hasPrefix("com.apple.") || name.hasPrefix(".GlobalPreferences") { continue }
            if DiskCleanupScanner.isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .brokenPreference))
                continue
            }
            if FileSafety.isSymbolicLink(url) { continue }
            guard let data = try? Data(contentsOf: url) else {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Permission denied"), category: .brokenPreference))
                continue
            }
            var valid = false
            if !data.isEmpty {
                do {
                    _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    valid = true
                } catch {
                    valid = false
                }
            }
            guard !valid else { continue }
            guard let fingerprint = FileSafety.fingerprint(of: url), !fingerprint.isDirectory else { continue }

            let detail = data.isEmpty
                ? L("This preference file is empty, so its app cannot read any settings from it.")
                : L("This preference file is not a valid property list.")
            items.append(ScanItem.make(
                url: url,
                category: .brokenPreference,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(root.path),
                detail: detail,
                evidence: [detail, L("Unreadable property lists are treated as broken; repair moves this file to the Trash.")],
                appName: name.hasSuffix(".plist") ? String(name.dropLast(6)) : name,
                scope: .maintenance
            ))
        }
        return items
    }

    // MARK: LaunchAgents

    static func scanLaunchAgents(
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var items: [ScanItem] = []
        let root = AppPaths.launchAgents
        for url in FileSafety.children(of: root) {
            if cancelled() { break }
            guard url.pathExtension.lowercased() == "plist" else { continue }
            if DiskCleanupScanner.isIgnored(url, ignoreList) {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .invalidLaunchAgent))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Permission denied"), category: .invalidLaunchAgent))
                continue
            }
            var dictionary: [String: Any]?
            do {
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                dictionary = plist as? [String: Any]
            } catch {
                dictionary = nil
            }
            guard let dictionary else {
                if let fingerprint = FileSafety.fingerprint(of: url) {
                    items.append(ScanItem.make(
                        url: url,
                        category: .invalidLaunchAgent,
                        size: fingerprint.size,
                        fingerprint: fingerprint,
                        location: PathDisplay.short(root.path),
                        detail: L("The definition could not be read, so Fettle leaves it informational."),
                        evidence: [L("The definition could not be read, so Fettle leaves it informational.")],
                        informational: true,
                        scope: .maintenance
                    ))
                }
                continue
            }
            let label = (dictionary["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let workingDirectory = (dictionary["WorkingDirectory"] as? String)
            let program = (dictionary["Program"] as? String)
                ?? ((dictionary["ProgramArguments"] as? [String])?.first)
            var evidence: [String] = []
            var invalid = false
            var informational = false
            if label.isEmpty {
                invalid = true
                evidence.append(L("This startup agent has no valid Label."))
            }
            if let program, !program.isEmpty {
                // A relative Program is joined to WorkingDirectory, then the
                // path is tilde-expanded and standardised. A missing path is
                // broken unless an installed app owns it. The executable bit
                // is never tested.
                var candidate = program
                if !candidate.hasPrefix("/") {
                    if let workingDirectory, !workingDirectory.isEmpty {
                        candidate = (workingDirectory as NSString).appendingPathComponent(candidate)
                    } else {
                        invalid = true
                        evidence.append(L("The program path is not absolute and there is no WorkingDirectory: %@", program))
                    }
                }
                if !invalid {
                    candidate = (candidate as NSString).expandingTildeInPath
                    let resolved = URL(fileURLWithPath: candidate).standardizedFileURL.path
                    if !FileManager.default.fileExists(atPath: resolved) {
                        // Missing is broken unless the path belongs to an
                        // installed app.
                        if let bundle = enclosingAppBundle(resolved), FileManager.default.fileExists(atPath: bundle.path) {
                            informational = true
                            evidence.append(L("The program is missing, but the path belongs to an installed app, so Fettle leaves it alone."))
                            evidence.append(L("Program: %@", resolved))
                        } else {
                            invalid = true
                            evidence.append(L("This startup agent points to a program that no longer exists."))
                            evidence.append(L("Program: %@", resolved))
                        }
                    }
                    // An existing path is not broken, even when it is not
                    // executable.
                }
            } else {
                // No program path at all is broken.
                invalid = true
                evidence.append(L("No program path was declared, so this startup agent cannot start."))
            }
            guard invalid || informational else { continue }
            guard let fingerprint = FileSafety.fingerprint(of: url) else { continue }
            var item = ScanItem.make(
                url: url,
                category: .invalidLaunchAgent,
                size: fingerprint.size,
                fingerprint: fingerprint,
                location: PathDisplay.short(root.path),
                detail: evidence.first,
                evidence: evidence,
                informational: informational,
                scope: .maintenance
            )
            item.appName = label.isEmpty ? url.deletingPathExtension().lastPathComponent : label
            items.append(item)
        }
        return items
    }

    static func enclosingAppBundle(_ path: String) -> URL? {
        guard let marker = path.range(of: Rules.LaunchAgent.appOwnedMarker) else { return nil }
        return URL(fileURLWithPath: String(path[..<marker.lowerBound]) + ".app")
    }

    // MARK: Leftovers

    static func scanLeftovers(
        options: Options,
        ignoreList: [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ScanItem] {
        var leftovers: [String: [URL]] = [:]
        let locations: [(url: URL, normalizer: (String) -> String?)] = [
            (AppPaths.caches, { name in name }),
            (AppPaths.logs, { name in name }),
            (AppPaths.preferences, { name in name.hasSuffix(".plist") ? String(name.dropLast(6)) : nil }),
            (AppPaths.applicationSupport, { name in name }),
            (AppPaths.savedState, { name in name.hasSuffix(".savedState") ? String(name.dropLast(11)) : nil }),
            (AppPaths.containers, { name in name }),
            (AppPaths.webKit, { name in name }),
            (AppPaths.httpStorages, { name in name }),
            // Extra per-bundle roots (see `Rules.Leftovers`).
            (AppPaths.library.appendingPathComponent("Preferences/SDMHelpData/Other", isDirectory: true), { name in name }),
            (AppPaths.applicationSupport.appendingPathComponent("Adobe/AIR/ELS", isDirectory: true), { name in name }),
        ]

        let installed = options.installedBundleIDsOverride ?? installedBundleIDs(extraRoots: options.extraAppRoots)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let ownID = Bundle.main.bundleIdentifier ?? "com.fettle.app"

        for (root, normalizer) in locations {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for url in FileSafety.children(of: root) {
                if cancelled() { break }
                let name = url.lastPathComponent
                guard let identifier = normalizer(name),
                      FileSafety.isBundleIdentifierLike(identifier),
                      !FileSafety.isAppleIdentifier(identifier),
                      identifier != ownID else { continue }
                if DiskCleanupScanner.isIgnored(url, ignoreList) {
                    skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("This folder is on the ignore list."), category: .leftover))
                    continue
                }
                if FileSafety.isSymbolicLink(url) { continue }
                if installed.contains(identifier) || running.contains(identifier) { continue }
                // Apps in subfolders or other places are found through LaunchServices.
                if !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).isEmpty { continue }
                // Keep vendor infrastructure (updaters, helpers, keystone) out of
                // confirmed cleanup, and do not call something a leftover when
                // another app from the same vendor is still installed.
                let vendorPrefix = identifier.split(separator: ".").prefix(2).joined(separator: ".")
                if installed.contains(where: { $0.hasPrefix(vendorPrefix + ".") }) { continue }
                leftovers[identifier, default: []].append(url)
            }
        }

        var items: [ScanItem] = []
        for (identifier, urls) in leftovers.sorted(by: { $0.key < $1.key }) {
            if cancelled() { break }
            let lower = identifier.lowercased()
            let helperLike = ["updater", "update", "helper", "keystone", "crashpad", "xpc", "daemon", "agent", "launcher"].contains { lower.contains($0) }
            let confirmed = urls.count >= 2 && !helperLike
            for url in urls {
                if cancelled() { break }
                guard let fingerprint = FileSafety.fingerprint(of: url) else { continue }
                var evidence: [String] = []
                if confirmed {
                    evidence.append(L("No installed app claims bundle identifier %@, and matching leftovers appear in %d places.", identifier, urls.count))
                } else {
                    evidence.append(L("Only one leftover location was found, so this stays informational."))
                }
                if let other = urls.first(where: { $0 != url }) {
                    evidence.append(L("Also found: %@", PathDisplay.short(other.path)))
                }
                items.append(ScanItem.make(
                    url: url,
                    category: .leftover,
                    size: fingerprint.size,
                    fingerprint: fingerprint,
                    location: PathDisplay.short(url.deletingLastPathComponent().path),
                    detail: confirmed
                        ? L("No installed app claims bundle identifier %@, and matching leftovers appear in %d places.", identifier, urls.count)
                        : L("Only one leftover location was found, so this stays informational."),
                    evidence: evidence,
                    bundleID: identifier,
                    appName: identifier,
                    informational: !confirmed,
                    isAppData: url.path.hasPrefix(AppPaths.containers.path + "/") || url.path.hasPrefix(AppPaths.applicationSupport.path + "/"),
                    scope: .maintenance
                ))
            }
        }
        return items
    }

    static func installedBundleIDs(extraRoots: [URL]) -> Set<String> {
        var roots: [URL]
        if let override = ProcessInfo.processInfo.environment["FETTLE_APPS_ROOT"], !override.isEmpty {
            roots = [URL(fileURLWithPath: override, isDirectory: true)]
        } else {
            roots = [URL(fileURLWithPath: "/Applications"), AppPaths.applications]
        }
        roots += extraRoots
        var ids = Set<String>()
        for root in roots {
            for url in FileSafety.children(of: root) where url.pathExtension.lowercased() == "app" {
                if let info = FileSafety.appBundleInfo(at: url) {
                    ids.insert(info.id)
                }
            }
        }
        // Running apps count as installed wherever they live. Apps stored
        // elsewhere are checked per identifier through LaunchServices in scan.
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id) }
        }
        return ids
    }
}
