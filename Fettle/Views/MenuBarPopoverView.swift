import SwiftUI
import AppKit

struct MenuBarPopoverView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var health: HealthModel
    var actions: MenuBarActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    liveGrid
                    if !health.activeAlerts.isEmpty {
                        alertSection
                    }
                    statusCard
                    quickActions
                    toggles
                    if let message = health.message {
                        Text(message).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 368, height: 480)
        .background(Palette.background(scheme))
        .preferredColorScheme(app.settings.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Fettle").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(health.statusHeadline).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                actions.settings()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var liveGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                miniMetric(
                    icon: "cpu",
                    label: L("CPU"),
                    value: health.snapshot?.cpu.warmedUp == true ? HealthFormat.percent(health.snapshot!.cpu.usageFraction) : "—",
                    tint: Palette.blue
                )
                miniMetric(
                    icon: "memorychip",
                    label: L("Memory"),
                    value: health.snapshot.map { HealthFormat.percent($0.memory.usedFraction) } ?? "—",
                    tint: Palette.violet
                )
            }
            HStack(spacing: 8) {
                miniMetric(
                    icon: "internaldrive",
                    label: L("Disk free"),
                    value: health.snapshot?.rootVolume.map { Fmt.bytes($0.availableBytes) } ?? "—",
                    tint: Palette.accent
                )
                miniMetric(
                    icon: "network",
                    label: L("Network"),
                    value: health.snapshot.map { "\(HealthFormat.rate($0.network.receiveRate)) ↓" } ?? "—",
                    tint: Palette.green
                )
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(health.isMonitoring ? Palette.green : Palette.amber)
                    .frame(width: 5, height: 5)
                Text(health.isMonitoring ? L("Live · every %d s", max(1, app.settings.sampleIntervalSeconds)) : L("Live readings paused"))
                    .font(.system(size: 8.5, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                if let date = health.snapshot?.readAt {
                    Text(L("Updated %@", HealthFormat.time(date))).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
    }

    private func miniMetric(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            IconTile(symbol: icon, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Needs attention")).font(.system(size: 9.5, weight: .semibold)).tracking(0.4).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Text("\(health.activeAlerts.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.coral)
            }
            ForEach(health.activeAlerts.prefix(3)) { alert in
                Button {
                    app.select(.health)
                    health.page = alert.kind.page
                    actions.open()
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: alert.kind.symbol).font(.system(size: 10)).foregroundStyle(color(for: alert.severity)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(alert.detail).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(color(for: health.highestSeverity).opacity(0.08)))
    }

    private var statusCard: some View {
        VStack(spacing: 7) {
            statusRow(icon: "battery.75", label: L("Battery"), value: batteryText, tint: Palette.green)
            Divider().opacity(0.25)
            statusRow(icon: "internaldrive", label: L("Drive"), value: driveText, tint: driveColor)
            Divider().opacity(0.25)
            statusRow(icon: "cpu", label: L("Busiest process"), value: busiestText, tint: Palette.blue)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
    }

    private func statusRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
        }
    }

    private var batteryText: String {
        guard let battery = health.snapshot?.battery, battery.isPresent else { return L("No battery") }
        return "\(battery.percent ?? 0)% · \(battery.conditionText ?? L("Battery"))"
    }

    private var driveText: String {
        guard let drive = health.snapshot?.worstDrive else { return L("No drive details") }
        return "\(drive.smartLabel) · \(drive.model)"
    }

    private var driveColor: Color {
        color(for: health.snapshot?.worstDrive?.severity ?? .info)
    }

    private var busiestText: String {
        guard let process = health.snapshot?.topCPU.first else { return L("Collecting…") }
        return "\(process.displayName) · \(process.cpuText)"
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Quick actions")).font(.system(size: 9.5, weight: .semibold)).tracking(0.4).textCase(.uppercase).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                quickButton(icon: "sparkle.magnifyingglass", title: L("Scan")) { actions.scan() }
                quickButton(icon: "wind", title: L("Quit Selected Apps")) { actions.freeMemory() }
                quickButton(icon: "eject.fill", title: L("Eject All")) { actions.eject() }
            }
        }
    }

    private func quickButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.accent)
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.card(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var toggles: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(get: { app.settings.backgroundMode }, set: { app.setBackgroundMode($0) })) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Keep running in the menu bar")).font(.system(size: 10.5, weight: .medium))
                    Text(L("Closing the window leaves Fettle available here.")).font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            Toggle(isOn: Binding(get: { app.settings.openAtLogin }, set: { app.setOpenAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Open at login")).font(.system(size: 10.5, weight: .medium))
                    Text(app.loginItemStatus).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                actions.open()
            } label: {
                Label(L("Open Fettle"), systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.small)
            Spacer()
            Button {
                actions.quit()
            } label: {
                Text(L("Quit Fettle"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func color(for severity: HealthSeverity) -> Color {
        switch severity {
        case .critical: return Palette.coral
        case .warning: return Palette.amber
        case .good: return Palette.green
        case .info: return Palette.blue
        }
    }
}
