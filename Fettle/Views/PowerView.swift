import SwiftUI

struct PowerView: View {
    @ObservedObject var model: PowerModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(
                    module: .power,
                    title: L("Sleep & Power"),
                    message: L("Fettle reads the power settings macOS reports for battery and plugged-in use. It never changes them and never touches sleep or recovery files.")
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
                if model.isReading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Reading %@…", L("Battery details"))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                if let snapshot = model.snapshot {
                    HStack(spacing: 10) {
                        IconTile(symbol: "waveform.path.ecg", tint: Palette.accent, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("Live battery readings are in Mac Health")).font(.system(size: 11, weight: .semibold))
                            Text(L("Charge, battery condition, cycles and live trends are read there without changing anything."))
                                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Open Mac Health")) { app.select(.health); app.health.page = .battery }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .card(padding: 12, radius: 12)
                    SummaryCard(
                        label: L("Battery"),
                        value: snapshot.batteryPercent ?? "—",
                        caption: snapshot.batteryDescription,
                        facts: [
                            SummaryFact(icon: "clock", label: L("Battery details"), value: snapshot.batteryTimeRemaining ?? "—", tint: Palette.blue, help: L("Battery health is in System Settings.")),
                            SummaryFact(icon: "powerplug", label: L("Power adapter"), value: snapshot.differences.isEmpty ? L("Same as battery") : L("%d differences", snapshot.differences.count), tint: Palette.amber, help: L("Battery mode vs. power adapter"))
                        ]
                    )
                    differencesCard(snapshot)
                    allSettingsCard(snapshot)
                    filesCard(snapshot)
                    HStack {
                        Button(L("Open Battery Settings")) { model.openBatterySettings() }
                            .buttonStyle(.bordered)
                        Button(L("Open Energy Saver")) { model.openEnergySaver() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text(L("These files support safe sleep. They are outside cleanup and cannot be removed here."))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary).frame(maxWidth: 340, alignment: .trailing)
                    }
                } else if !model.isReading {
                    EmptyStateView(icon: "bolt.batteryblock", title: L("Power settings could not be read."), message: L("Read-only, no changes"), actionTitle: L("Refresh power settings"), action: { Task { await model.refresh() } })
                        .frame(height: 320)
                }
            }
            .padding(26)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .background(Palette.background(scheme))
        .task {
            if model.snapshot == nil { await model.refresh() }
        }
    }

    private func differencesCard(_ snapshot: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L("Differences"), subtitle: L("Only differences between battery and plugged-in mode are shown here. Settings that match are left out."))
            if snapshot.differences.isEmpty {
                Text(L("Battery and power adapter use the same settings."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                settingsTable(snapshot.differences)
            }
        }
        .card(padding: 18, radius: 16)
    }

    private func allSettingsCard(_ snapshot: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showAll.toggle() }
            } label: {
                HStack {
                    SectionTitle(title: L("All power settings"), subtitle: L("Setting") + " · " + L("Battery mode") + " · " + L("Power adapter"))
                    Spacer()
                    Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAll {
                settingsTable(snapshot.settings)
            }
        }
        .card(padding: 18, radius: 16)
    }

    private func settingsTable(_ settings: [PowerSetting]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Setting")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Battery mode")).frame(width: 150, alignment: .leading)
                Text(L("Power adapter")).frame(width: 150, alignment: .leading)
            }
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.vertical, 5)
            Divider()
            ForEach(settings) { setting in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(setting.label).font(.system(size: 11.5, weight: .medium))
                        Text(setting.explanation).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(setting.batteryValue ?? "—").font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 150, alignment: .leading)
                    Text(setting.acValue ?? "—").font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 150, alignment: .leading)
                }
                .padding(.vertical, 6)
                Divider().opacity(0.3)
            }
        }
    }

    private func filesCard(_ snapshot: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L("Sleep and recovery files"), subtitle: L("These files support safe sleep. They are outside cleanup and cannot be removed here."))
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Hibernation file")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(snapshot.hibernationFile ?? "—").font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(snapshot.hibernationFileSize.map { Fmt.bytes($0) } ?? L("Unavailable")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Swap used")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(snapshot.swapUsed ?? "—").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                Spacer()
                Image(systemName: "snowflake").font(.system(size: 24, weight: .light)).foregroundStyle(Palette.blue.opacity(0.5))
            }
        }
        .card(padding: 18, radius: 16)
    }
}
