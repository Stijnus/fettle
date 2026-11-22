import Foundation
import AppKit
import CryptoKit

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

struct TestRunner {
    var results: [[String: Any]] = []
    var failures = 0

    mutating func test(_ name: String, _ body: () throws -> String) {
        do {
            let detail = try body()
            results.append(["name": name, "passed": true, "detail": detail])
        } catch {
            failures += 1
            let detail: String
            if let failure = error as? TestFailure { detail = failure.description } else { detail = error.localizedDescription }
            results.append(["name": name, "passed": false, "detail": detail])
        }
    }
}

enum SelfTest {
    static func runAndExit() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fettle-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("FETTLE_HOME", root.path, 1)
        setenv("FETTLE_TRASH_DIR", root.appendingPathComponent(".Trash").path, 1)
        setenv("FETTLE_TMP_DIR", root.appendingPathComponent("tmp").path, 1)
        setenv("FETTLE_APPS_ROOT", root.appendingPathComponent("Applications").path, 1)

        var runner = TestRunner()
        do {
            try Fixture.build(home: root)
            runTests(runner: &runner, home: root)
        } catch {
            runner.failures += 1
            runner.results.append(["name": "fixture", "passed": false, "detail": "\(error)"])
        }

        let outputPath: String
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-output"), index + 1 < CommandLine.arguments.count {
            outputPath = CommandLine.arguments[index + 1]
        } else {
            outputPath = NSTemporaryDirectory() + "fettle-selftest.json"
        }
        let summary: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "home": root.path,
            "passed": runner.failures == 0,
            "failures": runner.failures,
            "results": runner.results
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        for result in runner.results {
            let passed = result["passed"] as? Bool ?? false
            print("\(passed ? "PASS" : "FAIL") \(result["name"] ?? "")\(passed ? "" : " — \(result["detail"] ?? "")")")
        }
        print("Fettle self-test: \(runner.failures == 0 ? "all passed" : "\(runner.failures) failed") — \(outputPath)")
        if ProcessInfo.processInfo.environment["FETTLE_KEEP"] == nil {
            try? FileManager.default.removeItem(at: root)
        }
        exit(runner.failures == 0 ? 0 : 1)
    }

    static func runTests(runner: inout TestRunner, home: URL) {
        let paths = HomePaths(home: home)

        runner.test("disk scan finds safe categories and keeps Trash separate") {
            let report = DiskCleanupScanner.scan(ignoreList: [], progress: { _ in }, cancelled: { false })
            try expect(report.items.contains { $0.category == .cache }, "cache item missing")
            try expect(report.items.contains { $0.category == .logs }, "old log missing")
            try expect(report.items.contains { $0.category == .crashReports }, "old crash report missing")
            try expect(!report.items.contains { $0.name == "new.ips" }, "new crash report should be kept")
            try expect(report.items.contains { $0.category == .trash }, "trash item missing")
            try expect(report.items.filter { $0.category == .trash }.allSatisfy { $0.scope == .trash }, "trash scope")
            try expect(report.skipped.contains { $0.reason == L("Backups") }, "backup skip reason missing")
            return "\(report.items.count) items, \(report.skipped.count) skipped"
        }

        runner.test("ignore list excludes a cache and is persisted") {
            let cache = paths.home.appendingPathComponent("Library/Caches/com.example.cache", isDirectory: true)
            let storeURL = paths.home.appendingPathComponent("Library/Application Support/Fettle/test-ignore.json")
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var skipped: [SkippedItem] = []
            let items = DiskCleanupScanner.scanCaches(ignoreList: [cache.path], skipped: &skipped, progress: { _ in }, cancelled: { false })
            try expect(!items.contains { $0.path == cache.path }, "ignored cache was scanned")
            try expect(skipped.contains { $0.reason == L("This folder is on the ignore list.") }, "ignore skip missing")
            try MainActor.assumeIsolated {
                let store = IgnoreListStore(fileURL: storeURL)
                store.add(cache)
                let reloaded = IgnoreListStore(fileURL: storeURL)
                try expect(reloaded.contains(cache), "ignore list did not persist")
            }
            return "excluded and persisted"
        }

        runner.test("scan cancellation is safe and returns partial data") {
            let report = DiskCleanupScanner.scan(ignoreList: [], progress: { _ in }, cancelled: { true })
            try expect(report.scannedAt.timeIntervalSinceNow > -10, "report timestamp invalid")
            return "cancelled without errors"
        }

        runner.test("changed files are skipped at action time") {
            let file = paths.home.appendingPathComponent("Library/Caches/com.change/file.bin")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: file)
            let fp = FileSafety.fingerprint(of: file)!
            let item = ScanItem.make(url: file, category: .cache, size: fp.size, fingerprint: fp, location: "cache", scope: .diskCleanup)
            try Data("much longer content".utf8).write(to: file)
            let outcome = FileSafety.moveToTrash([item], scope: .diskCleanup, ignoreList: [])
            let current = FileSafety.fingerprint(of: file)
            try expect(outcome.skippedCount == 1, "changed file was not skipped (before=\(fp.size), after=\(current?.size ?? -1), results=\(outcome.results.map { $0.success }))")
            try expect(FileManager.default.fileExists(atPath: file.path), "changed file was moved")
            return "skipped as changed"
        }

        runner.test("outside-scope paths are refused") {
            let file = paths.home.appendingPathComponent("Documents/keep.txt")
            let fp = FileSafety.fingerprint(of: file)!
            let item = ScanItem.make(url: file, category: .cache, size: fp.size, fingerprint: fp, location: "documents", scope: .diskCleanup)
            try expect(FileSafety.validate(item, scope: .diskCleanup) == .outsideScope, "document was considered cleanable")
            let outcome = FileSafety.moveToTrash([item], scope: .diskCleanup, ignoreList: [])
            try expect(outcome.skippedCount == 1, "document was not skipped")
            try expect(FileManager.default.fileExists(atPath: file.path), "document was removed")
            return "refused"
        }

        runner.test("moving to Trash and emptying Trash are separate") {
            let cache = paths.home.appendingPathComponent("Library/Caches/com.example.cache", isDirectory: true)
            let fp = FileSafety.fingerprint(of: cache)!
            let item = ScanItem.make(url: cache, category: .cache, size: fp.size, fingerprint: fp, location: "Caches", scope: .diskCleanup)
            let outcome = FileSafety.moveToTrash([item], scope: .diskCleanup, ignoreList: [])
            try expect(outcome.successCount == 1, "cache was not moved: \(outcome.results.first?.message ?? "")")
            try expect(!FileManager.default.fileExists(atPath: cache.path), "cache still exists")
            try expect((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.trash.path).count) ?? 0 > 0, "test Trash is empty")
            var trashSkipped: [SkippedItem] = []
            let reviewed = DiskCleanupScanner.scanTrash(ignoreList: [], skipped: &trashSkipped, cancelled: { false })
            let emptied = FileSafety.emptyTrash(reviewed)
            try expect(emptied.successCount > 0, "Trash was not emptied")
            return "moved and emptied"
        }

        runner.test("broken symlink can be repaired without touching its target") {
            let link = paths.home.appendingPathComponent("Desktop/Broken Link")
            let fp = FileSafety.fingerprint(of: link)!
            let item = ScanItem.make(url: link, category: .brokenAlias, size: fp.size, fingerprint: fp, location: "Desktop", scope: .maintenance)
            let outcome = FileSafety.moveToTrash([item], scope: .maintenance, ignoreList: [])
            try expect(outcome.successCount == 1, "broken symlink was not moved: \(outcome.results.first?.message ?? "")")
            try expect(!FileSafety.existsIncludingSymlink(link), "link still exists")
            return "link moved"
        }

        runner.test("permanent delete removes only chosen local paths") {
            let file = paths.home.appendingPathComponent("Documents/delete-me.txt")
            let fp = FileSafety.fingerprint(of: file)!
            let item = ScanItem.make(url: file, category: .largeFile, size: fp.size, fingerprint: fp, location: "Documents", scope: .permanentDelete)
            let outcome = FileSafety.permanentlyDelete([item])
            try expect(outcome.successCount == 1, "file was not deleted")
            try expect(!FileManager.default.fileExists(atPath: file.path), "file still exists")
            let protected = ScanItem.make(
                url: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"),
                category: .largeFile,
                size: 1,
                fingerprint: FileFingerprint(size: 1, modified: nil, isDirectory: false),
                location: "System",
                scope: .permanentDelete
            )
            try expect(FileSafety.validate(protected, scope: .permanentDelete) != nil, "protected system file validated")
            return "deleted fixture; system refused"
        }

        runner.test("permanent delete of a symlink leaves its target") {
            let target = paths.home.appendingPathComponent("Documents/target.txt")
            try Data("target".utf8).write(to: target)
            let link = paths.home.appendingPathComponent("Documents/link-to-target")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            let fp = FileSafety.fingerprint(of: link)!
            let item = ScanItem.make(url: link, category: .largeFile, size: fp.size, fingerprint: fp, location: "Documents", scope: .permanentDelete)
            let outcome = FileSafety.permanentlyDelete([item])
            try expect(outcome.successCount == 1, "symlink was not deleted")
            try expect(FileManager.default.fileExists(atPath: target.path), "symlink target was deleted")
            return "link removed, target kept"
        }

        runner.test("maintenance finds aliases, invalid agents and confirmed leftovers") {
            let freshAlias = paths.home.appendingPathComponent("Desktop/Broken Alias")
            try? FileManager.default.removeItem(at: freshAlias)
            try FileManager.default.createSymbolicLink(atPath: freshAlias.path, withDestinationPath: "/no/such/alias-target")
            let options = MaintenanceScanner.Options(extraAppRoots: [paths.apps], installedBundleIDsOverride: [])
            let report = MaintenanceScanner.scan(options: options, ignoreList: [], progress: { _ in }, cancelled: { false })
            try expect(report.items.contains { $0.category == .brokenAlias }, "broken alias missing")
            try expect(report.items.contains { $0.category == .invalidLaunchAgent && !$0.isInformational }, "invalid agent missing")
            try expect(report.items.contains { $0.category == .leftover && $0.bundleID == "com.leftover.app" && !$0.isInformational }, "confirmed leftover missing")
            try expect(report.items.contains { $0.category == .leftover && $0.bundleID == "com.single.app" && $0.isInformational }, "uncertain leftover should be informational")
            return "\(report.items.count) findings"
        }

        runner.test("maintenance resolves relative LaunchAgents and exempts app-owned paths") {
            let options = MaintenanceScanner.Options(extraAppRoots: [paths.apps], installedBundleIDsOverride: [])
            let report = MaintenanceScanner.scan(options: options, ignoreList: [], progress: { _ in }, cancelled: { false })
            try expect(!report.items.contains { $0.category == .invalidLaunchAgent && ($0.appName ?? "").contains("com.test.relative") }, "relative agent wrongly flagged")
            // A missing program is broken only when the path
            // is not owned by an installed app.
            try expect(report.items.contains { $0.category == .invalidLaunchAgent && $0.appName == "com.test.owned" && $0.isInformational }, "missing app-owned program should stay informational")
            // No resolved program path at all is broken.
            try expect(report.items.contains { $0.category == .invalidLaunchAgent && $0.appName == "com.test.noprogram" && !$0.isInformational }, "agent with no program should be broken")
            // An existing path is not broken, even when the
            // file is not executable, so no finding is produced.
            try expect(!report.items.contains { $0.category == .invalidLaunchAgent && $0.appName == "com.test.ownedfile" }, "existing non-executable file should not be flagged")
            return "relative resolved; missing app-owned exempt; no program broken; non-executable ignored"
        }

        runner.test("maintenance reports broken preferences") {
            let options = MaintenanceScanner.Options(extraAppRoots: [paths.apps], installedBundleIDsOverride: [])
            let report = MaintenanceScanner.scan(options: options, ignoreList: [], progress: { _ in }, cancelled: { false })
            try expect(report.items.contains { $0.category == .brokenPreference && ($0.appName ?? "") == "com.test.broken" }, "broken preference missing")
            try expect(!report.items.contains { $0.category == .brokenPreference && ($0.appName ?? "") == "com.test.app" }, "valid preference flagged")
            return "invalid plist detected, valid plist ignored"
        }

        runner.test("reminder and alert thresholds match the product rules") {
            try expect(Rules.Reminder.optionDays == [3, 7, 14, 30], "reminder options wrong")
            try expect(Rules.Reminder.optionSeconds == [259_200, 604_800, 1_209_600, 2_592_000], "reminder seconds wrong")
            try expect(Rules.Reminder.defaultDays == 7, "reminder default wrong")
            try expect(Rules.Reminder.notificationCategory == "FettleCleanupReminder", "notification category wrong")
            try expect(Rules.Reminder.notificationRepeats, "reminder trigger should repeat")
            try expect(Rules.Reminder.intervalSeconds(forDays: 3) == 259_200, "3-day interval wrong")
            try expect(Rules.Reminder.intervalSeconds(forDays: 7) == 604_800, "7-day interval wrong")
            try expect(Rules.Reminder.intervalSeconds(forDays: 14) == 1_209_600, "14-day interval wrong")
            try expect(Rules.Reminder.intervalSeconds(forDays: 30) == 2_592_000, "30-day interval wrong")
            try expect(Rules.trashAlertThresholdBytes.count == 11, "trash option count wrong")
            try expect(Rules.trashAlertThresholdBytes.first == 500_000_000, "trash first option wrong")
            try expect(Rules.defaultTrashAlertThresholdIndex == 2, "trash default index wrong")
            try expect(Rules.defaultTrashAlertThresholdBytes == 2_000_000_000, "trash default wrong")
            try expect(Rules.diskSpaceAlertThresholdBytes == [2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000, 30_000_000_000, 50_000_000_000, 100_000_000_000], "disk options wrong")
            try expect(Rules.defaultDiskSpaceThreshold(freeSpace: 25_000_000_000) == 2_000_000_000, "10% rounding wrong")
            try expect(Rules.defaultDiskSpaceThreshold(freeSpace: 50_000_000_000) == 5_000_000_000, "10% exact wrong")
            try expect(Rules.defaultDiskSpaceThreshold(freeSpace: 0) == 2_000_000_000, "readable zero should use the smallest option")
            try expect(Rules.defaultDiskSpaceThreshold(freeSpace: 35_000_000_000) == 2_000_000_000, "exact 2/5 GB tie should keep the smaller option")
            try expect(Rules.defaultDiskSpaceThreshold(freeSpace: nil) == 100_000_000_000, "fallback wrong")
            return "reminder seconds and category, 11 trash options, 7 disk options, defaults verified"
        }

        runner.test("invalid LaunchAgent can be moved to Trash") {
            let plist = paths.home.appendingPathComponent("Library/LaunchAgents/com.test.bad.plist")
            let fp = FileSafety.fingerprint(of: plist)!
            let item = ScanItem.make(url: plist, category: .invalidLaunchAgent, size: fp.size, fingerprint: fp, location: "LaunchAgents", scope: .maintenance)
            let outcome = FileSafety.moveToTrash([item], scope: .maintenance, ignoreList: [])
            try expect(outcome.successCount == 1, "agent plist was not moved")
            try expect(!FileManager.default.fileExists(atPath: plist.path), "agent plist still exists")
            return "plist moved to Trash"
        }

        runner.test("uninstaller matches exact bundle identifier and flags app data") {
            let result = UninstallerScanner.scan(extraFolders: [], ignoreList: [], progress: { _ in }, cancelled: { false })
            guard let app = result.apps.first(where: { $0.bundleID == "com.test.app" }) else {
                throw TestFailure.failed("fake app not found")
            }
            try expect(app.version == "2.1", "version wrong")
            try expect(app.size > 0, "size not measured")
            try expect(app.associations.contains { $0.category == .appCache }, "app cache not matched")
            try expect(app.associations.contains { $0.category == .appData && $0.isAppData }, "app data not flagged")
            try expect(!app.associations.contains { $0.bundleID == "com.other.app" }, "other app data included")
            try expect(!app.associations.contains { $0.path.contains("Group Containers") }, "shared container included")
            try expect(!app.isSystem, "fake app marked as system")
            return "\(app.associations.count) associated items"
        }

        runner.test("uninstaller removes the app and selected support files") {
            let result = UninstallerScanner.scan(extraFolders: [], ignoreList: [], progress: { _ in }, cancelled: { false })
            guard let app = result.apps.first(where: { $0.bundleID == "com.test.app" }) else {
                throw TestFailure.failed("fake app not found")
            }
            var items: [ScanItem] = []
            if let fp = app.fingerprint {
                items.append(ScanItem.make(url: app.bundleURL, category: .app, size: app.size, fingerprint: fp, location: app.source, scope: .uninstaller))
            }
            items += app.associations.filter { !$0.isAppData }
            let outcome = FileSafety.moveToTrash(items, scope: .uninstaller, extraRoots: [paths.apps], ignoreList: [])
            try expect(outcome.successCount == items.count, "not all app files moved: \(outcome.results.filter { !$0.success }.map { $0.message ?? "" })")
            try expect(!FileManager.default.fileExists(atPath: app.bundleURL.path), "app still exists")
            return "\(items.count) items moved"
        }

        runner.test("privacy scan finds cache, cookies, history and download records") {
            var skipped: [SkippedItem] = []
            let result = PrivacyScanner.scanChromium(browser: .opera, ignoreList: [], skipped: &skipped, cancelled: { false })
            try expect(result.items.contains { $0.category == .browserCache }, "cache missing")
            try expect(result.items.contains { $0.category == .cookies }, "cookies missing")
            try expect(result.items.contains { $0.category == .browsingHistory }, "history missing")
            try expect(result.items.contains { $0.category == .downloadHistory }, "download history missing")
            return "\(result.items.count) items"
        }

        runner.test("clearing download history keeps downloaded files") {
            var downloadSkipped: [SkippedItem] = []
            let scan = PrivacyScanner.scanChromium(browser: .opera, ignoreList: [], skipped: &downloadSkipped, cancelled: { false })
            guard let db = scan.items.first(where: { $0.category == .downloadHistory }) else {
                throw TestFailure.failed("download history row missing")
            }
            let downloaded = paths.home.appendingPathComponent("Downloads/report.pdf")
            try expect(FileManager.default.fileExists(atPath: downloaded.path), "fixture download missing")
            let result = PrivacyScanner.clearDownloadHistory(item: db)
            try expect(result.success, "clear failed: \(result.message ?? "")")
            try expect(FileManager.default.fileExists(atPath: downloaded.path), "downloaded file was deleted")
            let count = Shell.run(FsTool.sqlitePath, [db.path, "SELECT COUNT(*) FROM downloads;"])
            try expect(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "download rows remain: \(count.stdout)")
            return "rows cleared, file kept"
        }

        runner.test("Safari download history clear keeps a valid plist") {
            let plist = paths.home.appendingPathComponent("Library/Safari/Downloads.plist")
            let fp = FileSafety.fingerprint(of: plist)!
            let item = ScanItem.make(url: plist, category: .downloadHistory, size: fp.size, fingerprint: fp, location: "Safari", bundleID: "com.apple.Safari", scope: .privacy)
            let result = PrivacyScanner.clearDownloadHistory(item: item)
            try expect(result.success, "Safari clear failed: \(result.message ?? "")")
            let data = try Data(contentsOf: plist)
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            try expect((object as? [Any])?.isEmpty == true, "Safari downloads plist is not empty")
            try expect(FileManager.default.fileExists(atPath: paths.home.appendingPathComponent("Downloads/report.pdf").path), "Safari file was deleted")
            return "plist cleared"
        }

        runner.test("extension scan reads manifest and enabled state") {
            var skipped: [SkippedItem] = []
            var profiles: [String] = []
            let records = ExtensionsScanner.scanChromium(
                bundleID: BrowserKind.opera.bundleID,
                appName: "Opera",
                profileRoot: paths.home.appendingPathComponent("Library/Application Support/com.operasoftware.Opera", isDirectory: true),
                managementURL: "opera://extensions",
                provider: "Opera",
                profiles: &profiles,
                skipped: &skipped,
                cancelled: { false }
            )
            guard let record = records.first(where: { $0.name == "Test Extension" }) else {
                throw TestFailure.failed("extension not found")
            }
            try expect(record.version == "1.2.3", "version wrong")
            try expect(record.enabled == true, "enabled state wrong")
            return "manifest and state read"
        }

        runner.test("login item scan parses user LaunchAgents") {
            var notes: [String] = []
            var skipped: [SkippedItem] = []
            let fresh: [String: Any] = ["Label": "com.test.login", "Program": "/bin/ls"]
            let agentURL = paths.home.appendingPathComponent("Library/LaunchAgents/com.test.login.plist")
            try PropertyListSerialization.data(fromPropertyList: fresh, format: .xml, options: 0).write(to: agentURL)
            let records = LoginItemsScanner.scanLaunchAgents(notes: &notes, skipped: &skipped, cancelled: { false })
            try expect(records.contains { $0.identifier == "com.test.login" }, "fresh agent missing")
            try expect(records.contains { $0.identifier == "com.test.login" }, "login agent missing")
            try expect(records.contains { $0.identifier == "com.test.good" }, "good agent missing")
            try expect(records.allSatisfy { $0.manageability == .manageable }, "manageability wrong")
            return "\(records.count) agents"
        }

        runner.test("background item parsing is read-only and typed") {
            let block = [
                "#1:",
                "     UUID: ABC",
                "     Name: Example",
                "Developer Name: Example Inc",
                "     Type: login item (0x10)",
                "Disposition: [enabled, allowed] (0x9)",
                " Identifier: com.example.login",
                "        URL: /Applications/Example.app"
            ].joined(separator: "\n")
            let fields = LoginItemsScanner.parseFields(block)
            try expect(fields["Name"] == "Example", "name not parsed")
            try expect(fields["Identifier"] == "com.example.login", "identifier not parsed")
            return "fields parsed"
        }

        runner.test("background item dump yields every indented item once") {
            let dump = [
                "========================",
                " Records for UID -2 : FFFF",
                "========================",
                "",
                " Items:",
                "",
                " #1:",
                "                 UUID: AAA",
                "                 Name: Docker",
                "           Identifier: Docker",
                "          Disposition: [disabled, allowed, not notified] (0x2)",
                "  Embedded Item Identifiers:",
                "    #1: 16.com.docker.vmnetd",
                "",
                " #2:",
                "                 UUID: BBB",
                "                 Name: OneDrive",
                "           Identifier: com.microsoft.OneDrive",
                "          Disposition: [enabled, allowed, notified] (0x3)",
                "                  URL: file:///Applications/OneDrive.app/",
                "========================",
                " Records for UID 501 : CCCC",
                "========================",
                " #1:",
                "                 UUID: AAA",
                "                 Name: Docker",
                "           Identifier: Docker",
                " #2:",
                "                 UUID: DDD",
                "                 Name: (null)",
                "       Developer Name: (null)",
                "           Identifier: com.example.helper",
                "                  URL: (null)"
            ].joined(separator: "\n")
            let records = LoginItemsScanner.parseBackgroundItems(dump)
            try expect(records.map(\.name) == ["Docker", "OneDrive", "com.example.helper"], "items: \(records.map(\.name))")
            try expect(Set(records.map(\.id)).count == records.count, "duplicate ids")
            try expect(records[0].enabled == false && records[1].enabled == true, "disposition not parsed")
            try expect(records[2].path == nil, "null URL kept")
            try expect(records[2].publisher != "(null)", "null developer shown")
            try expect(records.allSatisfy { $0.manageability == .systemManaged }, "background items must stay read-only")
            return "\(records.count) items"
        }

        runner.test("volume lookup matches a volume root, not the startup disk") {
            let startup = FileSafety.volumeInfo(for: URL(fileURLWithPath: "/"))
            try expect(startup?.url.path == "/", "startup disk not matched")
            let home = FileSafety.volumeInfo(for: AppPaths.home)
            try expect(home != nil, "home volume not matched")
            for volume in FileSafety.volumes() where volume.url.path != "/" {
                let root = FileSafety.volumeInfo(for: volume.url)
                try expect(root?.url.path == volume.url.path, "\(volume.url.path) matched \(root?.url.path ?? "nil")")
                let inside = FileSafety.volumeInfo(for: volume.url.appendingPathComponent("folder/file"))
                try expect(inside?.url.path == volume.url.path, "path inside \(volume.url.path) matched \(inside?.url.path ?? "nil")")
            }
            return "\(FileSafety.volumes().count) volumes"
        }

        runner.test("power parser understands minutes and toggles") {
            let parsed = PowerReader.splitSetting("displaysleep 5")
            try expect(parsed?.key == "displaysleep" && parsed?.value == "5", "split failed")
            try expect(PowerReader.formatValue(key: "displaysleep", value: "0") == L("Never"), "zero should be Never")
            try expect(PowerReader.formatValue(key: "powernap", value: "1") == L("On"), "toggle wrong")
            let snapshot = PowerReader.read()
            try expect(!snapshot.settings.isEmpty, "pmset returned no settings")
            return "\(snapshot.settings.count) settings"
        }

        runner.test("history persists and reports outcomes") {
            let historyURL = paths.home.appendingPathComponent("Library/Application Support/Fettle/test-history.json")
            try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MainActor.assumeIsolated {
                let store = HistoryStore(fileURL: historyURL)
                let outcome = OperationOutcome(title: "Test", message: "Test", results: [ItemResult(path: "/tmp/x", name: "x", category: .cache, success: true, bytes: 10)], bytes: 10)
                let originalLanguage = L10n.languageCode
                defer { L10n.languageCode = originalLanguage }
                L10n.apply(language: .dutch)
                store.record(module: .disk, actionKey: "Move to Trash", outcome: outcome)
                let reloaded = HistoryStore(fileURL: historyURL)
                try expect(reloaded.events.count == 1, "history did not persist")
                guard var event = reloaded.events.first else { throw TestFailure.failed("missing history event") }
                try expect(event.bytes == 10, "history bytes wrong")
                try expect(event.action == "Move to Trash" && event.outcome == "Completed", "history stored translated labels")
                try expect(event.displayAction == "Naar prullenmand" && event.displayOutcome == "Voltooid", "Dutch history labels wrong")
                event.action = "Apps verwijderen"
                event.outcome = "Sommige items konden niet worden verwijderd"
                store.record(event)
                L10n.apply(language: .english)
                let legacy = HistoryStore(fileURL: historyURL).events.first { $0.action == "Apps verwijderen" }
                try expect(legacy?.displayAction == "Remove apps" && legacy?.displayOutcome == "Some items could not be removed", "legacy history did not follow language")
                event.action = "Custom operation"
                try expect(event.displayAction == event.action, "unknown history label was lost")
            }
            return "persisted"
        }


        runner.test("update feed signature is verified before offering a version") {
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
            let feedURL = "https://updates.example.test/feed.json"
            let version = "9.9.9"
            let payload = "\(version)||\(feedURL)|"
            let signature = try key.signature(for: Data(payload.utf8)).base64EncodedString()
            let feed: [String: Any] = ["version": version, "url": feedURL, "signature": signature]
            MockUpdateProtocol.payload = try JSONSerialization.data(withJSONObject: feed)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockUpdateProtocol.self]
            let session = URLSession(configuration: configuration)
            let result = runAsync { await UpdateChecker.check(feedURL: feedURL, publicKeyBase64: publicKey, session: session) }
            if case .available(let offered) = result {
                try expect(offered.version == version, "wrong version offered")
            } else {
                throw TestFailure.failed("valid signed feed was not accepted: \(result)")
            }
            let badPayload: [String: Any] = ["version": version, "url": feedURL, "signature": Data("bad".utf8).base64EncodedString()]
            MockUpdateProtocol.payload = try JSONSerialization.data(withJSONObject: badPayload)
            let bad = runAsync { await UpdateChecker.check(feedURL: feedURL, publicKeyBase64: publicKey, session: session) }
            if case .invalidSignature = bad {
                // expected
            } else {
                throw TestFailure.failed("invalid signature was accepted: \(bad)")
            }
            return "signed accepted, tampered rejected"
        }

        runner.test("app updater parses an appcast and orders versions") {
            try expect(VersionOrder.isNewer("1.10.2", than: "1.9.9"), "numeric version order")
            try expect(VersionOrder.isNewer("2.0", than: "2.0-beta"), "release sorts after beta")
            try expect(VersionOrder.compare("1.0", "1.0.0") == .orderedSame, "missing component should compare as zero")
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>Fixture</title>
                <item>
                  <title>Version 2.0.1</title>
                  <sparkle:shortVersionString>2.0.1</sparkle:shortVersionString>
                  <sparkle:version>201</sparkle:version>
                  <pubDate>Wed, 02 Oct 2024 13:00:00 +0000</pubDate>
                  <description><![CDATA[<p>Fixes &amp; improvements.</p>]]></description>
                  <enclosure url="https://example.test/UpdaterTest.zip" length="1234567" type="application/octet-stream"/>
                </item>
              </channel>
            </rss>
            """
            let entries = try UpdaterScanner.parseAppcast(Data(xml.utf8))
            try expect(entries.count == 1, "appcast item count")
            let entry = entries[0]
            try expect(entry.shortVersion == "2.0.1", "short version")
            try expect(entry.buildVersion == "201", "build version")
            try expect(entry.downloadURL?.absoluteString == "https://example.test/UpdaterTest.zip", "download URL")
            try expect(entry.updateSize == 1_234_567, "update size")
            try expect(entry.releaseNotes?.contains("Fixes & improvements") == true, "release notes")
            try expect(entry.releaseDate != nil, "release date")
            let listNotes = plainText("<ul><li>Faster scans</li><li>Fixes a crash</li></ul><h2>Other</h2><div>Notes</div>")
            try expect(listNotes == "• Faster scans\n• Fixes a crash\nOther\nNotes", "list notes ran together: \(listNotes)")
            return "versions and appcast parsed"
        }

        runner.test("app updater finds Sparkle, App Store and Apple apps") {
            let apps = home.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
            let feed = home.appendingPathComponent("updater-feed.xml")
            let feedXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item>
                <sparkle:shortVersionString>2.0.1</sparkle:shortVersionString>
                <sparkle:version>201</sparkle:version>
                <description>New things</description>
                <enclosure url="https://example.test/UpdaterTest.zip" length="4000" type="application/octet-stream"/>
              </item></channel>
            </rss>
            """
            try Data(feedXML.utf8).write(to: feed)

            func makeApp(_ name: String, bundleID: String, version: String, feedURL: String?, mas: Bool = false) throws -> URL {
                let contents = apps.appendingPathComponent("\(name).app/Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: contents.appendingPathComponent("MacOS/\(name)"))
                var info: [String: Any] = [
                    "CFBundleIdentifier": bundleID,
                    "CFBundleName": name,
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": "100",
                    "CFBundlePackageType": "APPL"
                ]
                if let feedURL { info["SUFeedURL"] = feedURL }
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                if mas {
                    let receipt = contents.appendingPathComponent("_MASReceipt/receipt")
                    try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("receipt".utf8).write(to: receipt)
                }
                return contents.deletingLastPathComponent()
            }

            let sparkleApp = try makeApp("UpdaterTest", bundleID: "com.test.updater", version: "1.0", feedURL: feed.absoluteString)
            _ = try makeApp("StoreTest", bundleID: "com.test.store", version: "3.0", feedURL: nil, mas: true)
            _ = try makeApp("AppleTest", bundleID: "com.apple.test", version: "1.0", feedURL: nil)
            _ = try makeApp("AppleStoreTest", bundleID: "com.apple.storetest", version: "16.0", feedURL: nil, mas: true)
            let selfUpdating = try makeApp("SelfUpdating", bundleID: "com.test.selfupdating", version: "1.0", feedURL: nil)
            try FileManager.default.createDirectory(at: selfUpdating.appendingPathComponent("Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
            _ = try makeApp("BrokenFeed", bundleID: "com.test.broken", version: "1.0", feedURL: home.appendingPathComponent("missing-feed.xml").absoluteString)

            let result = runAsync {
                await UpdaterScanner.scan(extraFolders: [], ignoreList: [], progress: { _ in }, cancelled: { false })
            }
            let sparkle = result.records.first { $0.bundleID == "com.test.updater" }
            try expect(sparkle?.status == .available, "Sparkle update missing")
            try expect(sparkle?.latestVersion == "2.0.1", "latest version wrong")
            try expect(sparkle?.actionURL?.absoluteString == "https://example.test/UpdaterTest.zip", "action URL wrong")
            let store = result.records.first { $0.bundleID == "com.test.store" }
            try expect(store?.status == .appStore, "App Store app not identified")
            try expect(store?.actionURL?.scheme == "macappstore", "App Store route wrong")
            let apple = result.records.first { $0.bundleID == "com.apple.test" }
            try expect(apple?.status == .appleSoftwareUpdate, "Apple app not identified")
            try expect(apple?.actionURL?.scheme == "x-apple.systempreferences", "Software Update route wrong")
            let appleStore = result.records.first { $0.bundleID == "com.apple.storetest" }
            try expect(appleStore?.status == .appStore, "Apple app from the App Store sent to Software Update")
            try expect(appleStore?.actionURL?.scheme == "macappstore", "Apple App Store app route wrong")
            let updatesItself = result.records.first { $0.bundleID == "com.test.selfupdating" }
            try expect(updatesItself?.status == .noChannel, "app without a published feed was checked")
            try expect(updatesItself?.errorMessage?.contains("updates itself") == true, "self-updating app not explained")
            let broken = result.records.first { $0.bundleID == "com.test.broken" }
            try expect(broken?.status == .failed, "broken feed not reported")

            _ = try makeApp("UpdaterTest", bundleID: "com.test.updater", version: "2.0.1", feedURL: feed.absoluteString)
            let rechecked = runAsync {
                await UpdaterScanner.scan(extraFolders: [], ignoreList: [], progress: { _ in }, cancelled: { false })
            }
            try expect(rechecked.records.first { $0.bundleID == "com.test.updater" }?.status == .upToDate, "recheck used stale bundle metadata")
            let ignored = runAsync {
                await UpdaterScanner.scan(extraFolders: [], ignoreList: [sparkleApp.path], progress: { _ in }, cancelled: { false })
            }
            try expect(!ignored.records.contains { $0.bundleID == "com.test.updater" }, "ignored app was checked")
            let cancelled = runAsync {
                await UpdaterScanner.scan(extraFolders: [], ignoreList: [], progress: { _ in }, cancelled: { true })
            }
            try expect(cancelled.records.isEmpty, "cancelled updater scan returned results")
            return "Sparkle, App Store, Apple, self-updating, ignored and cancelled apps"
        }

        runner.test("Dutch and English interface strings resolve") {
            let previous = L10n.languageCode
            defer { L10n.languageCode = previous }
            L10n.languageCode = "en"
            try expect(Fmt.availableUpdates(1) == "1 update available" && Fmt.availableUpdates(2) == "2 updates available", "English update count wrong")
            try expect(L("Scan") == "Scan", "English Scan wrong")
            L10n.languageCode = "nl"
            try expect(L("Scan") == "Scannen", "Dutch Scan wrong")
            try expect(L("Disk Cleanup") == "Schijfopruiming", "Dutch Disk Cleanup wrong")
            try expect(L("Clearing this data will sign you out of websites.") == "Deze gegevens wissen logt je uit bij websites.", "Dutch sign-out warning missing")
            try expect(L("Clearing history removes the list of sites you visited. You stay signed in.") == "Geschiedenis wissen verwijdert de lijst met bezochte websites. Je blijft ingelogd.", "Dutch history note missing")
            try expect(Fmt.availableUpdates(1) == "1 update beschikbaar" && Fmt.availableUpdates(0) == "0 updates beschikbaar", "Dutch update count wrong")
            return "both languages resolve"
        }

        runner.test("network rates restart after resets, removal or a sampling gap") {
            let bytes: (received: UInt64, sent: UInt64) = (100, 200)
            try expect(HealthSampler.networkRates(current: bytes, previous: (80, 160), elapsed: 2) == (10, 20), "normal rates")
            try expect(HealthSampler.networkRates(current: bytes, previous: (120, 160), elapsed: 2) == (0, 0), "counter reset")
            try expect(HealthSampler.networkRates(current: bytes, previous: nil, elapsed: 2) == (0, 0), "interface reappeared")
            try expect(HealthSampler.networkRates(current: bytes, previous: (80, 160), elapsed: 300) == (0, 0), "sleep gap")
            return "network baselines verified"
        }

        runner.test("health parsers read counters, swap and pressure safely") {
            try expect(HealthSampler.parseByteValue("1.50G") == 1_500_000_000, "GB parse wrong")
            try expect(HealthSampler.parseByteValue("512M") == 512_000_000, "MB parse wrong")
            let swap = HealthSampler.parseSwap("total = 8192.00M  used = 1024.00M  free = 7168.00M")
            try expect(swap.total == 8_192_000_000 && swap.used == 1_024_000_000 && swap.free == 7_168_000_000, "swap parse wrong")
            try expect(HealthSampler.memoryPressureLevel(raw: 1) == .normal, "normal pressure wrong")
            try expect(HealthSampler.memoryPressureLevel(raw: 2) == .warning, "warning pressure wrong")
            try expect(HealthSampler.memoryPressureLevel(raw: 4) == .critical, "critical pressure wrong")
            try expect(HealthSampler.processStatus(2) == L("Running"), "process status wrong")
            try expect(HealthSampler.intFromIOReg("  |   \"CycleCount\" = 278", key: "CycleCount") == 278, "ioreg int wrong")
            let ioreg = "\"Statistics\" = {\"Bytes (Read)\"=100,\"Bytes (Write)\"=200} \"Statistics\" = {\"Bytes (Read)\"=50,\"Bytes (Write)\"=25}"
            try expect(HealthSampler.sumStatistic(in: ioreg, key: "Bytes (Read)") == 150, "read sum wrong")
            try expect(HealthSampler.sumStatistic(in: ioreg, key: "Bytes (Write)") == 225, "write sum wrong")
            return "parsers verified"
        }

        runner.test("health alerts cover memory, CPU, disk, Trash, drives and external volumes") {
            try MainActor.assumeIsolated {
                let settings = AppSettings()
                let previous = (
                    settings.memoryPressureAlert, settings.highCPUAlert, settings.highCPUThreshold,
                    settings.diskSpaceAlert, settings.diskSpaceThresholdGB,
                    settings.trashReminder, settings.trashThresholdMB,
                    settings.driveHealthAlert, settings.externalDriveAlert, settings.notificationsEnabled
                )
                defer {
                    settings.memoryPressureAlert = previous.0
                    settings.highCPUAlert = previous.1
                    settings.highCPUThreshold = previous.2
                    settings.diskSpaceAlert = previous.3
                    settings.diskSpaceThresholdGB = previous.4
                    settings.trashReminder = previous.5
                    settings.trashThresholdMB = previous.6
                    settings.driveHealthAlert = previous.7
                    settings.externalDriveAlert = previous.8
                    settings.notificationsEnabled = previous.9
                }
                settings.memoryPressureAlert = true
                settings.highCPUAlert = true
                settings.highCPUThreshold = 85
                settings.diskSpaceAlert = true
                settings.diskSpaceThresholdGB = 100
                settings.trashReminder = true
                settings.trashThresholdMB = 1
                settings.driveHealthAlert = true
                settings.externalDriveAlert = true
                settings.notificationsEnabled = false

                let historyURL = paths.home.appendingPathComponent("Library/Application Support/Fettle/alert-history.json")
                let activityURL = paths.home.appendingPathComponent("Library/Application Support/Fettle/alert-activity.json")
                let model = HealthModel(settings: settings, cleanupHistory: HistoryStore(fileURL: historyURL), activity: HealthHistoryStore(fileURL: activityURL))
                try expect(model.highestSeverity == nil, "unmeasured health reported a severity")
                model.trashBytes = 5_000_000_000

                var snapshot = HealthSnapshot()
                snapshot.cpu.usageFraction = 0.95
                snapshot.cpu.warmedUp = true
                snapshot.memory.pressure = .critical
                snapshot.memory.totalBytes = 16_000_000_000
                snapshot.memory.usedBytes = 14_000_000_000
                snapshot.drives = [DriveHealth(id: "disk9", model: "Test Drive", sizeBytes: 1_000_000_000, isInternal: false, isSolidState: true, smartStatus: "Failing", busProtocol: "USB", volumeIDs: ["v1"])]
                snapshot.volumes = [
                    VolumeHealth(id: "root", name: "Macintosh HD", mountPath: "/", device: "/dev/disk1s1", totalBytes: 100_000_000_000, availableBytes: 1_000_000_000, isInternal: true, isRemovable: false, isEjectable: false, isReadOnly: false, filesystem: "APFS", driveID: "disk1", smartStatus: "Verified", isSystemVolume: true),
                    VolumeHealth(id: "usb", name: "USB", mountPath: "/Volumes/USB", device: "/dev/disk9s1", totalBytes: 1_000_000_000, availableBytes: 500_000_000, isInternal: false, isRemovable: true, isEjectable: true, isReadOnly: false, filesystem: "ExFAT", driveID: "disk9", smartStatus: "Failing", isSystemVolume: false)
                ]
                for _ in 0..<3 { model.evaluateForTesting(snapshot) }
                let kinds = Set(model.activeAlerts.map(\.kind))
                try expect(kinds.contains(.memoryPressure), "memory pressure alert missing")
                try expect(kinds.contains(.highCPU), "CPU alert missing")
                try expect(kinds.contains(.lowDisk), "low disk alert missing")
                try expect(kinds.contains(.largeTrash), "Trash alert missing")
                try expect(kinds.contains(.externalDrive), "external drive alert missing")
                try expect(kinds.contains(.driveHealth), "drive health alert missing")
                try expect(model.highestSeverity == .critical, "critical severity not reported")
            }
            return "six alert kinds evaluated"
        }

        runner.test("activity history stores only numeric readings") {
            let url = paths.home.appendingPathComponent("Library/Application Support/Fettle/health-history-test.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MainActor.assumeIsolated {
                let store = HealthHistoryStore(fileURL: url)
                let sample = HealthHistorySample(
                    date: Date(),
                    cpuPercent: 12,
                    memoryUsedBytes: 1_000,
                    memoryTotalBytes: 2_000,
                    memoryPressure: .normal,
                    diskFreeBytes: 3_000,
                    diskTotalBytes: 4_000,
                    networkInBytesPerSecond: 5,
                    networkOutBytesPerSecond: 6,
                    batteryPercent: 77,
                    thermalState: L("Nominal")
                )
                store.append(sample)
                let reloaded = HealthHistoryStore(fileURL: url)
                try expect(reloaded.samples.count == 1, "activity history did not persist")
                try expect(reloaded.samples.first?.cpuPercent == 12, "activity CPU wrong")
                try expect(HealthTrendMetric.cpu.value(sample) == 12, "trend CPU wrong")
                try expect(HealthTrendMetric.disk.value(sample) == 0.000003, "trend disk wrong")
                reloaded.clear()
                try expect(HealthHistoryStore(fileURL: url).samples.isEmpty, "activity clear failed")
            }
            return "numeric history persisted and cleared"
        }

        runner.test("process actions refuse the wrong process") {
            let protected = ProcessReading(pid: 1, name: "launchd", path: "/sbin/launchd", canManage: false)
            try expect(!ProcessActions.stillMatches(protected), "protected process accepted")
            let own = ProcessReading(pid: getpid(), name: "Fettle", path: nil, canManage: true)
            try expect(!ProcessActions.stillMatches(own), "own process accepted")
            try expect(ProcessActions.responsiveness(of: getpid()) == nil || ProcessActions.responsiveness(of: getpid()) == true, "responsiveness returned an impossible value")
            return "identity guards verified"
        }

        runner.test("permission failures are reported, not hidden") {
            let denied = paths.home.appendingPathComponent("Library/Logs/denied")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
            var skipped: [SkippedItem] = []
            _ = DiskCleanupScanner.scanLogs(ignoreList: [], skipped: &skipped, cancelled: { false })
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
            try expect(skipped.contains { $0.unreadable == true && $0.path.hasSuffix("/denied") }, "permission denial not reported")
            var rescanned: [SkippedItem] = []
            _ = DiskCleanupScanner.scanLogs(ignoreList: [], skipped: &rescanned, cancelled: { false })
            try expect(!rescanned.contains { $0.path.hasSuffix("/denied") }, "permission failure persisted after access was restored")
            return "permission denial and recovery recorded"
        }
    }
}

struct HomePaths {
    var home: URL
    var apps: URL { home.appendingPathComponent("Applications", isDirectory: true) }
}

enum Fixture {
    static func build(home: URL) throws {
        let fm = FileManager.default
        func dir(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ relative: String, size: Int = 4096, modified: Date? = nil) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: size).write(to: url)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            return url
        }
        func preference(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["fixture": true], format: .binary, options: 0)
            try data.write(to: url)
            return url
        }
        let old = Date().addingTimeInterval(-10 * 86_400)
        let recent = Date().addingTimeInterval(-60)

        _ = try dir("Library/Caches/com.example.cache")
        _ = try file("Library/Caches/com.example.cache/cache.bin", size: 24_000, modified: old)
        _ = try file("Library/Caches/TemporaryItems/old.tmp", size: 4_000, modified: old)
        _ = try file("Library/Caches/com.denied")
        _ = try dir("Library/Logs/denied")
        _ = try file("Library/Logs/denied/old.log", size: 3_000, modified: old)
        _ = try file("Library/Logs/old.log", size: 5_000, modified: old)
        _ = try file("Library/Logs/DiagnosticReports/old.ips", size: 6_000, modified: old)
        _ = try file("Library/Logs/DiagnosticReports/new.ips", size: 6_000, modified: recent)
        _ = try file("Library/Application Support/MobileSync/Backup/backup.bin", size: 10_000, modified: old)
        _ = try file(".Trash/junk.txt", size: 2_000)
        _ = try file("Documents/keep.txt", size: 1_000)
        _ = try file("Documents/delete-me.txt", size: 1_000)
        _ = try file("Documents/target.txt", size: 100)
        _ = try file("Downloads/report.pdf", size: 12_000)
        _ = try file("tmp/leftover.tmp", size: 2_000, modified: old)

        let desktop = try dir("Desktop")
        try fm.createSymbolicLink(atPath: desktop.appendingPathComponent("Broken Link").path, withDestinationPath: "/no/such/target")

        // LaunchAgents: one invalid, one valid.
        let bad: [String: Any] = ["Label": "com.test.bad", "Program": "/nonexistent/program", "RunAtLoad": true]
        let good: [String: Any] = ["Label": "com.test.good", "Program": "/bin/ls"]
        let agents = try dir("Library/LaunchAgents")
        try PropertyListSerialization.data(fromPropertyList: bad, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.bad.plist"))
        try PropertyListSerialization.data(fromPropertyList: good, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.good.plist"))
        let relative: [String: Any] = ["Label": "com.test.relative", "WorkingDirectory": "/bin", "Program": "ls", "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: relative, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.relative.plist"))
        _ = try file("Applications/TestApp.app/Contents/Resources/not-a-program.txt")
        let appOwnedMissing: [String: Any] = [
            "Label": "com.test.owned",
            "Program": home.appendingPathComponent("Applications/TestApp.app/Contents/MacOS/Gone").path,
        ]
        try PropertyListSerialization.data(fromPropertyList: appOwnedMissing, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.owned.plist"))
        let appOwnedFile: [String: Any] = [
            "Label": "com.test.ownedfile",
            "Program": home.appendingPathComponent("Applications/TestApp.app/Contents/Resources/not-a-program.txt").path,
        ]
        try PropertyListSerialization.data(fromPropertyList: appOwnedFile, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.ownedfile.plist"))
        let noProgram: [String: Any] = ["Label": "com.test.noprogram", "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: noProgram, format: .xml, options: 0).write(to: agents.appendingPathComponent("com.test.noprogram.plist"))
        let brokenPrefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fm.createDirectory(at: brokenPrefs, withIntermediateDirectories: true)
        try Data("this is not a property list".utf8).write(to: brokenPrefs.appendingPathComponent("com.test.broken.plist"))

        // Confirmed leftovers (two locations) and one uncertain leftover.
        _ = try file("Library/Caches/com.leftover.app/left.bin", size: 4_000)
        _ = try preference("Library/Preferences/com.leftover.app.plist")
        _ = try file("Library/Caches/com.single.app/only.bin", size: 4_000)
        _ = try preference("Library/Preferences/com.other.app.plist")

        // Fake app bundle with bundle identifier, version and support files.
        let app = try dir("Applications/TestApp.app/Contents")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.test.app",
            "CFBundleName": "Test App",
            "CFBundleDisplayName": "Test App",
            "CFBundleShortVersionString": "2.1",
            "CFBundleVersion": "21",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        _ = try file("Applications/TestApp.app/Contents/MacOS/TestApp", size: 20_000)
        _ = try file("Library/Caches/com.test.app/cache.bin", size: 7_000)
        _ = try file("Library/Logs/com.test.app/test.log", size: 2_000)
        _ = try preference("Library/Preferences/com.test.app.plist")
        _ = try file("Library/Application Support/com.test.app/data.bin", size: 9_000)
        _ = try dir("Library/Containers/com.test.app/Data")
        _ = try file("Library/Containers/com.test.app/Data/user.db", size: 5_000)
        _ = try dir("Library/Group Containers/group.com.test.shared")
        _ = try file("Library/Group Containers/group.com.test.shared/shared.bin", size: 8_000)

        // Fake Opera profile, extension, history database and download record.
        let opera = try dir("Library/Application Support/com.operasoftware.Opera/Default")
        _ = try file("Library/Application Support/com.operasoftware.Opera/Default/Cache/cache.bin", size: 8_000)
        _ = try file("Library/Application Support/com.operasoftware.Opera/Default/Cookies", size: 1_200)
        _ = try file("Library/Application Support/com.operasoftware.Opera/Default/Local Storage/leveldb/data.ldb", size: 2_000)
        let historyDB = opera.appendingPathComponent("History")
        try fm.createDirectory(at: opera, withIntermediateDirectories: true)
        for sql in [
            "CREATE TABLE downloads(id INTEGER PRIMARY KEY, target_path TEXT);",
            "CREATE TABLE downloads_url_chains(id INTEGER, chain_index INTEGER, url TEXT);",
            "CREATE TABLE downloads_slices(id INTEGER, offset INTEGER);",
            "INSERT INTO downloads(id, target_path) VALUES (1, '\(home.appendingPathComponent("Downloads/report.pdf").path)');",
            "INSERT INTO downloads_url_chains(id, chain_index, url) VALUES (1, 0, 'https://example.test/report.pdf');"
        ] {
            let result = Shell.run(FsTool.sqlitePath, [historyDB.path, sql], timeout: 10)
            if !result.succeeded { throw TestFailure.failed("sqlite setup failed: \(result.stderr)") }
        }
        let prefs: [String: Any] = ["extensions": ["settings": ["abcdefghijklmnop": ["state": 1]]]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: opera.appendingPathComponent("Preferences"))
        let ext = try dir("Library/Application Support/com.operasoftware.Opera/Default/Extensions/abcdefghijklmnop/1.2.3")
        let manifest: [String: Any] = ["name": "Test Extension", "version": "1.2.3", "manifest_version": 3]
        try JSONSerialization.data(withJSONObject: manifest).write(to: ext.appendingPathComponent("manifest.json"))

        // Safari download history (binary plist with one record).
        _ = try dir("Library/Safari")
        let safariDownloads: [[String: Any]] = [["URL": "https://example.test/report.pdf", "Path": home.appendingPathComponent("Downloads/report.pdf").path]]
        try PropertyListSerialization.data(fromPropertyList: safariDownloads, format: .binary, options: 0)
            .write(to: home.appendingPathComponent("Library/Safari/Downloads.plist"))

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
    }
}


final class MockUpdateProtocol: URLProtocol {
    nonisolated(unsafe) static var payload: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let payload = MockUpdateProtocol.payload else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AsyncBox<T>: @unchecked Sendable {
    var value: T?
}

func runAsync<T>(_ operation: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return box.value!
}
