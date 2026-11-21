import Foundation
import AppKit

/// Reads installed apps and asks each app's own update feed whether a newer
/// version exists. Nothing is downloaded, installed or executed. App Store and
/// Apple apps are reported with a route to the store or Software Update instead
/// of a fabricated version.
enum UpdaterScanner {
    struct Result: Sendable {
        var records: [AppUpdateRecord]
        var skipped: [SkippedItem]
        var notes: [String]
        var duration: TimeInterval
    }

    private static let maximumFeedBytes = 4 * 1024 * 1024
    private static let maximumConcurrentChecks = 6
    /// Ephemeral and cookie-free so a vendor feed never sees browser cookies,
    /// logins or a persistent cache from another task.
    private static let feedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    static func scan(
        extraFolders: [String],
        ignoreList: [String],
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) async -> Result {
        let started = Date()
        var skipped: [SkippedItem] = []
        let roots = UninstallerScanner.roots(extraFolders: extraFolders)
        let appURLs = UninstallerScanner.discoverApps(in: roots, skipped: &skipped, cancelled: cancelled)
        var notes: [String] = [
            L("Fettle reads each app's own update feed. It never installs an update itself; installation stays with the vendor, the App Store or Software Update."),
            L("Only app names, versions and feed addresses are used. No document, password or browsing data is read."),
        ]
        if appURLs.isEmpty {
            progress(ScanProgress(fraction: 1, message: L("No apps found")))
            return Result(records: [], skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started))
        }

        var records: [AppUpdateRecord] = []
        var ignoredCount = 0
        let total = appURLs.count
        var index = 0
        while index < appURLs.count {
            if cancelled() { break }
            let end = min(index + maximumConcurrentChecks, appURLs.count)
            let chunk = Array(appURLs[index..<end])
            progress(ScanProgress(
                fraction: 0.03 + 0.92 * Double(index) / Double(total),
                message: L("Checking %d of %d…", index + 1, total)
            ))
            let chunkRecords = await withTaskGroup(of: AppUpdateRecord?.self) { group in
                for url in chunk {
                    group.addTask {
                        if cancelled() { return nil }
                        if DiskCleanupScanner.isIgnored(url, ignoreList) { return nil }
                        return await inspect(appAt: url)
                    }
                }
                var output: [AppUpdateRecord] = []
                for await record in group {
                    if let record { output.append(record) }
                }
                return output
            }
            ignoredCount += chunk.count - chunkRecords.count
            records.append(contentsOf: chunkRecords)
            index = end
        }

        if cancelled() {
            progress(ScanProgress(fraction: 0.98, message: L("Scan cancelled")))
        } else {
            progress(ScanProgress(fraction: 0.98, message: L("Preparing…")))
        }

        records.sort { lhs, rhs in
            if lhs.status.sortRank != rhs.status.sortRank { return lhs.status.sortRank < rhs.status.sortRank }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
        if ignoredCount > 0 {
            notes.append(L("%d apps were skipped because they are on the ignore list.", ignoredCount))
        }
        let available = records.filter { $0.status == .available }.count
        if available == 0 && !cancelled() {
            notes.append(L("No newer versions were reported by the app feeds that could be reached."))
        }
        return Result(records: records, skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started))
    }

    private static func inspect(appAt url: URL) async -> AppUpdateRecord? {
        guard let info = FileSafety.appBundleInfo(at: url) else { return nil }
        let bundle = Bundle(url: url)
        let build = (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let isSystem = info.id.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
        let running = SystemActions.isRunning(appAt: url)
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        let isMAS = FileManager.default.fileExists(atPath: receipt.path)
        let feedString = (bundle?.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var record = AppUpdateRecord(
            bundleURL: url,
            appName: info.name,
            bundleID: info.id,
            currentVersion: info.version,
            currentBuild: build,
            latestVersion: nil,
            latestBuild: nil,
            status: .noChannel,
            source: .none,
            feedURL: nil,
            downloadURL: nil,
            releaseNotes: nil,
            releaseDate: nil,
            updateSize: nil,
            minimumSystemVersion: nil,
            errorMessage: nil,
            isRunning: running,
            isSystem: isSystem,
            checkedAt: Date()
        )

        // An App Store receipt decides first: Apple apps such as Xcode that
        // came from the App Store update there, not through Software Update.
        if isMAS {
            record.status = .appStore
            record.source = .appStore
            record.errorMessage = L("This app is managed by the App Store.")
            return record
        }

        if isSystem {
            record.status = .appleSoftwareUpdate
            record.source = .appleSoftwareUpdate
            record.errorMessage = L("Apple apps update through Software Update.")
            return record
        }

        guard let feedString, !feedString.isEmpty, let feedURL = resolvedURL(feedString, relativeTo: url) else {
            record.status = .noChannel
            record.source = .none
            if usesSparkleWithoutPublishedFeed(url) {
                record.errorMessage = L("This app updates itself but keeps its feed address inside the app. Use the app's own Check for Updates command.")
            } else {
                record.errorMessage = L("This app does not publish a readable update feed.")
            }
            return record
        }

        record.feedURL = feedURL
        do {
            let data = try await loadFeed(feedURL)
            let entries = try parseAppcast(data)
            let compatible = entries.filter { entry in
                guard let minimum = entry.minimumSystemVersion else { return true }
                return MacOSVersion.isAtLeast(minimum)
            }
            guard let latest = compatible.max(by: {
                let left = $0.shortVersion ?? $0.buildVersion ?? ""
                let right = $1.shortVersion ?? $1.buildVersion ?? ""
                return VersionOrder.compare(left, right) == .orderedAscending
            }) else {
                if let first = entries.first, let minimum = first.minimumSystemVersion, !MacOSVersion.isAtLeast(minimum) {
                    record.status = .incompatible
                    record.minimumSystemVersion = minimum
                    record.latestVersion = first.shortVersion ?? first.buildVersion
                    record.errorMessage = L("This update requires macOS %@ or later.", minimum)
                } else {
                    record.status = .noChannel
                    record.errorMessage = L("The update feed did not contain a usable version.")
                }
                return record
            }

            let latestVersion = latest.shortVersion ?? latest.buildVersion ?? ""
            record.latestVersion = latestVersion
            record.latestBuild = latest.buildVersion
            record.downloadURL = latest.downloadURL ?? latest.link
            record.releaseNotes = latest.releaseNotes
            record.releaseDate = latest.releaseDate
            record.updateSize = latest.updateSize
            record.minimumSystemVersion = latest.minimumSystemVersion
            record.source = .sparkle

            if latestVersion.isEmpty {
                record.status = .noChannel
                record.errorMessage = L("The update feed did not contain a usable version.")
            } else if VersionOrder.isNewer(latestVersion, than: info.version) {
                record.status = .available
                record.errorMessage = nil
            } else {
                record.status = .upToDate
                record.errorMessage = L("The app's feed reports this version is current.")
            }
        } catch {
            record.status = .failed
            record.source = .sparkle
            record.errorMessage = error.localizedDescription
        }
        return record
    }

    /// Some apps ship Sparkle but set the feed address in code, so it is not
    /// in Info.plist. They still update themselves.
    static func usesSparkleWithoutPublishedFeed(_ appURL: URL) -> Bool {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path)
    }

    // MARK: Feed loading

    static func loadFeed(_ url: URL) async throws -> Data {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Fettle/1.2 (macOS)", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await feedSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppcastError.malformed(L("The update feed returned HTTP %d.", http.statusCode))
            }
            data = body
        }
        guard !data.isEmpty else { throw AppcastError.empty }
        guard data.count <= maximumFeedBytes else { throw AppcastError.tooLarge }
        return data
    }

    // MARK: Appcast parsing

    static func parseAppcast(_ data: Data) throws -> [AppcastEntry] {
        let parser = XMLParser(data: data)
        let delegate = AppcastDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? L("The update feed could not be read.")
            throw AppcastError.malformed(reason)
        }
        guard !delegate.items.isEmpty else { throw AppcastError.empty }
        return delegate.items.filter { ($0.shortVersion ?? $0.buildVersion) != nil }
    }

    // MARK: Helpers

    private static func resolvedURL(_ value: String, relativeTo appURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: trimmed, relativeTo: appURL)?.absoluteURL
    }
}

// MARK: - XML delegate

private struct RawAppcastItem {
    var shortVersion: String?
    var buildVersion: String?
    var title: String?
    var link: String?
    var enclosureURL: String?
    var enclosureShortVersion: String?
    var enclosureBuildVersion: String?
    var enclosureLength: String?
    var notes: String?
    var releaseDate: Date?
    var minimumSystemVersion: String?
}

private final class AppcastDelegate: NSObject, XMLParserDelegate {
    var items: [AppcastEntry] = []
    private var current: RawAppcastItem?
    private var text = ""
    private var inItem = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        if name == "item" {
            inItem = true
            current = RawAppcastItem()
            text = ""
            return
        }
        guard inItem else { return }
        if name == "enclosure" {
            current?.enclosureURL = attribute(attributeDict, "url")
            current?.enclosureShortVersion = attribute(attributeDict, "sparkle:shortVersionString")
            current?.enclosureBuildVersion = attribute(attributeDict, "sparkle:version")
            current?.enclosureLength = attribute(attributeDict, "length")
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem else { return }
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item" {
            if let current {
                let notes = current.notes.map { plainText($0) }
                items.append(AppcastEntry(
                    shortVersion: current.shortVersion ?? current.enclosureShortVersion,
                    buildVersion: current.buildVersion ?? current.enclosureBuildVersion,
                    title: current.title,
                    link: current.link.flatMap(URL.init(string:)),
                    downloadURL: current.enclosureURL.flatMap(URL.init(string:)),
                    releaseNotes: notes,
                    releaseDate: current.releaseDate,
                    updateSize: current.enclosureLength.flatMap { Int64($0) },
                    minimumSystemVersion: current.minimumSystemVersion
                ))
            }
            current = nil
            inItem = false
            text = ""
            return
        }
        guard current != nil else { return }
        switch name {
        case "sparkle:shortversionstring", "shortversionstring":
            current?.shortVersion = value.isEmpty ? nil : value
        case "sparkle:version", "version":
            current?.buildVersion = value.isEmpty ? nil : value
        case "title":
            current?.title = value.isEmpty ? nil : value
        case "link":
            current?.link = value.isEmpty ? nil : value
        case "description":
            current?.notes = value.isEmpty ? nil : value
        case "pubdate":
            current?.releaseDate = Self.parseDate(value)
        case "sparkle:minimumsystemversion", "minimumsystemversion":
            current?.minimumSystemVersion = value.isEmpty ? nil : value
        case "sparkle:releasenoteslink", "releasenoteslink":
            if current?.notes == nil, !value.isEmpty {
                current?.notes = value
            }
        default:
            break
        }
        text = ""
    }

    private func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let exact = attributes[name] { return exact }
        let target = name.lowercased()
        return attributes.first { $0.key.lowercased() == target || $0.key.lowercased().hasSuffix(target) }?.value
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formats = ["EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss Z"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

// MARK: - Text helpers

func plainText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "</(li|ul|ol|div|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    if joined.count > 4_000 {
        return String(joined.prefix(4_000)) + "…"
    }
    return joined
}
