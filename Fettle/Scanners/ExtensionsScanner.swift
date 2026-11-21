import Foundation
import AppKit

enum ExtensionsScanner {
    struct Result: Sendable {
        var records: [ExtensionRecord]
        var skipped: [SkippedItem]
        var notes: [String]
        var duration: TimeInterval
        var browserProfiles: [String]
    }

    static func scan(
        progress: @escaping @Sendable (ScanProgress) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> Result {
        let started = Date()
        var records: [ExtensionRecord] = []
        var skipped: [SkippedItem] = []
        var notes: [String] = []
        var profiles: [String] = []

        progress(ScanProgress(fraction: 0.15, message: L("Scanning %@…", L("System extensions"))))
        records += scanSystemExtensions(notes: &notes)
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        progress(ScanProgress(fraction: 0.4, message: L("Scanning %@…", L("Safari extensions"))))
        records += scanSafariExtensions(notes: &notes)
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        progress(ScanProgress(fraction: 0.55, message: L("Scanning %@…", L("Chrome"))))
        records += scanChromium(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            profileRoot: AppPaths.applicationSupport.appendingPathComponent("Google/Chrome", isDirectory: true),
            managementURL: "chrome://extensions",
            provider: "Google",
            profiles: &profiles,
            skipped: &skipped,
            cancelled: cancelled
        )
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        progress(ScanProgress(fraction: 0.7, message: L("Scanning %@…", L("Edge"))))
        records += scanChromium(
            bundleID: "com.microsoft.edgemac",
            appName: "Microsoft Edge",
            profileRoot: AppPaths.applicationSupport.appendingPathComponent("Microsoft Edge", isDirectory: true),
            managementURL: "edge://extensions",
            provider: "Microsoft",
            profiles: &profiles,
            skipped: &skipped,
            cancelled: cancelled
        )
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        progress(ScanProgress(fraction: 0.82, message: L("Scanning %@…", L("Opera"))))
        records += scanChromium(
            bundleID: "com.operasoftware.Opera",
            appName: "Opera",
            profileRoot: AppPaths.applicationSupport.appendingPathComponent("com.operasoftware.Opera", isDirectory: true),
            managementURL: "opera://extensions",
            provider: "Opera",
            profiles: &profiles,
            skipped: &skipped,
            cancelled: cancelled
        )
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        progress(ScanProgress(fraction: 0.92, message: L("Scanning %@…", L("Firefox"))))
        records += scanFirefox(profiles: &profiles, skipped: &skipped, cancelled: cancelled)
        if cancelled() { return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started) }

        records.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return kindOrder(lhs.kind) < kindOrder(rhs.kind) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        notes.append(L("Extension information is limited to what the system exposes."))
        notes.append(L("Chrome, Edge, Opera and Firefox profiles are read only where they are installed."))
        return result(records: records, skipped: skipped, notes: notes, profiles: profiles, started: started)
    }

    private static func result(records: [ExtensionRecord], skipped: [SkippedItem], notes: [String], profiles: [String], started: Date) -> Result {
        Result(records: records, skipped: skipped, notes: notes, duration: Date().timeIntervalSince(started), browserProfiles: Array(Set(profiles)).sorted())
    }

    static func kindOrder(_ kind: ExtensionRecord.Kind) -> Int {
        switch kind {
        case .system: return 0
        case .safari: return 1
        case .chromium: return 2
        case .firefox: return 3
        }
    }

    // MARK: System extensions

    static func scanSystemExtensions(notes: inout [String]) -> [ExtensionRecord] {
        let run = Shell.run(FsTool.systemExtensionsPath, ["list"], timeout: 15)
        guard run.succeeded else {
            notes.append(L("System extensions") + " — " + L("Unavailable"))
            return []
        }
        var records: [ExtensionRecord] = []
        var category = ""
        for line in run.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") {
                if let id = trimmed.split(separator: " ").dropFirst().first {
                    category = String(id)
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("enabled\t") || trimmed.contains("extension(s)") {
                continue
            }
            let parts = trimmed.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4 else { continue }
            let team = parts.count > 2 ? parts[2] : ""
            let bundleAndVersion = parts[3]
            guard let bundleID = bundleAndVersion.split(separator: " ").first.map(String.init) else { continue }
            var version = ""
            if let start = bundleAndVersion.firstIndex(of: "("), let end = bundleAndVersion.firstIndex(of: ")"), start < end {
                version = String(bundleAndVersion[bundleAndVersion.index(after: start)..<end]).components(separatedBy: "/").first ?? ""
            }
            let name = parts.count > 4 ? parts[4] : bundleID
            let state = parts.count > 5 ? parts[5] : ""
            let enabled: Bool? = state.contains("activated") ? true : (state.contains("terminated") || state.contains("disabled") ? false : nil)
            records.append(ExtensionRecord(
                id: "system|\(bundleID)",
                name: name,
                provider: team.isEmpty ? "Apple" : team,
                host: L("macOS"),
                version: version,
                enabled: enabled,
                kind: .system,
                path: nil,
                managementURL: "loginItems",
                note: category.components(separatedBy: ".").last?.replacingOccurrences(of: "_", with: " ").capitalized
            ))
        }
        return records
    }

    // MARK: Safari app extensions via pluginkit

    static func scanSafariExtensions(notes: inout [String]) -> [ExtensionRecord] {
        let run = Shell.run(FsTool.pluginkitPath, ["-m", "-v"], timeout: 15)
        guard run.succeeded else {
            notes.append(L("Safari data needs permission"))
            return scanSafariAppExtensions(notes: &notes)
        }
        var records: [ExtensionRecord] = []
        for line in run.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("+") || trimmed.hasPrefix("-") else { continue }
            let enabled = trimmed.hasPrefix("+")
            let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard body.lowercased().contains("safari") else { continue }
            let parts = body.components(separatedBy: "\t")
            let first = parts.first ?? body
            let tokens = first.split(separator: " ").map(String.init)
            guard let identifier = tokens.first else { continue }
            var path: String?
            if let range = body.range(of: #"/[^\t]+\.appex"#, options: .regularExpression) ?? body.range(of: #"/[^\t]+\.app"#, options: .regularExpression) {
                path = String(body[range])
            }
            let version = first.range(of: #"\(([^)]+)\)"#, options: .regularExpression).map { String(first[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? ""
            let name = identifier.split(separator: ".").last.map(String.init) ?? identifier
            records.append(ExtensionRecord(
                id: "safari|\(identifier)",
                name: name,
                provider: path?.components(separatedBy: "/").dropLast().last ?? "Safari",
                host: "Safari",
                version: version,
                enabled: enabled,
                kind: .safari,
                path: path,
                managementURL: "safari",
                note: L("System-managed")
            ))
        }
        if records.isEmpty {
            return scanSafariAppExtensions(notes: &notes)
        }
        return records
    }

    static func scanSafariAppExtensions(notes: inout [String]) -> [ExtensionRecord] {
        var records: [ExtensionRecord] = []
        let roots = [URL(fileURLWithPath: "/Applications"), AppPaths.applications]
        for root in roots {
            for appURL in FileSafety.children(of: root) where appURL.pathExtension.lowercased() == "app" {
                guard !FileSafety.isSymbolicLink(appURL) else { continue }
                let plugins = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
                for appex in FileSafety.children(of: plugins) where appex.pathExtension.lowercased() == "appex" {
                    guard let bundle = Bundle(url: appex) else { continue }
                    let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
                    let point = (extensionInfo?["NSExtensionPointIdentifier"] as? String) ?? ""
                    guard point.localizedCaseInsensitiveContains("Safari") else { continue }
                    let identifier = bundle.bundleIdentifier ?? appex.deletingPathExtension().lastPathComponent
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? identifier
                    let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
                    let hostApp = FileSafety.appBundleInfo(at: appURL)?.name ?? appURL.deletingPathExtension().lastPathComponent
                    records.append(ExtensionRecord(
                        id: "safari|\(identifier)",
                        name: name,
                        provider: hostApp,
                        host: "Safari",
                        version: version,
                        enabled: nil,
                        kind: .safari,
                        path: PathDisplay.short(appex.path),
                        managementURL: "safari",
                        note: L("System-managed")
                    ))
                }
            }
        }
        if records.isEmpty { notes.append(L("No extensions were reported.")) }
        return records
    }

    // MARK: Chromium browsers

    static func scanChromium(
        bundleID: String,
        appName: String,
        profileRoot: URL,
        managementURL: String,
        provider: String,
        profiles: inout [String],
        skipped: inout [SkippedItem],
        cancelled: @escaping @Sendable () -> Bool
    ) -> [ExtensionRecord] {
        guard FileManager.default.fileExists(atPath: profileRoot.path) else { return [] }
        var records: [ExtensionRecord] = []
        let profileDirectories = discoverChromiumProfiles(root: profileRoot)
        for profile in profileDirectories {
            if cancelled() { break }
            let profileName = profile.standardizedFileURL == profileRoot.standardizedFileURL ? "Default" : profile.lastPathComponent
            profiles.append("\(appName) — \(profileName)")
            let prefs = readPreferences(profile: profile)
            let extensionRoot = profile.appendingPathComponent("Extensions", isDirectory: true)
            for extensionDirectory in FileSafety.children(of: extensionRoot) {
                if cancelled() { break }
                let extensionID = extensionDirectory.lastPathComponent
                let versions = FileSafety.children(of: extensionDirectory).filter { FileSafety.isDirectory($0) }
                guard let versionDirectory = versions.max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) else { continue }
                let manifestURL = versionDirectory.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    skipped.append(SkippedItem(path: PathDisplay.short(manifestURL.path), reason: L("Could not read this profile"), category: .browserExtension))
                    continue
                }
                let rawName = (manifest["name"] as? String) ?? extensionID
                let name = resolveLocalizedName(rawName, manifest: manifest, extensionDirectory: versionDirectory)
                let version = (manifest["version"] as? String) ?? versionDirectory.lastPathComponent
                let enabled = chromiumEnabledState(prefs: prefs, extensionID: extensionID)
                records.append(ExtensionRecord(
                    id: "\(bundleID)|\(profileName)|\(extensionID)",
                    name: name,
                    provider: provider,
                    host: appName,
                    version: version,
                    enabled: enabled,
                    kind: .chromium,
                    path: PathDisplay.short(versionDirectory.path),
                    managementURL: managementURL,
                    note: profileName
                ))
            }
        }
        return records
    }

    static func discoverChromiumProfiles(root: URL) -> [URL] {
        let candidates = FileSafety.children(of: root).filter {
            FileSafety.isDirectory($0) && !["System Profile", "Guest Profile", "Crashpad", "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "BrowserMetrics", "WidevineCdm", "OptimizationHints", "extensions_crx_cache"].contains($0.lastPathComponent)
        }
        let withData = candidates.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Preferences").path) ||
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Extensions").path)
        }
        if withData.isEmpty {
            // Opera and some Chromium variants store the default profile at the root.
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Extensions").path) {
                return [root]
            }
        }
        return withData
    }

    static func readPreferences(profile: URL) -> [String: Any] {
        let url = profile.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func chromiumEnabledState(prefs: [String: Any], extensionID: String) -> Bool? {
        guard let extensions = prefs["extensions"] as? [String: Any],
              let settings = extensions["settings"] as? [String: Any],
              let entry = settings[extensionID] as? [String: Any] else { return nil }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let state = entry["state"] as? Int { return state == 1 }
        if let state = entry["state"] as? NSNumber { return state.intValue == 1 }
        return nil
    }

    static func resolveLocalizedName(_ raw: String, manifest: [String: Any], extensionDirectory: URL) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        guard let defaultLocale = manifest["default_locale"] as? String else { return key }
        for locale in [L10n.languageCode, defaultLocale, "en"] {
            let url = extensionDirectory.appendingPathComponent("_locales/\(locale)/messages.json")
            if let data = try? Data(contentsOf: url),
               let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entry = messages[key] as? [String: Any],
               let message = entry["message"] as? String {
                return message
            }
        }
        return key
    }

    // MARK: Firefox

    static func scanFirefox(profiles: inout [String], skipped: inout [SkippedItem], cancelled: @escaping @Sendable () -> Bool) -> [ExtensionRecord] {
        let root = AppPaths.applicationSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var records: [ExtensionRecord] = []
        for profile in FileSafety.children(of: root) where FileSafety.isDirectory(profile) {
            if cancelled() { break }
            let extensionsJSON = profile.appendingPathComponent("extensions.json")
            guard let data = try? Data(contentsOf: extensionsJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = object["addons"] as? [[String: Any]] else {
                continue
            }
            profiles.append("Firefox — \(profile.lastPathComponent)")
            for addon in addons {
                let type = (addon["type"] as? String) ?? ""
                guard type == "extension" else { continue }
                let id = (addon["id"] as? String) ?? ""
                guard !id.isEmpty else { continue }
                let name = (addon["name"] as? String) ?? id
                let version = (addon["version"] as? String) ?? ""
                let active = addon["active"] as? Bool
                let location = (addon["location"] as? String) ?? ""
                records.append(ExtensionRecord(
                    id: "firefox|\(profile.lastPathComponent)|\(id)",
                    name: name,
                    provider: "Mozilla",
                    host: "Firefox",
                    version: version,
                    enabled: active,
                    kind: .firefox,
                    path: location.isEmpty ? nil : location,
                    managementURL: "about:addons",
                    note: location
                ))
            }
        }
        return records
    }
}
