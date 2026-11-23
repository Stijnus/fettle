import SwiftUI

struct SecurityView: View {
    @ObservedObject var model: SecurityModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var networkTab: NetworkTab = .listening
    @State private var showFirewallApps = false

    enum NetworkTab: String, CaseIterable, Identifiable {
        case listening, connections
        var id: String { rawValue }
        var title: String { self == .listening ? L("Listening") : L("Connections") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(
                    module: .security,
                    title: L("Security"),
                    message: L("Fettle reads the protections built into macOS and the network sockets that are open right now. It never changes a security setting and is not an antivirus.")
                ) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .controlSize(.large)
                    .disabled(model.isReading)
                }
                if model.isReading && model.snapshot == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Reading %@…", L("Security"))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                if let snapshot = model.snapshot {
                    summary(snapshot)
                    if snapshot.attentionCount > 0 {
                        BannerView(
                            icon: "exclamationmark.shield.fill",
                            title: snapshot.attentionCount == 1 ? L("1 protection needs attention") : L("%d protections need attention", snapshot.attentionCount),
                            message: L("Each item below explains what is off and opens the System Settings page where you can turn it on."),
                            tint: Palette.amber
                        )
                    }
                    checksCard(snapshot)
                    networkCard(snapshot)
                    firewallAppsCard(snapshot)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.notes, id: \.self) { note in
                            InfoNote(icon: "info.circle", title: "", message: note)
                        }
                    }
                    .padding(.horizontal, 4)
                } else if !model.isReading {
                    EmptyStateView(icon: "lock.shield", title: L("Security status could not be read."), message: L("Read-only, no changes"), actionTitle: L("Refresh"), action: { Task { await model.refresh() } })
                        .frame(height: 320)
                }
            }
            .padding(26)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .background(Palette.background(scheme))
        .task {
            if model.snapshot == nil { await model.refresh() }
            model.startLive()
        }
        .onDisappear { model.stopLive() }
    }

    // MARK: Summary

    private func summary(_ snapshot: SecuritySnapshot) -> some View {
        let firewall = snapshot.checks.first { $0.id == "firewall" }
        let fileVault = snapshot.checks.first { $0.id == "filevault" }
        return SummaryCard(
            label: L("Protection"),
            value: snapshot.attentionCount == 0 ? L("All on") : L("%d to review", snapshot.attentionCount),
            caption: L("%d of %d checks are on", snapshot.goodCount, snapshot.checks.filter { $0.status == .good || $0.status == .attention }.count),
            facts: [
                SummaryFact(icon: "flame", label: L("Firewall"), value: firewall?.value ?? "—", tint: tint(firewall?.status ?? .unknown), action: { model.open(.firewall) }),
                SummaryFact(icon: "lock.fill", label: L("FileVault"), value: fileVault?.value ?? "—", tint: tint(fileVault?.status ?? .unknown), action: { model.open(.fileVault) }),
                SummaryFact(icon: "antenna.radiowaves.left.and.right", label: L("Open to the network"), value: "\(snapshot.networkListeners.count)", tint: Palette.blue, help: L("Listening sockets reachable from other devices, unless the firewall blocks them."), action: { networkTab = .listening }),
                SummaryFact(icon: "arrow.left.arrow.right", label: L("Active connections"), value: "\(snapshot.connections.count)", tint: Palette.violet, action: { networkTab = .connections })
            ]
        )
    }

    // MARK: Checks

    private func checksCard(_ snapshot: SecuritySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: L("Built-in protections"), subtitle: L("Read from macOS. Change them in System Settings."))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(snapshot.checks) { check in
                    checkRow(check)
                }
            }
        }
        .card(padding: 18, radius: 16)
    }

    private func checkRow(_ check: SecurityCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(check.status))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint(check.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(check.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(check.value)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(check.status == .attention ? Palette.amber : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Text(check.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let route = check.route {
                    Button(route.title) { model.open(route) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.top, 1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint(check.status).opacity(check.status == .attention ? 0.09 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint(check.status).opacity(check.status == .attention ? 0.28 : 0.10), lineWidth: 1))
    }

    // MARK: Network

    private func networkCard(_ snapshot: SecuritySnapshot) -> some View {
        let query = app.searchText
        let listeners = snapshot.listeners.filter { $0.matches(query) }
        let connections = snapshot.connections.filter { $0.matches(query) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SectionTitle(title: L("Network activity"), subtitle: L("TCP sockets of apps running as you, read with lsof. Nothing is blocked or changed."))
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle(isOn: Binding(get: { model.isLive }, set: { model.setLive($0) })) {
                        HStack(spacing: 5) {
                            Circle().fill(model.isLive ? Palette.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text(L("Live")).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(L("Refresh sockets every %d seconds while this page is open.", Int(SecurityModel.liveInterval)))
                    Text(L("Updated %@", snapshot.networkReadAt.formatted(date: .omitted, time: .standard)))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Picker("", selection: $networkTab) {
                ForEach(NetworkTab.allCases) { tab in
                    Text(tab == .listening ? L("Listening (%d)", listeners.count) : L("Connections (%d)", connections.count)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch networkTab {
            case .listening:
                listenersTable(listeners)
            case .connections:
                connectionsTable(connections)
            }
        }
        .card(padding: 18, radius: 16)
    }

    private func listenersTable(_ listeners: [NetworkSocket]) -> some View {
        VStack(spacing: 0) {
            tableHeader([(L("Process"), nil), (L("Port"), 70), (L("Bound to"), 170), (L("Reachable from"), 130)])
            if listeners.isEmpty {
                emptyRow(app.searchText.isEmpty ? L("No app is listening for connections.") : L("No results match the search."))
            }
            ForEach(listeners.prefix(300)) { socket in
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Text(socket.processName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(verbatim: String(socket.pid)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                        if model.newListenerKeys.contains(socket.listenerKey) {
                            Pill(text: L("New"), icon: "sparkle", tint: Palette.amber)
                        }
                        if let service = socket.service, socket.exposure != .thisMac {
                            Pill(text: service, tint: Palette.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(socket.localPort).font(.system(size: 11, design: .monospaced)).frame(width: 70, alignment: .leading)
                    Text(socket.boundTo).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(width: 170, alignment: .leading)
                    HStack {
                        Pill(text: socket.exposure.title, tint: exposureTint(socket.exposure))
                        Spacer(minLength: 0)
                    }
                    .frame(width: 130)
                }
                .padding(.vertical, 5)
                .contextMenu { copyMenu(socket) }
                Divider().opacity(0.3)
            }
        }
    }

    private func connectionsTable(_ connections: [NetworkSocket]) -> some View {
        VStack(spacing: 0) {
            tableHeader([(L("Process"), nil), (L("Remote address"), 260), (L("Port"), 70)])
            if connections.isEmpty {
                emptyRow(app.searchText.isEmpty ? L("No active connections.") : L("No results match the search."))
            }
            ForEach(connections.prefix(300)) { socket in
                HStack {
                    HStack(spacing: 6) {
                        Text(socket.processName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(verbatim: String(socket.pid)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(socket.remoteAddress).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(width: 260, alignment: .leading)
                    Text(socket.remotePort).font(.system(size: 11, design: .monospaced)).frame(width: 70, alignment: .leading)
                }
                .padding(.vertical, 5)
                .contextMenu { copyMenu(socket) }
                Divider().opacity(0.3)
            }
            if connections.count > 300 {
                emptyRow(L("Showing the first 300. Search to narrow the list."))
            }
        }
    }

    @ViewBuilder
    private func copyMenu(_ socket: NetworkSocket) -> some View {
        Button(L("Copy Process Name")) { copy(socket.processName) }
        Button(L("Copy Address")) {
            copy(socket.state == "LISTEN" ? "\(socket.localAddress):\(socket.localPort)" : "\(socket.remoteAddress):\(socket.remotePort)")
        }
        Divider()
        Button(L("Open Activity Monitor")) { SystemActions.openFolder(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.toast(L("Copied"))
    }

    // MARK: Firewall apps

    private func firewallAppsCard(_ snapshot: SecuritySnapshot) -> some View {
        let apps = snapshot.firewallApps.filter { app.searchText.isEmpty || $0.path.lowercased().contains(app.searchText.lowercased()) }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showFirewallApps.toggle() }
            } label: {
                HStack {
                    SectionTitle(title: L("Firewall app rules"), subtitle: L("%d apps · %d blocked", apps.count, apps.filter { !$0.allowsIncoming }.count))
                    Spacer()
                    Image(systemName: showFirewallApps ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showFirewallApps {
                VStack(spacing: 0) {
                    if apps.isEmpty { emptyRow(L("The firewall has no app rules.")) }
                    ForEach(apps) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Text(rule.path).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Pill(text: rule.allowsIncoming ? L("Allow incoming") : L("Block incoming"), tint: rule.allowsIncoming ? Palette.green : Palette.coral)
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.3)
                    }
                    HStack {
                        Spacer()
                        Button(L("Open Firewall Settings")) { model.open(.firewall) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .card(padding: 18, radius: 16)
    }

    // MARK: Helpers

    private func tableHeader(_ columns: [(String, CGFloat?)]) -> some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    if let width = column.1 {
                        Text(column.0).frame(width: width, alignment: .leading)
                    } else {
                        Text(column.0).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.vertical, 5)
            Divider()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private func symbol(_ status: SecurityStatus) -> String {
        switch status {
        case .good: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func tint(_ status: SecurityStatus) -> Color {
        switch status {
        case .good: return Palette.green
        case .attention: return Palette.amber
        case .info: return Palette.blue
        case .unknown: return Color.secondary
        }
    }

    private func exposureTint(_ exposure: SocketExposure) -> Color {
        switch exposure {
        case .thisMac: return Palette.green
        case .localLink: return Palette.blue
        case .network: return Palette.amber
        }
    }
}
