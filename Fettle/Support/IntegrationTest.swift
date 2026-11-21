import Foundation
import AppKit

enum IntegrationTest {
    static func runAndExit() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fettle-integration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("FETTLE_HOME", home.path, 1)
        setenv("FETTLE_TRASH_DIR", home.appendingPathComponent(".Trash").path, 1)
        setenv("FETTLE_TMP_DIR", home.appendingPathComponent("tmp").path, 1)
        setenv("FETTLE_APPS_ROOT", home.appendingPathComponent("Applications").path, 1)
        do { try Fixture.build(home: home) } catch {
            print("FAIL fixture: \(error)")
            exit(1)
        }
        MainActor.assumeIsolated {
            let app = AppModel()
            Task { @MainActor in
                var failures: [String] = []
                func check(_ condition: @autoclosure () -> Bool, _ message: String) {
                    if !condition() { failures.append(message) }
                }
                @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 20) async {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !condition() && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                await app.disk.runScan()
                check(!app.disk.items.isEmpty, "disk scan found nothing")
                let selectable = app.disk.items.filter { app.disk.isSelectable($0) && $0.category != .trash }.prefix(2)
                app.disk.selectedIDs = Set(selectable.map { $0.id })
                app.disk.requestRemoveSelected()
                if let request = app.disk.confirmation {
                    app.disk.performConfirmed(request)
                    await waitUntil { app.disk.outcome != nil && !app.disk.isWorking }
                    check(app.disk.outcome?.successCount == 2, "disk remove did not succeed for both items")
                } else {
                    failures.append("disk confirmation was not created")
                }

                let alias = home.appendingPathComponent("Desktop/Integration Alias")
                try? FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/no/such/integration")
                await app.maintenance.runScan()
                if let finding = app.maintenance.items.first(where: { $0.category == .brokenAlias && !$0.isInformational }) {
                    app.maintenance.selectedIDs = [finding.id]
                    app.maintenance.repairSelected()
                    if let request = app.maintenance.confirmation {
                        app.maintenance.performConfirmed(request)
                        await waitUntil { app.maintenance.outcome != nil && !app.maintenance.isWorking }
                        check(app.maintenance.outcome?.successCount == 1, "maintenance repair failed")
                    } else {
                        failures.append("maintenance confirmation missing")
                    }
                } else {
                    failures.append("maintenance did not find the broken alias")
                }

                await app.uninstaller.runScan()
                if let target = app.uninstaller.apps.first(where: { $0.bundleID == "com.test.app" }) {
                    app.uninstaller.selectedAppIDs = [target.id]
                    app.uninstaller.beginReview()
                    check(app.uninstaller.reviewAssociations.contains { $0.isAppData }, "uninstaller did not flag app data")
                    app.uninstaller.requestRemoval()
                    if let request = app.uninstaller.confirmation {
                        app.uninstaller.performConfirmed(request)
                        await waitUntil { app.uninstaller.outcome != nil && !app.uninstaller.isWorking }
                        check(app.uninstaller.outcome?.successCount ?? 0 > 0, "uninstaller removed nothing")
                        check(!FileManager.default.fileExists(atPath: target.bundleURL.path), "uninstaller left the app bundle")
                    } else {
                        failures.append("uninstaller confirmation missing")
                    }
                } else {
                    failures.append("uninstaller did not find the test app")
                }

                // App Updater: a disposable Sparkle app and a review with no automatic action.
                let updaterContents = home.appendingPathComponent("Applications/UpdaterIntegration.app/Contents", isDirectory: true)
                try? FileManager.default.createDirectory(at: updaterContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                let updaterFeed = home.appendingPathComponent("integration-updater-feed.xml")
                let updaterXML = """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                  <channel><item>
                    <sparkle:shortVersionString>4.2</sparkle:shortVersionString>
                    <sparkle:version>420</sparkle:version>
                    <description>Integration update</description>
                    <enclosure url="https://example.test/UpdaterIntegration.zip" length="2048" type="application/octet-stream"/>
                  </item></channel>
                </rss>
                """
                try? Data(updaterXML.utf8).write(to: updaterFeed)
                let updaterInfo: [String: Any] = [
                    "CFBundleIdentifier": "com.test.updaterintegration",
                    "CFBundleName": "Updater Integration",
                    "CFBundleShortVersionString": "4.0",
                    "CFBundleVersion": "400",
                    "CFBundlePackageType": "APPL",
                    "SUFeedURL": updaterFeed.absoluteString
                ]
                try? PropertyListSerialization.data(fromPropertyList: updaterInfo, format: .xml, options: 0)
                    .write(to: updaterContents.appendingPathComponent("Info.plist"))
                try? Data("x".utf8).write(to: updaterContents.appendingPathComponent("MacOS/UpdaterIntegration"))
                await app.updater.runScan()
                check(app.updater.selectedIDs.isEmpty, "updater selected items by default")
                if let record = app.updater.records.first(where: { $0.bundleID == "com.test.updaterintegration" }) {
                    check(record.status == .available, "updater did not find the integration update")
                    check(record.latestVersion == "4.2", "updater latest version wrong")
                    app.updater.selectedIDs = [record.id]
                    app.updater.beginReview()
                    check(app.updater.reviewRecords.count == 1, "updater review did not receive the selected app")
                    check(app.updater.reviewIDs.contains(record.id), "updater review selection missing")
                    app.updater.showReview = false
                    app.updater.deselectAll()
                } else {
                    failures.append("updater did not find the integration app")
                }

                await app.privacy.runScan()
                if let download = app.privacy.items.first(where: { $0.category == .downloadHistory && $0.bundleID == BrowserKind.opera.bundleID }) {
                    app.privacy.selectedIDs = [download.id]
                    app.privacy.requestClear()
                    if let request = app.privacy.confirmation {
                        app.privacy.performClear(request)
                        await waitUntil { app.privacy.outcome != nil && !app.privacy.isWorking }
                        check(app.privacy.outcome?.successCount == 1, "privacy download clear failed")
                        check(FileManager.default.fileExists(atPath: home.appendingPathComponent("Downloads/report.pdf").path), "privacy deleted a downloaded file")
                    } else {
                        failures.append("privacy confirmation missing")
                    }
                } else {
                    failures.append("privacy download row missing")
                }

                let deleteFile = home.appendingPathComponent("Documents/integration-delete.txt")
                try? Data("delete".utf8).write(to: deleteFile)
                app.permanentDelete.add(urls: [deleteFile])
                await waitUntil { !app.permanentDelete.isCalculating }
                app.permanentDelete.requestDelete()
                if let request = app.permanentDelete.confirmation {
                    app.permanentDelete.performConfirmed(request)
                    await waitUntil { app.permanentDelete.outcome != nil }
                    check(!FileManager.default.fileExists(atPath: deleteFile.path), "permanent delete left the file")
                } else {
                    failures.append("permanent delete confirmation missing")
                }

                await app.health.refreshNow()
                await waitUntil { app.health.snapshot != nil }
                check((app.health.snapshot?.memory.totalBytes ?? 0) > 0, "health memory reading is empty")
                check(app.health.snapshot?.rootVolume != nil, "health did not read the root volume")
                check(!(app.health.snapshot?.drives.isEmpty ?? true), "health did not read any drive")
                check(!(app.health.snapshot?.network.interfaces.isEmpty ?? true), "health did not read a network interface")
                check(!(app.health.snapshot?.processCount ?? 0 == 0), "health did not read any process")
                check(app.menuBar.isInstalled, "menu bar item was not installed")
                app.menuBar.sync()

                // Quit and Force Quit a disposable sleep process.
                func spawnSleep() -> Process? {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                    process.arguments = ["30"]
                    do { try process.run() } catch { return nil }
                    return process
                }
                if let sleep = spawnSleep() {
                    let reading = ProcessReading(
                        pid: sleep.processIdentifier,
                        name: "sleep",
                        path: "/bin/sleep",
                        isApplication: false,
                        cpuPercent: 0,
                        memoryBytes: 0,
                        status: L("Running"),
                        user: NSUserName(),
                        startedAt: Date(),
                        canManage: true
                    )
                    let result = ProcessActions.quit(reading, force: false)
                    check(result.0, "quit of disposable process failed: \(result.1)")
                    sleep.waitUntilExit()
                } else {
                    failures.append("could not spawn a disposable process")
                }
                if let sleep = spawnSleep() {
                    let reading = ProcessReading(
                        pid: sleep.processIdentifier,
                        name: "sleep",
                        path: "/bin/sleep",
                        isApplication: false,
                        cpuPercent: 0,
                        memoryBytes: 0,
                        status: L("Running"),
                        user: NSUserName(),
                        startedAt: Date(),
                        canManage: true
                    )
                    let result = ProcessActions.quit(reading, force: true)
                    check(result.0, "force quit of disposable process failed: \(result.1)")
                    sleep.waitUntilExit()
                }

                // Free Up Memory on a disposable process and verify the outcome is recorded.
                if let sleep = spawnSleep() {
                    await app.health.refreshNow()
                    let before = app.history.events.count
                    app.health.performFreeMemory(pids: [sleep.processIdentifier])
                    await waitUntil { app.history.events.count > before }
                    check(app.history.events.first?.module == .health, "Free Up Memory was not recorded")
                    check(!ProcessActions.isRunning(sleep.processIdentifier), "Free Up Memory left the disposable process running")
                    sleep.waitUntilExit()
                }

                // Eject a disposable disk image and verify it is gone.
                let image = home.appendingPathComponent("FettleFixture.dmg")
                let create = Shell.run("/usr/sbin/diskutil", ["image", "create", "blank", "-size", "128m", "-volumeName", "FettleFixture", "-fs", "APFS", image.path], timeout: 60)
                if create.succeeded {
                    let attach = Shell.run("/usr/sbin/diskutil", ["image", "attach", image.path], timeout: 30)
                    if attach.succeeded, let mountLine = attach.stdout.components(separatedBy: .newlines).last(where: { $0.contains("/Volumes/") }) {
                        let mountPath = mountLine.components(separatedBy: .whitespaces).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        await app.health.refreshNow(rescanDisks: true)
                        check(app.health.snapshot?.ejectableVolumes.contains { $0.name == "FettleFixture" } == true, "disk image was not listed as ejectable")
                        app.health.ejectAll()
                        await waitUntil { !app.health.isEjecting }
                        check(!FileManager.default.fileExists(atPath: mountPath), "Eject All left the disk image mounted")
                    } else {
                        failures.append("could not attach the disposable disk image")
                    }
                    _ = Shell.run("/usr/sbin/diskutil", ["eject", "/Volumes/FettleFixture"], timeout: 20)
                    try? FileManager.default.removeItem(at: image)
                } else {
                    failures.append("could not create the disposable disk image: \(create.combined)")
                }

                app.setBackgroundMode(true)
                check(app.settings.backgroundMode && app.settings.menuBarEnabled, "background mode did not keep the menu bar available")
                app.setBackgroundMode(false)
                app.refreshLoginItemStatus()
                check(!app.loginItemStatus.isEmpty, "login item status was empty")
                check(!app.history.events.isEmpty, "history was not recorded")
                let report: [String: Any] = ["passed": failures.isEmpty, "failures": failures, "history": app.history.events.count]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/fettle-integration.json"))
                }
                if failures.isEmpty {
                    print("Integration test passed (\(app.history.events.count) history events)")
                    exit(0)
                } else {
                    for failure in failures { print("FAIL \(failure)") }
                    exit(1)
                }
            }
            RunLoop.main.run()
        }
    }
}
