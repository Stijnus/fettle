import SwiftUI

struct LoginItemsView: View {
    @ObservedObject var model: LoginItemsModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme

    private var visibleManageable: [LoginRecord] {
        filter(model.manageable)
    }
    private var visibleBackground: [LoginRecord] {
        filter(model.background)
    }

    private func filter(_ records: [LoginRecord]) -> [LoginRecord] {
        let query = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.publisher.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .loginItems,
                title: L("Login Items"),
                message: L("Fettle reads user Login Agents and the background items macOS reports. User agents can be switched on or off; system-managed items open in System Settings.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.records.isEmpty ? L("Scan") : L("Scan Again"), systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)
                Button {
                    model.openSystemSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(L("Open Login Items & Extensions"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            if model.isScanning {
                ScanProgressBar(progress: model.progress, phase: model.phase) { model.cancel() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if model.records.isEmpty && !model.isScanning {
                EmptyStateView(icon: "person.badge.key", title: L("No login items were found."), message: L("Only user LaunchAgents can be switched here. System daemons are never touched."), actionTitle: L("Scan login items"), action: { model.startScan() })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            MetricTile(icon: "person.badge.key", label: L("User LaunchAgents"), value: "\(model.manageable.count)", caption: L("Manageable"), tint: Palette.accent)
                            MetricTile(icon: "gearshape.2", label: L("Background items"), value: "\(model.background.count)", caption: L("Managed by macOS"), tint: Palette.violet)
                            MetricTile(icon: "power", label: L("Loaded"), value: "\(model.records.filter { $0.status == L("Loaded") }.count)", caption: L("Startup status is read from launchd."), tint: Palette.green)
                            MetricTile(icon: "eye", label: L("Read-only"), value: L("System"), caption: L("System daemons are never touched."), tint: Palette.blue)
                        }
                        if model.backgroundItemsTimedOut {
                            BannerView(
                                icon: "clock",
                                title: L("macOS took too long to report background items."),
                                message: L("macOS took too long to report background items. Scan again to retry."),
                                tint: Palette.amber,
                                actionTitle: L("Scan Again"),
                                action: { model.startScan() }
                            )
                        } else if !model.readableBackgroundItems {
                            BannerView(
                                icon: "info.circle",
                                title: L("Background item details are limited without Full Disk Access."),
                                message: L("Fettle could not read the system background item list. It shows user LaunchAgents instead."),
                                tint: Palette.amber,
                                actionTitle: L("Open Privacy Settings"),
                                action: { SystemActions.openPrivacySettings() }
                            )
                        }
                        if !visibleManageable.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: L("User LaunchAgents"), subtitle: L("Only user LaunchAgents can be switched here. System daemons are never touched."))
                                VStack(spacing: 8) {
                                    ForEach(visibleManageable) { record in
                                        LoginRow(record: record) {
                                            model.requestToggle(record)
                                        } openSettings: {
                                            model.openSystemSettings()
                                        }
                                    }
                                }
                            }
                        }
                        if !visibleBackground.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: L("Background items"), subtitle: L("This entry is managed by macOS or another app. Use Login Items & Extensions settings."))
                                VStack(spacing: 8) {
                                    ForEach(visibleBackground.prefix(120)) { record in
                                        LoginRow(record: record) {
                                            model.openSystemSettings()
                                        } openSettings: {
                                            model.openSystemSettings()
                                        }
                                    }
                                }
                            }
                        }
                        if !model.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(Set(model.notes)).sorted(), id: \.self) { note in
                                    HStack(alignment: .top, spacing: 6) {
                                        Circle().fill(Palette.accent.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                                        Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Palette.background(scheme))
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) { model.performConfirmed(request) } onCancel: { model.confirmation = nil }
        }
        .sheet(item: $model.outcome) { outcome in OutcomeSheet(outcome: outcome) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 24) }
        }
        .task {
            if model.records.isEmpty && !model.isScanning { model.startScan() }
        }
    }
}

struct LoginRow: View {
    var record: LoginRecord
    var action: () -> Void
    var openSettings: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 11) {
            IconTile(symbol: record.manageability == .manageable ? "bolt.badge.clock.fill" : "gearshape.2.fill", tint: record.manageability == .manageable ? Palette.accent : Palette.violet, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if record.manageability == .manageable {
                        Pill(text: L("Manageable"), tint: Palette.accent)
                    } else {
                        Pill(text: L("Managed by macOS"), tint: Palette.violet)
                    }
                    if let enabled = record.enabled {
                        Pill(text: enabled ? L("Enabled") : L("Disabled"), tint: enabled ? Palette.green : .secondary)
                    }
                }
                Text("\(record.publisher) · \(record.status)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(record.manageability == .manageable ? L("Source: personal LaunchAgent") : L("Source: macOS background item"))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if record.manageability == .manageable, let enabled = record.enabled {
                Button(enabled ? L("Disable") : L("Enable"), action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(L("Open System Settings"), action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
        )
    }
}
