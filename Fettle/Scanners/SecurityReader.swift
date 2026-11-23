import Foundation
import Darwin

/// Reads the Mac's built-in protections and open network sockets. Every probe
/// is read-only and works without administrator rights. Fettle is not an
/// antivirus and never changes a security setting; it reports what macOS
/// already does and links to the page where the user can change it.
enum SecurityReader {
    static let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    static let fdesetupPath = "/usr/bin/fdesetup"
    static let csrutilPath = "/usr/bin/csrutil"
    static let spctlPath = "/usr/sbin/spctl"
    static let lsofPath = "/usr/sbin/lsof"
    static let xprotectBundle = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
    static let xprotectRemediator = "/Library/Apple/System/Library/CoreServices/XProtect.app"
    static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    static let commercePlist = "/Library/Preferences/com.apple.commerce.plist"

    /// XProtect normally updates every few weeks. After this long without one,
    /// the check asks the user to confirm that security responses install.
    static let xprotectStaleDays = 90

    // MARK: Full read

    static func read() -> SecuritySnapshot {
        var notes: [String] = []
        var checks: [SecurityCheck] = []

        // Firewall
        let global = Shell.run(firewallTool, ["--getglobalstate"], timeout: 8)
        let firewall = global.succeeded ? parseFirewallState(global.stdout) : nil
        checks.append(firewallCheck(firewall))
        let stealth = Shell.run(firewallTool, ["--getstealthmode"], timeout: 8)
        checks.append(stealthCheck(stealth.succeeded ? parseStealthMode(stealth.stdout) : nil, firewallOn: firewall?.isOn ?? false))
        let signed = Shell.run(firewallTool, ["--getallowsigned"], timeout: 8)
        if signed.succeeded {
            checks.append(signedCheck(parseAllowSigned(signed.stdout)))
        }
        let list = Shell.run(firewallTool, ["--listapps"], timeout: 10)
        let firewallApps = list.succeeded ? parseFirewallApps(list.stdout) : []
        if !list.succeeded { notes.append(L("The firewall's app list could not be read.")) }

        // Disk, system and app protections
        let fde = Shell.run(fdesetupPath, ["status"], timeout: 8)
        checks.append(fileVaultCheck(fde.succeeded ? parseFileVault(fde.stdout) : nil))
        let csr = Shell.run(csrutilPath, ["status"], timeout: 8)
        checks.append(sipCheck(csr.succeeded ? parseSIP(csr.stdout) : nil))
        let gatekeeper = Shell.run(spctlPath, ["--status"], timeout: 8)
        checks.append(gatekeeperCheck(parseGatekeeper(gatekeeper.combined)))

        // XProtect
        let definitions = bundleInfo(xprotectBundle)
        let remediator = bundleInfo(xprotectRemediator)
        checks.append(xprotectCheck(definitions: definitions, remediator: remediator, now: Date()))

        // Updates
        let updatePrefs = readPlist(softwareUpdatePlist)
        let commercePrefs = readPlist(commercePlist)
        checks.append(contentsOf: updateChecks(softwareUpdate: updatePrefs, commerce: commercePrefs))

        // Network
        let network = readNetwork()
        if let error = network.error { notes.append(error) }
        let sharingPorts = probeSharingPorts()
        checks.append(sharingCheck(network.listeners, openPorts: sharingPorts))

        notes.append(L("Fettle is not an antivirus. macOS scans apps with XProtect and Gatekeeper; Fettle shows their status and never changes a security setting."))
        notes.append(L("Network activity lists TCP sockets of apps running as you. System services are not shown without administrator rights; Fettle never asks for them."))

        return SecuritySnapshot(
            checks: checks,
            firewallApps: firewallApps,
            listeners: network.listeners,
            connections: network.connections,
            sharingPorts: sharingPorts,
            readAt: Date(),
            networkReadAt: Date(),
            notes: notes
        )
    }

    /// The cheap part that the live view refreshes every few seconds.
    ///
    /// `lsof` is used rather than `netstat`: recent macOS returns an empty
    /// socket table to `netstat` when it runs on behalf of an app that is not
    /// signed by Apple. Without administrator rights `lsof` sees the current
    /// user's processes, which is what Fettle reports.
    static func readNetwork() -> (listeners: [NetworkSocket], connections: [NetworkSocket], error: String?) {
        let result = Shell.run(lsofPath, ["-nP", "-iTCP", "-FpcnT"], timeout: 8)
        // lsof exits with 1 when nothing matches.
        guard !result.timedOut, result.status == 0 || (result.status == 1 && result.stdout.isEmpty) else {
            return ([], [], L("Network sockets could not be read.") + (result.timedOut ? " (timeout)" : ""))
        }
        var names: [Int32: String] = [:]
        let sockets = parseLsof(result.stdout).map { socket -> NetworkSocket in
            var resolved = socket
            if let cached = names[socket.pid] {
                resolved.processName = cached
            } else {
                let name = processName(pid: socket.pid, fallback: socket.processName)
                names[socket.pid] = name
                resolved.processName = name
            }
            return resolved
        }
        return (groupListeners(sockets), sockets.filter { $0.state == "ESTABLISHED" }.sorted(by: connectionOrder), nil)
    }

    /// Connects to each sharing port on the loopback address. A port that
    /// accepts is served by a sharing service. Only run on a full refresh, so
    /// the services' own logs are not filled by the live view.
    static func probeSharingPorts(timeoutMilliseconds: Int32 = 250) -> [String] {
        sharingProbePorts.filter { port in
            guard let number = UInt16(port) else { return false }
            return loopbackAccepts(port: number, timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    static let sharingProbePorts = ["22", "445", "548", "5900", "3283", "3031"]

    static func loopbackAccepts(port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, timeoutMilliseconds) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    // MARK: Parsers (pure, covered by the self-test)

    struct FirewallState: Equatable { var isOn: Bool; var blocksAll: Bool }

    static func parseFirewallState(_ text: String) -> FirewallState? {
        if let range = text.range(of: #"State = (\d)"#, options: .regularExpression) {
            let digit = text[range].last.flatMap { Int(String($0)) } ?? -1
            switch digit {
            case 0: return FirewallState(isOn: false, blocksAll: false)
            case 1: return FirewallState(isOn: true, blocksAll: false)
            case 2: return FirewallState(isOn: true, blocksAll: true)
            default: break
            }
        }
        let lower = text.lowercased()
        if lower.contains("is enabled") { return FirewallState(isOn: true, blocksAll: false) }
        if lower.contains("is disabled") { return FirewallState(isOn: false, blocksAll: false) }
        return nil
    }

    static func parseStealthMode(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("stealth mode is on") || lower.contains("stealth mode enabled") { return true }
        if lower.contains("stealth mode is off") || lower.contains("stealth mode disabled") { return false }
        return nil
    }

    static func parseAllowSigned(_ text: String) -> (builtIn: Bool?, downloaded: Bool?) {
        var builtIn: Bool?
        var downloaded: Bool?
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            let value: Bool? = lower.contains("enabled") ? true : (lower.contains("disabled") ? false : nil)
            if lower.contains("built-in") { builtIn = value }
            if lower.contains("downloaded") { downloaded = value }
        }
        return (builtIn, downloaded)
    }

    static func parseFirewallApps(_ text: String) -> [FirewallApp] {
        var apps: [FirewallApp] = []
        var pendingPath: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^\d+ : "#, options: .regularExpression) {
                pendingPath = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let path = pendingPath, line.hasPrefix("(") {
                let lower = line.lowercased()
                apps.append(FirewallApp(path: path, allowsIncoming: !lower.contains("block")))
                pendingPath = nil
            }
        }
        return apps
    }

    enum FileVaultState: Equatable { case on, off, encrypting, decrypting }

    static func parseFileVault(_ text: String) -> FileVaultState? {
        let lower = text.lowercased()
        if lower.contains("encryption in progress") { return .encrypting }
        if lower.contains("decryption in progress") { return .decrypting }
        if lower.contains("filevault is on") { return .on }
        if lower.contains("filevault is off") { return .off }
        return nil
    }

    enum SIPState: Equatable { case enabled, disabled, custom }

    static func parseSIP(_ text: String) -> SIPState? {
        let lower = text.lowercased()
        guard lower.contains("system integrity protection status") else { return nil }
        if lower.contains("custom configuration") || lower.contains("unknown") { return .custom }
        if lower.contains("status: enabled") { return .enabled }
        if lower.contains("status: disabled") { return .disabled }
        return nil
    }

    static func parseGatekeeper(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("assessments enabled") { return true }
        if lower.contains("assessments disabled") { return false }
        return nil
    }

    /// Parses `lsof -F pcnT` output: a `p` line per process, then one `f`
    /// line per file with `n` (name) and `T` (TCP info such as `ST=LISTEN`).
    static func parseLsof(_ text: String) -> [NetworkSocket] {
        var sockets: [NetworkSocket] = []
        var pid: Int32 = 0
        var command = ""
        var name: String?
        var state: String?

        func flush() {
            defer { name = nil; state = nil }
            guard let name, let state, pid > 0 else { return }
            let parts = name.components(separatedBy: "->")
            let local = splitEndpoint(parts[0])
            let remote = parts.count > 1 ? splitEndpoint(parts[1]) : (address: "*", port: "*")
            sockets.append(NetworkSocket(
                proto: local.address.contains(":") || local.address.hasPrefix("[") ? "tcp6" : "tcp4",
                localAddress: local.address,
                localPort: local.port,
                remoteAddress: remote.address,
                remotePort: remote.port,
                state: state,
                processName: command,
                pid: pid
            ))
        }

        for line in text.components(separatedBy: .newlines) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value) ?? 0
                command = ""
            case "c":
                command = value
            case "f":
                flush()
            case "n":
                name = value
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default:
                break
            }
        }
        flush()
        return sockets
    }

    /// lsof writes `address:port`, with IPv6 addresses in brackets.
    static func splitEndpoint(_ value: String) -> (address: String, port: String) {
        guard let colon = value.lastIndex(of: ":") else { return (value, "") }
        var address = String(value[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return (address, String(value[value.index(after: colon)...]))
    }

    static func exposure(of address: String) -> SocketExposure {
        let lower = address.lowercased()
        if lower == "127.0.0.1" || lower.hasPrefix("127.") || lower == "::1" || lower.hasPrefix("::1%") || lower.contains("%lo0") {
            return .thisMac
        }
        if lower.hasPrefix("fe80:") { return .localLink }
        return .network
    }

    /// tcp4 and tcp6 sockets of the same process and port are one listener.
    static func groupListeners(_ sockets: [NetworkSocket]) -> [NetworkSocket] {
        var seen: [String: NetworkSocket] = [:]
        var order: [String] = []
        for socket in sockets where socket.state == "LISTEN" {
            let key = "\(socket.pid):\(socket.localPort)"
            if var existing = seen[key] {
                // Keep the widest exposure.
                if socket.exposure.rank > existing.exposure.rank {
                    existing.localAddress = socket.localAddress
                }
                if existing.proto != socket.proto { existing.proto = "tcp46" }
                seen[key] = existing
            } else {
                seen[key] = socket
                order.append(key)
            }
        }
        return order.compactMap { seen[$0] }.sorted { a, b in
            if a.exposure.rank != b.exposure.rank { return a.exposure.rank > b.exposure.rank }
            if a.processName.lowercased() != b.processName.lowercased() { return a.processName.lowercased() < b.processName.lowercased() }
            return (Int(a.localPort) ?? 0) < (Int(b.localPort) ?? 0)
        }
    }

    static func connectionOrder(_ a: NetworkSocket, _ b: NetworkSocket) -> Bool {
        if a.processName.lowercased() != b.processName.lowercased() { return a.processName.lowercased() < b.processName.lowercased() }
        return a.remoteAddress < b.remoteAddress
    }

    /// Well-known ports of the sharing services macOS can turn on.
    static func sharingService(port: String) -> String? {
        switch port {
        case "22": return L("Remote Login (SSH)")
        case "445": return L("File Sharing (SMB)")
        case "548": return L("File Sharing (AFP)")
        case "5900": return L("Screen Sharing")
        case "3283": return L("Remote Management")
        case "3031": return L("Remote Apple Events")
        case "7000": return L("AirPlay Receiver")
        default: return nil
        }
    }

    // MARK: Checks

    static func firewallCheck(_ state: FirewallState?) -> SecurityCheck {
        guard let state else {
            return SecurityCheck(id: "firewall", title: L("Firewall"), value: L("Unknown"), detail: L("macOS did not report the firewall state."), status: .unknown, route: .firewall)
        }
        if !state.isOn {
            return SecurityCheck(id: "firewall", title: L("Firewall"), value: L("Off"), detail: L("Apps and services can accept incoming connections from the network. Turn the firewall on in Network settings."), status: .attention, route: .firewall)
        }
        if state.blocksAll {
            return SecurityCheck(id: "firewall", title: L("Firewall"), value: L("On, blocking all"), detail: L("All incoming connections are blocked except basic network services."), status: .good, route: .firewall)
        }
        return SecurityCheck(id: "firewall", title: L("Firewall"), value: L("On"), detail: L("Incoming connections are allowed only for the apps listed below and signed software you allowed."), status: .good, route: .firewall)
    }

    static func stealthCheck(_ on: Bool?, firewallOn: Bool) -> SecurityCheck {
        guard let on else {
            return SecurityCheck(id: "stealth", title: L("Stealth mode"), value: L("Unknown"), detail: L("macOS did not report stealth mode."), status: .unknown, route: .firewall)
        }
        return SecurityCheck(
            id: "stealth",
            title: L("Stealth mode"),
            value: on ? L("On") : L("Off"),
            detail: on ? L("This Mac does not answer pings or probes from unknown senders.") : (firewallOn ? L("Optional. When on, the Mac ignores pings and probes. Useful on public networks.") : L("Stealth mode only works while the firewall is on.")),
            status: on ? .good : .info,
            route: .firewall
        )
    }

    static func signedCheck(_ value: (builtIn: Bool?, downloaded: Bool?)) -> SecurityCheck {
        let downloaded = value.downloaded ?? false
        return SecurityCheck(
            id: "signed",
            title: L("Allow signed software"),
            value: downloaded ? L("Built-in and downloaded") : ((value.builtIn ?? false) ? L("Built-in only") : L("Off")),
            detail: downloaded ? L("Signed apps you download may accept incoming connections without asking. This is the macOS default.") : L("Downloaded apps must be allowed one by one."),
            status: .info,
            route: .firewall
        )
    }

    static func fileVaultCheck(_ state: FileVaultState?) -> SecurityCheck {
        switch state {
        case .on:
            return SecurityCheck(id: "filevault", title: L("FileVault"), value: L("On"), detail: L("The startup disk is encrypted. Data stays unreadable without your password or recovery key."), status: .good, route: .fileVault)
        case .off:
            return SecurityCheck(id: "filevault", title: L("FileVault"), value: L("Off"), detail: L("The startup disk is not encrypted. Anyone with the Mac can read its files. Turn it on in Privacy & Security."), status: .attention, route: .fileVault)
        case .encrypting:
            return SecurityCheck(id: "filevault", title: L("FileVault"), value: L("Encrypting…"), detail: L("Encryption is in progress and continues in the background."), status: .info, route: .fileVault)
        case .decrypting:
            return SecurityCheck(id: "filevault", title: L("FileVault"), value: L("Decrypting…"), detail: L("FileVault is being turned off."), status: .attention, route: .fileVault)
        case nil:
            return SecurityCheck(id: "filevault", title: L("FileVault"), value: L("Unknown"), detail: L("macOS did not report the FileVault state."), status: .unknown, route: .fileVault)
        }
    }

    static func sipCheck(_ state: SIPState?) -> SecurityCheck {
        switch state {
        case .enabled:
            return SecurityCheck(id: "sip", title: L("System Integrity Protection"), value: L("On"), detail: L("System files and apps are protected from changes, even by administrators."), status: .good, route: nil)
        case .disabled:
            return SecurityCheck(id: "sip", title: L("System Integrity Protection"), value: L("Off"), detail: L("System files can be modified. It can only be turned back on from macOS Recovery with `csrutil enable`."), status: .attention, route: nil)
        case .custom:
            return SecurityCheck(id: "sip", title: L("System Integrity Protection"), value: L("Custom"), detail: L("Some protections are turned off. Turn it fully on from macOS Recovery with `csrutil enable`."), status: .attention, route: nil)
        case nil:
            return SecurityCheck(id: "sip", title: L("System Integrity Protection"), value: L("Unknown"), detail: L("macOS did not report the protection state."), status: .unknown, route: nil)
        }
    }

    static func gatekeeperCheck(_ on: Bool?) -> SecurityCheck {
        switch on {
        case true?:
            return SecurityCheck(id: "gatekeeper", title: L("Gatekeeper"), value: L("On"), detail: L("Apps are checked for a valid signature and Apple's malware scan before they first open."), status: .good, route: .privacySecurity)
        case false?:
            return SecurityCheck(id: "gatekeeper", title: L("Gatekeeper"), value: L("Off"), detail: L("Any app can open without a signature check. Turn it back on in Privacy & Security."), status: .attention, route: .privacySecurity)
        case nil:
            return SecurityCheck(id: "gatekeeper", title: L("Gatekeeper"), value: L("Unknown"), detail: L("macOS did not report the Gatekeeper state."), status: .unknown, route: .privacySecurity)
        }
    }

    struct BundleInfo: Equatable { var version: String?; var modified: Date? }

    static func xprotectCheck(definitions: BundleInfo?, remediator: BundleInfo?, now: Date) -> SecurityCheck {
        guard let definitions, let version = definitions.version else {
            return SecurityCheck(id: "xprotect", title: L("XProtect malware protection"), value: L("Unknown"), detail: L("The XProtect definitions could not be read."), status: .unknown, route: .softwareUpdate)
        }
        var parts = [L("Definitions %@", version)]
        if let remediatorVersion = remediator?.version { parts.append(L("Remediator %@", remediatorVersion)) }
        var detail = L("Built into macOS. It blocks known malware when files open and scans in the background.")
        var status: SecurityStatus = .good
        if let modified = definitions.modified {
            let days = max(0, Int(now.timeIntervalSince(modified) / 86_400))
            detail += " " + L("Last updated %@.", Fmt.relativeDay(modified, now: now))
            if days > xprotectStaleDays {
                status = .attention
                detail += " " + L("No update in %d days. Check that security responses install automatically.", days)
            }
        }
        return SecurityCheck(id: "xprotect", title: L("XProtect malware protection"), value: parts.joined(separator: " · "), detail: detail, status: status, route: .softwareUpdate)
    }

    static func updateChecks(softwareUpdate: [String: Any]?, commerce: [String: Any]?) -> [SecurityCheck] {
        func flag(_ dictionary: [String: Any]?, _ key: String, default value: Bool) -> Bool {
            if let bool = dictionary?[key] as? Bool { return bool }
            if let number = dictionary?[key] as? NSNumber { return number.boolValue }
            return value
        }
        let check = flag(softwareUpdate, "AutomaticCheckEnabled", default: true)
        let critical = flag(softwareUpdate, "CriticalUpdateInstall", default: true)
        let config = flag(softwareUpdate, "ConfigDataInstall", default: true)
        let macOS = flag(softwareUpdate, "AutomaticallyInstallMacOSUpdates", default: false)
        let appStore = flag(commerce, "AutoUpdate", default: false)

        let securityOn = check && critical && config
        var missing: [String] = []
        if !check { missing.append(L("checking for updates")) }
        if !critical || !config { missing.append(L("security responses and system files")) }
        let security = SecurityCheck(
            id: "security-updates",
            title: L("Automatic security updates"),
            value: securityOn ? L("On") : L("Off"),
            detail: securityOn
                ? L("XProtect definitions and Rapid Security Responses install automatically.")
                : L("Turned off: %@. Malware definitions may fall behind. Turn it on in Software Update → Automatic updates.", missing.joined(separator: ", ")),
            status: securityOn ? .good : .attention,
            route: .softwareUpdate
        )
        let macOSCheck = SecurityCheck(
            id: "macos-updates",
            title: L("Install macOS updates"),
            value: macOS ? L("Automatically") : L("Manually"),
            detail: macOS ? L("macOS updates install on their own, usually overnight.") : L("macOS updates wait until you install them in Software Update."),
            status: .info,
            route: .softwareUpdate
        )
        let storeCheck = SecurityCheck(
            id: "appstore-updates",
            title: L("App Store app updates"),
            value: appStore ? L("Automatically") : L("Manually"),
            detail: appStore ? L("Apps from the App Store update on their own.") : L("App Store apps update when you choose. App Updater lists other apps."),
            status: .info,
            route: .softwareUpdate
        )
        return [security, macOSCheck, storeCheck]
    }

    static func sharingCheck(_ listeners: [NetworkSocket], openPorts: [String]) -> SecurityCheck {
        let services = (openPorts + listeners.filter { $0.exposure != .thisMac }.map(\.localPort))
            .compactMap { sharingService(port: $0) }
        let unique = Array(NSOrderedSet(array: services)).compactMap { $0 as? String }
        if unique.isEmpty {
            return SecurityCheck(id: "sharing", title: L("Sharing services"), value: L("None listening"), detail: L("No Remote Login, Screen Sharing or File Sharing port is open to the network."), status: .good, route: .sharing)
        }
        return SecurityCheck(
            id: "sharing",
            title: L("Sharing services"),
            value: unique.joined(separator: ", "),
            detail: L("These services accept connections from the network. Turn off any you do not use in General → Sharing."),
            status: .info,
            route: .sharing
        )
    }

    // MARK: Helpers

    static func bundleInfo(_ path: String) -> BundleInfo? {
        let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        let dates = [path, infoURL.path].compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        return BundleInfo(version: version, modified: dates.max())
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// lsof shortens command names; the executable path gives the
    /// full name, and the outermost `.app` bundle gives the app's name.
    static func processName(pid: Int32, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let path = String(cString: buffer)
        return displayName(forExecutable: path) ?? fallback
    }

    static func displayName(forExecutable path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        if let app = components.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return components.last
    }
}
