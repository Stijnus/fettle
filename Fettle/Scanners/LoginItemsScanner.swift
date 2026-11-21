import Foundation
import AppKit

enum LoginItemsScanner {
    struct Result: Sendable {
        var records: [LoginRecord]
        var notes: [String]
        var skipped: [SkippedItem]
        var duration: TimeInterval
        var readableBackgroundItems: Bool
        var backgroundTimedOut: Bool = false
    }

    static func scan(
        launchAgentsReady: @escaping @Sendable ([LoginRecord]) -> Void,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> Result {
        let started = Date()
        var records: [LoginRecord] = []
        var notes: [String] = []
        var skipped: [SkippedItem] = []

        progress(ScanProgress(fraction: 0.2, message: L("Scanning %@…", L("User LaunchAgents"))))
        records += scanLaunchAgents(notes: &notes, skipped: &skipped, cancelled: cancelled)

        launchAgentsReady(records)
        progress(ScanProgress(fraction: 0.65, message: L("Scanning %@…", L("Background items"))))
        let background = scanBackgroundItems(notes: &notes)
        records += background.records

        if background.timedOut {
            notes.append(L("macOS took too long to report background items. Scan again to retry."))
        } else if !background.readable {
            notes.append(L("Fettle could not read the system background item list. It shows user LaunchAgents instead."))
        }
        notes.append(L("Only user LaunchAgents can be switched here. System daemons are never touched."))
        records.sort { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source == .userLaunchAgent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return Result(records: records, notes: notes, skipped: skipped, duration: Date().timeIntervalSince(started), readableBackgroundItems: background.readable, backgroundTimedOut: background.timedOut)
    }

    // MARK: LaunchAgents

    static func scanLaunchAgents(
        notes: inout [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [LoginRecord] {
        let disabled = disabledLabels()
        var records: [LoginRecord] = []
        for url in FileSafety.children(of: AppPaths.launchAgents) where url.pathExtension.lowercased() == "plist" {
            if cancelled() { break }
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                skipped.append(SkippedItem(path: PathDisplay.short(url.path), reason: L("Could not read this profile"), category: .loginItem))
                continue
            }
            guard let label = (plist["Label"] as? String), !label.isEmpty else { continue }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [String])?.first)
            let loaded = launchctlLoaded(label: label)
            let isDisabled = disabled.contains(label)
            let status: String
            let enabled: Bool
            if isDisabled {
                status = L("Disabled")
                enabled = false
            } else if loaded {
                status = L("Loaded")
                enabled = true
            } else {
                status = L("Not loaded, file present")
                enabled = true
            }
            let publisher = publisherName(for: url, program: program)
            records.append(LoginRecord(
                id: "agent|\(label)",
                name: label,
                publisher: publisher,
                source: .userLaunchAgent,
                manageability: .manageable,
                status: status,
                path: url.path,
                identifier: label,
                detail: program.map { L("Program: %@", $0) },
                enabled: enabled
            ))
        }
        if records.isEmpty {
            notes.append(L("No login items were found."))
        }
        return records
    }

    static func publisherName(for url: URL, program: String?) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let program, program.contains(".app/") {
            let parts = program.components(separatedBy: ".app/")
            if let app = parts.first {
                return app.components(separatedBy: "/").last ?? name
            }
        }
        let components = name.components(separatedBy: ".")
        if components.count > 2 { return components.prefix(2).joined(separator: ".") }
        return name
    }

    static func launchctlLoaded(label: String) -> Bool {
        let result = Shell.run(FsTool.launchctlPath, ["print", "gui/\(getuid())/\(label)"], timeout: 6)
        return result.succeeded
    }

    static func disabledLabels() -> Set<String> {
        let result = Shell.run(FsTool.launchctlPath, ["print-disabled", "gui/\(getuid())"], timeout: 6)
        guard result.succeeded else { return [] }
        var labels = Set<String>()
        let pattern = #""([^"]+)"\s*=>\s*disabled"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.stdout.startIndex..<result.stdout.endIndex, in: result.stdout)
            for match in regex.matches(in: result.stdout, range: range) {
                if let labelRange = Range(match.range(at: 1), in: result.stdout) {
                    labels.insert(String(result.stdout[labelRange]))
                }
            }
        }
        return labels
    }

    static func setEnabled(_ record: LoginRecord, enabled: Bool) -> (Bool, String) {
        guard record.manageability == .manageable, let path = record.path else {
            return (false, L("This entry is managed by macOS or another app. Use Login Items & Extensions settings."))
        }
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(record.identifier)"
        if enabled {
            _ = Shell.run(FsTool.launchctlPath, ["enable", target], timeout: 8)
            let bootstrap = Shell.run(FsTool.launchctlPath, ["bootstrap", domain, path], timeout: 10)
            if bootstrap.succeeded || bootstrap.stderr.localizedCaseInsensitiveContains("already loaded") {
                return (true, L("%@ is now %@.", record.name, L("Enabled")))
            }
            return (false, bootstrap.stderr.isEmpty ? L("The action could not be completed.") : bootstrap.stderr)
        } else {
            let disable = Shell.run(FsTool.launchctlPath, ["disable", target], timeout: 8)
            _ = Shell.run(FsTool.launchctlPath, ["bootout", target], timeout: 10)
            if disable.succeeded {
                return (true, L("%@ is now %@.", record.name, L("Disabled")))
            }
            return (false, disable.stderr.isEmpty ? L("The action could not be completed.") : disable.stderr)
        }
    }

    // MARK: Background items (read-only)

    struct BackgroundResult {
        var records: [LoginRecord]
        var readable: Bool
        var timedOut: Bool = false
    }

    /// `sfltool dumpbtm` is usually quick, but its first run after login or a
    /// change can take over a minute while the background task database is
    /// rebuilt. The scan runs off the main thread, so wait for it.
    static let backgroundItemTimeout: TimeInterval = 120

    static func scanBackgroundItems(notes: inout [String]) -> BackgroundResult {
        let run = Shell.run(FsTool.sfltoolPath, ["dumpbtm"], timeout: backgroundItemTimeout)
        if run.timedOut {
            return BackgroundResult(records: [], readable: false, timedOut: true)
        }
        guard run.succeeded, !run.stdout.isEmpty else {
            notes.append(L("Background item details are limited without Full Disk Access."))
            return BackgroundResult(records: [], readable: false)
        }
        return BackgroundResult(records: parseBackgroundItems(run.stdout), readable: true)
    }

    /// Splits `sfltool dumpbtm` output into one block per item. Item headers
    /// are indented (` #1:`), and the same item can be listed under several
    /// UIDs, so items are de-duplicated by their UUID.
    static func backgroundItemBlocks(_ output: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var inItem = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isItemHeader = trimmed.hasPrefix("#") && trimmed.hasSuffix(":") && Int(trimmed.dropFirst().dropLast()) != nil
            let isSectionBreak = trimmed.hasPrefix("=====") || trimmed.hasPrefix("Records for UID")
            if isItemHeader || isSectionBreak {
                if inItem, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = []
                inItem = isItemHeader
                continue
            }
            if inItem { current.append(line) }
        }
        if inItem, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    static func parseBackgroundItems(_ output: String) -> [LoginRecord] {
        var records: [LoginRecord] = []
        var seen = Set<String>()
        for block in backgroundItemBlocks(output) {
            // sfltool prints "(null)" for values it does not have.
            let fields = parseFields(block).filter { $0.value != "(null)" }
            guard let identifier = fields["Identifier"] else { continue }
            let name = fields["Name"] ?? identifier
            let uuid = fields["UUID"] ?? "\(identifier)|\(name)"
            guard seen.insert(uuid).inserted else { continue }
            let developer = fields["Developer Name"] ?? fields["Team Identifier"] ?? L("Unknown")
            let type = fields["Type"] ?? ""
            let disposition = fields["Disposition"] ?? ""
            let enabled = disposition.contains("enabled") ? true : (disposition.contains("disabled") ? false : nil)
            let url = fields["URL"]
            records.append(LoginRecord(
                id: "btm|\(uuid)",
                name: name,
                publisher: developer,
                source: .backgroundItem,
                manageability: .systemManaged,
                status: disposition.isEmpty ? L("Unknown") : disposition.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""),
                path: url,
                identifier: identifier,
                detail: type,
                enabled: enabled
            ))
        }
        return records
    }

    static func parseFields(_ block: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in block.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }
}
