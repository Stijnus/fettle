import Foundation

enum PowerReader {
    static func read() -> PowerSnapshot {
        let custom = Shell.run(FsTool.pmsetPath, ["-g", "custom"], timeout: 10)
        let batt = Shell.run(FsTool.pmsetPath, ["-g", "batt"], timeout: 10)
        var notes: [String] = [L("Read from pmset"), L("Read-only, no changes")]
        var sections: [String: [String: String]] = [:]
        var current = ""
        if custom.succeeded {
            for raw in custom.stdout.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasSuffix(":") {
                    current = line.replacingOccurrences(of: ":", with: "")
                    sections[current] = [:]
                    continue
                }
                guard !current.isEmpty else { continue }
                if let split = splitSetting(line) {
                    sections[current]?[split.key] = split.value
                }
            }
        } else {
            notes.append(L("Power settings could not be read.") + (custom.timedOut ? " (timeout)" : ""))
        }

        let batterySection = sections.first { $0.key.lowercased().contains("battery") }?.value ?? [:]
        let acSection = sections.first { $0.key.lowercased().contains("ac") || $0.key.lowercased().contains("charger") }?.value ?? [:]
        let keys = Set(batterySection.keys).union(acSection.keys)

        var settings: [PowerSetting] = []
        for key in keys.sorted(by: { keyOrder($0) < keyOrder($1) }) {
            let meta = describe(key)
            let batteryValue = batterySection[key].map { formatValue(key: key, value: $0) }
            let acValue = acSection[key].map { formatValue(key: key, value: $0) }
            settings.append(PowerSetting(
                key: key,
                label: meta.label,
                batteryValue: batteryValue,
                acValue: acValue,
                explanation: meta.explanation
            ))
        }

        var differences: [PowerSetting] = []
        for setting in settings where setting.batteryValue != setting.acValue {
            differences.append(setting)
        }

        var description = L("This Mac has no battery, or macOS did not report one.")
        var percent: String?
        var remaining: String?
        if batt.succeeded {
            for line in batt.stdout.components(separatedBy: .newlines) {
                let lower = line.lowercased()
                if lower.contains("now drawing from") {
                    if lower.contains("ac power") {
                        description = L("On power adapter")
                    } else if lower.contains("battery") {
                        description = L("On battery")
                    }
                }
                if line.contains("%") {
                    if let percentRange = line.range(of: #"\d{1,3}%"#, options: .regularExpression) {
                        percent = String(line[percentRange])
                    }
                    let parts = line.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    if let range = line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) {
                        remaining = L("%@ remaining", String(line[range]))
                    } else if let state = parts.firstIndex(of: "charging"), parts.indices.contains(state + 1) {
                        remaining = parts[state + 1]
                    } else if parts.contains("charged") {
                        remaining = L("Charged")
                    } else if parts.contains("discharging") {
                        remaining = L("On battery")
                    }
                }
            }
        } else {
            notes.append(L("Battery details") + " — " + L("Unavailable"))
        }

        let hibernationFile = settings.first { $0.key == "hibernatefile" }?.batteryValue
            ?? settings.first { $0.key == "hibernatefile" }?.acValue
          let hibernationSize: Int64? = {
            guard let path = hibernationFile, path.hasPrefix("/") else { return nil }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileSafety.allocatedSize(of: URL(fileURLWithPath: path))
        }()
        let swap = Shell.run("/usr/sbin/sysctl", ["vm.swapusage"], timeout: 5)
        var swapUsed: String?
        if swap.succeeded, let range = swap.stdout.range(of: #"used = [0-9.,]+[KMG]?"#, options: .regularExpression) {
            swapUsed = String(swap.stdout[range]).replacingOccurrences(of: "used = ", with: "")
        }

        if settings.isEmpty {
            notes.append(L("No power settings were reported."))
        }
        notes.append(L("These files support safe sleep. They are outside cleanup and cannot be removed here."))

        return PowerSnapshot(
            settings: settings,
            differences: differences,
            batteryDescription: description,
            batteryTimeRemaining: remaining,
            batteryPercent: percent,
            hibernationFile: hibernationFile,
            hibernationFileSize: hibernationSize,
            swapUsed: swapUsed,
            readAt: Date(),
            notes: notes
        )
    }

    static func splitSetting(_ line: String) -> (key: String, value: String)? {
        guard let lastSpace = line.lastIndex(of: " ") else { return nil }
        let key = String(line[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: lastSpace)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    static func keyOrder(_ key: String) -> Int {
        let order = ["sleep", "displaysleep", "disksleep", "hibernatemode", "standby", "powernap", "lowpowermode", "womp", "tcpkeepalive", "ttyskeepawake", "lessbright", "networkoversleep", "hibernatefile"]
        if let index = order.firstIndex(of: key) { return index }
        return 100
    }

    static func formatValue(key: String, value: String) -> String {
        if key == "hibernatefile" { return value }
        if let int = Int(value) {
            if ["sleep", "displaysleep", "disksleep", "standbydelaylow", "standbydelayhigh", "autopoweroffdelay", "highstandbythreshold"].contains(key) {
                if int == 0 { return L("Never") }
                if int < 60 { return L("%d minutes", int) }
                if int % 60 == 0 { return L("%d hours", int / 60) }
                return L("%d minutes", int)
            }
            if ["powernap", "standby", "womp", "tcpkeepalive", "ttyskeepawake", "lessbright", "autopoweroff", "lowpowermode", "networkoversleep"].contains(key) {
                return int == 0 ? L("Off") : L("On")
            }
            if key == "hibernatemode" {
                switch int {
                case 0: return L("0 — sleep only")
                case 3: return L("3 — safe sleep")
                case 25: return L("25 — hibernate")
                default: return "\(int)"
                }
            }
        }
        return value
    }

    static func describe(_ key: String) -> (label: String, explanation: String) {
        switch key {
        case "sleep":
            return (L("System sleep"), L("How long the Mac waits before sleeping."))
        case "displaysleep":
            return (L("Display sleep"), L("How long before the display turns off."))
        case "disksleep":
            return (L("Disk sleep"), L("How long before idle disks spin down."))
        case "hibernatemode":
            return (L("Hibernation mode"), L("Controls whether memory is written to disk before sleep."))
        case "standby":
            return (L("Standby"), L("Allows deeper power saving after extended sleep."))
        case "powernap":
            return (L("Power Nap"), L("Lets the Mac do small tasks while asleep."))
        case "lowpowermode":
            return (L("Low power mode"), L("Reduces background activity to save energy."))
        case "womp":
            return (L("Wake for network access"), L("Allows network wake-up while asleep."))
        case "tcpkeepalive":
            return (L("Keep network alive"), L("Keeps network connections alive during sleep."))
        case "ttyskeepawake":
            return (L("Stay awake for terminal"), L("Prevents sleep while a terminal session is active."))
        case "lessbright":
            return (L("Dim on battery"), L("Lowers display brightness when unplugged."))
        case "hibernatefile":
            return (L("Hibernation file"), L("Where the sleep image is stored, if one exists."))
        case "networkoversleep":
            return (L("Network over sleep"), L("Network behaviour during sleep."))
        case "autopoweroff":
            return (L("Auto power off"), L("Powers down after long sleep."))
        case "autopoweroffdelay":
            return (L("Auto power off delay"), L("How long before auto power off."))
        case "standbydelaylow", "standbydelayhigh":
            return (L("Standby delay"), L("How long before deep standby begins."))
        default:
            return (key, L("Reported by macOS."))
        }
    }
}
