import Foundation
import SwiftUI

// MARK: - Values

enum SecurityStatus: String, Sendable {
    case good, attention, info, unknown
}

/// Where a check's setting lives. Fettle only opens the page; macOS changes it.
enum SecurityRoute: String, Sendable {
    case firewall, privacySecurity, fileVault, softwareUpdate, sharing

    var title: String {
        switch self {
        case .firewall: return L("Open Firewall Settings")
        case .privacySecurity: return L("Open Privacy & Security")
        case .fileVault: return L("Open FileVault Settings")
        case .softwareUpdate: return L("Open Software Update")
        case .sharing: return L("Open Sharing Settings")
        }
    }

    var urls: [String] {
        switch self {
        case .firewall:
            return ["x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
                    "x-apple.systempreferences:com.apple.Network-Settings.extension"]
        case .privacySecurity:
            return [SystemSettingsPane.privacy.rawValue]
        case .fileVault:
            return ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
                    SystemSettingsPane.privacy.rawValue]
        case .softwareUpdate:
            return ["x-apple.systempreferences:com.apple.Software-Update-Settings.extension"]
        case .sharing:
            return ["x-apple.systempreferences:com.apple.Sharing-Settings.extension"]
        }
    }
}

struct SecurityCheck: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var value: String
    var detail: String
    var status: SecurityStatus
    var route: SecurityRoute?
}

struct FirewallApp: Identifiable, Sendable, Equatable {
    var id: String { path }
    var path: String
    var allowsIncoming: Bool

    var name: String { SecurityReader.displayName(forExecutable: path) ?? path }
}

enum SocketExposure: String, Sendable {
    case thisMac, localLink, network

    var rank: Int {
        switch self {
        case .thisMac: return 0
        case .localLink: return 1
        case .network: return 2
        }
    }

    var title: String {
        switch self {
        case .thisMac: return L("This Mac only")
        case .localLink: return L("Nearby devices")
        case .network: return L("Network")
        }
    }
}

struct NetworkSocket: Identifiable, Sendable, Equatable {
    var proto: String
    var localAddress: String
    var localPort: String
    var remoteAddress: String
    var remotePort: String
    var state: String
    var processName: String
    var pid: Int32

    var id: String { "\(pid)|\(proto)|\(localAddress).\(localPort)|\(remoteAddress).\(remotePort)" }
    var listenerKey: String { "\(pid):\(localPort)" }
    var exposure: SocketExposure { SecurityReader.exposure(of: localAddress) }
    var boundTo: String { localAddress == "*" ? L("All interfaces") : localAddress }
    var service: String? { SecurityReader.sharingService(port: localPort) }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [processName, localAddress, localPort, remoteAddress, remotePort, String(pid), service ?? ""]
            .contains { $0.lowercased().contains(q) }
    }
}

struct SecuritySnapshot: Sendable {
    var checks: [SecurityCheck]
    var firewallApps: [FirewallApp]
    var listeners: [NetworkSocket]
    var connections: [NetworkSocket]
    /// Sharing ports that accepted a loopback connection at the last full refresh.
    var sharingPorts: [String]
    var readAt: Date
    var networkReadAt: Date
    var notes: [String]

    var attentionCount: Int { checks.filter { $0.status == .attention }.count }
    var goodCount: Int { checks.filter { $0.status == .good }.count }
    var networkListeners: [NetworkSocket] { listeners.filter { $0.exposure != .thisMac } }
}

// MARK: - Model

@MainActor
final class SecurityModel: ObservableObject {
    @Published var snapshot: SecuritySnapshot?
    @Published var isReading = false
    @Published var isLive = true
    /// Listener keys that appeared after the first reading in this session.
    @Published private(set) var newListenerKeys: Set<String> = []

    private var knownListenerKeys: Set<String>?
    private var liveTask: Task<Void, Never>?
    static let liveInterval: UInt64 = 5

    func refresh() async {
        guard !isReading else { return }
        isReading = true
        let result = await Task.detached(priority: .userInitiated) { SecurityReader.read() }.value
        noteListeners(result.listeners)
        snapshot = result
        isReading = false
    }

    func refreshNetwork() async {
        guard var current = snapshot, !isReading else { return }
        let network = await Task.detached(priority: .utility) { SecurityReader.readNetwork() }.value
        guard network.error == nil else { return }
        noteListeners(network.listeners)
        current.listeners = network.listeners
        current.connections = network.connections
        current.networkReadAt = Date()
        if let index = current.checks.firstIndex(where: { $0.id == "sharing" }) {
            current.checks[index] = SecurityReader.sharingCheck(network.listeners, openPorts: current.sharingPorts)
        }
        snapshot = current
    }

    private func noteListeners(_ listeners: [NetworkSocket]) {
        let keys = Set(listeners.map(\.listenerKey))
        if let known = knownListenerKeys {
            newListenerKeys.formUnion(keys.subtracting(known))
            newListenerKeys.formIntersection(keys)
            knownListenerKeys = known.union(keys)
        } else {
            knownListenerKeys = keys
        }
    }

    /// Refreshes sockets every few seconds while the Security page is visible.
    func startLive() {
        stopLive()
        guard isLive else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SecurityModel.liveInterval * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshNetwork()
            }
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    func setLive(_ on: Bool) {
        isLive = on
        if on { startLive() } else { stopLive() }
    }

    func open(_ route: SecurityRoute) {
        for url in route.urls where SystemActions.open(url) { return }
        SystemActions.openSettings(.privacy)
    }
}
