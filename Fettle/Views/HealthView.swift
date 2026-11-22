import SwiftUI
import AppKit
import Charts

struct HealthView: View {
    @ObservedObject var model: HealthModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showAllProcesses = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pageTabs
                if let message = model.message {
                    messageBanner(message)
                }
                Group {
                    switch model.page {
                    case .overview: overview
                    case .cpu: cpuPage
                    case .memory: memoryPage
                    case .disk: diskPage
                    case .battery: batteryPage
                    case .network: networkPage
                    case .activity: activityPage
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .background(Palette.background(scheme))
        .sheet(isPresented: $showAllProcesses) {
            AllProcessesSheet(model: model)
        }
        .sheet(isPresented: $model.showFreeMemory) {
            FreeMemorySheet(model: model)
        }
        .sheet(item: $model.accessibilityPrompt) { _ in
            AccessibilitySheet(model: model)
        }
        .alert(item: $model.processConfirmation) { request in
            Alert(
                title: Text(request.force ? L("Force quit %@?", request.process.displayName) : L("Quit %@?", request.process.displayName)),
                message: Text(request.force
                    ? L("Force quitting can lose unsaved work. Fettle rechecks that this is still the same process before stopping it.")
                    : L("Fettle asks the app to quit. Unsaved work may be lost if the app closes without saving.")),
                primaryButton: .destructive(Text(request.force ? L("Force Quit") : L("Quit"))) {
                    model.performQuit(request)
                },
                secondaryButton: .cancel()
            )
        }
        .confirmationDialog(
            L("Eject all connected drives?"),
            isPresented: $model.showEjectConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Eject All"), role: .destructive) { model.ejectAll() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Fettle asks macOS to eject every removable volume. Save open files first."))
        }
        .onAppear {
            if model.snapshot == nil { Task { await model.refreshNow() } }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: "waveform.path.ecg", tint: Palette.accent, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L("Mac Health"))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .tracking(-0.4)
                    healthPill
                }
                Text(L("Live, read-only readings of the processor, memory, disks, battery and network. Nothing here changes a setting."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let snapshot = model.snapshot {
                    HStack(spacing: 10) {
                        Label(L("Updated %@", HealthFormat.time(snapshot.readAt)), systemImage: "clock")
                        Label(model.isMonitoring ? L("Every %d s", max(1, model.settings.sampleIntervalSeconds)) : L("Paused"), systemImage: model.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.circle")
                        if snapshot.processCount > 0 { Label(L("%d processes", snapshot.processCount), systemImage: "list.bullet") }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 6) {
                    Button {
                        model.settings.healthMonitoring.toggle()
                    } label: {
                        Label(model.isMonitoring ? L("Pause") : L("Resume"), systemImage: model.isMonitoring ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await model.refreshNow(rescanDisks: true) }
                    } label: {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSampling)
                }
                Button {
                    app.select(.power)
                } label: {
                    Text(L("Open Sleep & Power"))
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var healthPill: some View {
        let severity = model.highestSeverity
        let color = severity.map(self.color(for:)) ?? .secondary
        let title = severity.map { $0 == .good ? L("All clear") : $0.title } ?? L("Reading this Mac…")
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.blue)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.blue.opacity(0.08)))
    }

    private var pageTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(HealthPage.allCases) { page in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { model.page = page }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: page.symbol).font(.system(size: 10.5, weight: .semibold))
                            Text(page.title).font(.system(size: 11, weight: model.page == page ? .semibold : .medium))
                        }
                        .foregroundStyle(model.page == page ? Color.white : Color.primary.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.page == page ? Palette.accent : Palette.card(scheme))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.page == page ? Color.clear : Palette.stroke(scheme), lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.activeAlerts.isEmpty {
                alertsCard
            }
            if let snapshot = model.snapshot {
                HStack(spacing: 12) {
                    HealthMetricCard(
                        icon: "cpu",
                        label: L("CPU"),
                        value: snapshot.cpu.warmedUp ? HealthFormat.percent(snapshot.cpu.usageFraction) : L("Measuring…"),
                        caption: L("Load %@", String(format: "%.2f", snapshot.cpu.load1)),
                        tint: Palette.blue,
                        severity: snapshot.cpu.severity,
                        points: model.liveSamples.map { TrendPoint(date: $0.date, value: $0.cpuPercent) },
                        domain: 0...100
                    )
                    HealthMetricCard(
                        icon: "memorychip",
                        label: L("Memory"),
                        value: HealthFormat.percent(snapshot.memory.usedFraction),
                        caption: snapshot.memory.pressure.title,
                        tint: Palette.violet,
                        severity: snapshot.memory.severity,
                        points: model.liveSamples.map { TrendPoint(date: $0.date, value: $0.memoryTotalBytes > 0 ? Double($0.memoryUsedBytes) / Double($0.memoryTotalBytes) * 100 : 0) },
                        domain: 0...100
                    )
                    HealthMetricCard(
                        icon: "internaldrive",
                        label: L("Disk free"),
                        value: snapshot.rootVolume.map { Fmt.bytes($0.availableBytes) } ?? "—",
                        caption: snapshot.rootVolume?.name ?? L("No volume"),
                        tint: Palette.accent,
                        severity: diskSeverity(snapshot.rootVolume),
                        points: model.liveSamples.map { TrendPoint(date: $0.date, value: Double($0.diskFreeBytes) / 1_000_000_000) }
                    )
                    HealthMetricCard(
                        icon: "network",
                        label: L("Network"),
                        value: HealthFormat.rate(snapshot.network.receiveRate),
                        caption: L("Down · %@ up", HealthFormat.rate(snapshot.network.sendRate)),
                        tint: Palette.green,
                        severity: .good,
                        points: model.liveSamples.map { TrendPoint(date: $0.date, value: ($0.networkInBytesPerSecond + $0.networkOutBytesPerSecond) / 1_000_000) }
                    )
                }
                HStack(alignment: .top, spacing: 14) {
                    liveTrendCard(snapshot)
                    VStack(spacing: 14) {
                        batterySummaryCard(snapshot.battery)
                        driveSummaryCard(snapshot)
                    }
                    .frame(width: 292)
                }
                HStack(alignment: .top, spacing: 14) {
                    processPreview(title: L("Busiest processes"), processes: snapshot.topCPU, isMemory: false)
                    processPreview(title: L("Largest memory users"), processes: snapshot.topMemory, isMemory: true)
                }
                notesCard(snapshot.notes)
            } else {
                EmptyStateView(icon: "waveform.path.ecg", title: L("Reading this Mac…"), message: L("Live readings will appear here in a moment."))
                    .frame(height: 320)
            }
        }
    }

    private func diskSeverity(_ volume: VolumeHealth?) -> HealthSeverity {
        guard let volume, volume.totalBytes > 0 else { return .info }
        if volume.availableBytes < 2_000_000_000 { return .critical }
        if volume.availableBytes < 10_000_000_000 { return .warning }
        return .good
    }

    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: L("Needs attention"), subtitle: L("These are live readings, not cleanup results."))
                Spacer()
                Text("\(model.activeAlerts.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.coral)
            }
            ForEach(model.activeAlerts.prefix(4)) { alert in
                Button {
                    model.page = alert.kind.page
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        IconTile(symbol: alert.kind.symbol, tint: color(for: alert.severity), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary)
                            Text(alert.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(alert.severity.title).font(.system(size: 9, weight: .semibold)).foregroundStyle(color(for: alert.severity))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                Divider().opacity(0.3)
            }
        }
        .card(padding: 14, radius: 14)
    }

    private func liveTrendCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(title: L("Activity in this session"), subtitle: L("The last %d readings, kept in memory only.", model.liveSamples.count))
            if model.liveSamples.count > 1 {
                VStack(spacing: 8) {
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(Palette.accent).frame(width: 6, height: 6)
                            Text(L("CPU")).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(HealthFormat.percent(snapshot.cpu.usageFraction)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    Sparkline(points: model.liveSamples.map { TrendPoint(date: $0.date, value: $0.cpuPercent) }, tint: Palette.accent, domain: 0...100)
                        .frame(height: 32)
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(Palette.violet).frame(width: 6, height: 6)
                            Text(L("Memory")).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(HealthFormat.percent(snapshot.memory.usedFraction)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    Sparkline(points: model.liveSamples.map { TrendPoint(date: $0.date, value: $0.memoryTotalBytes > 0 ? Double($0.memoryUsedBytes) / Double($0.memoryTotalBytes) * 100 : 0) }, tint: Palette.violet, domain: 0...100)
                        .frame(height: 32)
                }
                Text(L("Readings are estimates from macOS counters.")).font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                Text(L("Collecting readings…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .card(padding: 16, radius: 16)
    }

    private func batterySummaryCard(_ battery: BatteryReading) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle(title: L("Battery"), subtitle: nil)
                Spacer()
                Image(systemName: battery.isPluggedIn ? "powerplug.fill" : "battery.75")
                    .foregroundStyle(battery.isPluggedIn ? Palette.green : Palette.amber)
            }
            if battery.isPresent {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(battery.percent.map { "\($0)" } ?? "—").font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(battery.isCharging ? L("Charging") : (battery.isPluggedIn ? L("Plugged in") : L("On battery")))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(battery.isPluggedIn ? Palette.green : Palette.amber)
                }
                Text(battery.timeRemainingText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                HStack {
                    Text(L("Health")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text(battery.healthPercent.map { "\($0)%" } ?? "—").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                HStack {
                    Text(L("Cycles")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text(battery.cycleCount.map(String.init) ?? "—").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            } else {
                Text(L("No internal battery is reported by this Mac.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .card(padding: 13, radius: 14)
    }

    private func driveSummaryCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle(title: L("Drives"), subtitle: nil)
                Spacer()
                Button(L("Disk")) { model.page = .disk }.buttonStyle(.borderless).font(.system(size: 9.5))
            }
            if snapshot.drives.isEmpty {
                Text(L("No drive details were reported.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.drives.prefix(2)) { drive in
                    HStack(spacing: 7) {
                        Image(systemName: drive.isSolidState ? "internaldrive.fill" : "externaldrive.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(color(for: drive.severity))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(drive.model).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            Text(drive.smartLabel).font(.system(size: 9)).foregroundStyle(color(for: drive.severity))
                        }
                        Spacer()
                    }
                }
            }
        }
        .card(padding: 13, radius: 14)
    }

    private func processPreview(title: String, processes: [ProcessReading], isMemory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(L("All processes")) { showAllProcesses = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5))
            }
            if processes.isEmpty {
                Text(L("No process readings yet.")).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.vertical, 14)
            } else {
                ForEach(processes.prefix(5)) { process in
                    HStack(spacing: 7) {
                        Image(systemName: process.isApplication ? "app.fill" : "gearshape.2.fill")
                            .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
                        Text(process.displayName).font(.system(size: 10.5)).lineLimit(1)
                        Spacer()
                        Text(isMemory ? process.memoryText : process.cpuText)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(isMemory ? Palette.violet : Palette.blue)
                        if process.canManage {
                            Menu {
                                Button(L("Quit")) { model.requestQuit(process, force: false) }
                                Button(L("Force Quit"), role: .destructive) { model.requestQuit(process, force: true) }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.system(size: 10))
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 18)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .card(padding: 13, radius: 14)
    }

    private func notesCard(_ notes: [String]) -> some View {
        Group {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(Palette.blue)
                        Text(L("What this reading includes")).font(.system(size: 10.5, weight: .semibold))
                    }
                    ForEach(Array(Set(notes)).sorted(), id: \.self) { note in
                        Text("· " + note).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 12, radius: 12)
            }
        }
    }

    private func color(for severity: HealthSeverity) -> Color {
        switch severity {
        case .critical: return Palette.coral
        case .warning: return Palette.amber
        case .good: return Palette.green
        case .info: return Palette.blue
        }
    }

    // MARK: - CPU

    private var cpuPage: some View {
        Group {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        MetricTile(icon: "cpu", label: L("Total CPU"), value: snapshot.cpu.warmedUp ? HealthFormat.percent(snapshot.cpu.usageFraction) : L("Measuring…"), caption: L("%d cores", snapshot.cpu.coreCount), tint: Palette.blue)
                        MetricTile(icon: "person.fill", label: L("User"), value: HealthFormat.percent(snapshot.cpu.userFraction), caption: L("Apps and helpers"), tint: Palette.violet)
                        MetricTile(icon: "gearshape.2.fill", label: L("System"), value: HealthFormat.percent(snapshot.cpu.systemFraction), caption: L("macOS work"), tint: Palette.amber)
                        MetricTile(icon: "clock", label: L("Uptime"), value: HealthFormat.uptime(snapshot.cpu.uptime), caption: L("Since this Mac started"), tint: Palette.accent)
                    }
                    ChartCard(title: L("CPU over the last few minutes"), subtitle: L("Live readings, not estimates from another app."), samples: model.liveSamples, metric: .cpu, tint: Palette.blue, height: 170)
                    HStack(alignment: .top, spacing: 14) {
                        coresCard(snapshot.cpu)
                        loadCard(snapshot.cpu)
                            .frame(width: 270)
                    }
                    processSection(title: L("Busiest processes"), processes: snapshot.topCPU, isMemory: false)
                    responsivenessCard(snapshot)
                    notesCard(snapshot.notes)
                }
            } else {
                loading
            }
        }
    }

    private func coresCard(_ cpu: CPUReading) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(title: L("Cores"), subtitle: L("Each bar is one logical processor."))
            if cpu.perCore.isEmpty {
                Text(L("Collecting core readings…")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 7) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { index, value in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(L("Core %d", index + 1)).font(.system(size: 9)).foregroundStyle(.secondary)
                                Spacer()
                                Text(HealthFormat.percent(value)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule().fill(value > 0.85 ? Palette.coral : (value > 0.6 ? Palette.amber : Palette.blue))
                                        .frame(width: max(2, geometry.size.width * min(1, value)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
        .card(padding: 14, radius: 14)
    }

    private func loadCard(_ cpu: CPUReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: L("Load average"), subtitle: L("Processes waiting for a core."))
            loadRow(L("1 minute"), cpu.load1)
            loadRow(L("5 minutes"), cpu.load5)
            loadRow(L("15 minutes"), cpu.load15)
            Divider()
            Text(L("A load above the number of cores means work is waiting. A short spike is normal."))
                .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 14, radius: 14)
    }

    private func loadRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.2f", value)).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }

    private func responsivenessCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: L("Apps not responding"), subtitle: L("Checks the apps macOS says are running."))
                Spacer()
                Button {
                    model.checkResponsiveness()
                } label: {
                    Label(L("Check Now"), systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
            }
            if !ProcessActions.accessibilityGranted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Palette.amber)
                    Text(L("This check uses Apple's Accessibility interface and needs your permission. Fettle never turns it on by itself."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(snapshot.applications.filter(\.stillLaunching)) { process in
                Text(L("Still launching: %@", process.displayName)).font(.caption)
            }
            if model.lastResponsivenessCheck == nil {
                Text(L("No check has run yet. Running apps that have not finished launching may need your attention."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if model.unresponsiveProcesses.isEmpty {
                Label(L("No app was confirmed unresponsive."), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.green)
            } else {
                ForEach(model.unresponsiveProcesses) { process in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.coral)
                        Text(process.displayName).font(.system(size: 10.5, weight: .medium))
                        Spacer()
                        Button(L("Quit")) { model.requestQuit(process, force: false) }.buttonStyle(.borderless).font(.system(size: 9.5))
                        Button(L("Force Quit")) { model.requestQuit(process, force: true) }.buttonStyle(.borderless).font(.system(size: 9.5)).foregroundStyle(Palette.coral)
                    }
                }
            }
            if let date = model.lastResponsivenessCheck {
                Text(L("Last checked %@", Fmt.dateTime(date))).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .card(padding: 14, radius: 14)
    }

    // MARK: - Memory

    private var memoryPage: some View {
        Group {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        memoryGaugeCard(snapshot.memory)
                            .frame(width: 270)
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                MetricTile(icon: "memorychip", label: L("In use"), value: Fmt.bytes(Int64(snapshot.memory.usedBytes)), caption: L("of %@", Fmt.bytes(Int64(snapshot.memory.totalBytes))), tint: Palette.violet)
                                MetricTile(icon: "arrow.triangle.2.circlepath", label: L("Swap used"), value: Fmt.bytes(Int64(snapshot.memory.swapUsedBytes)), caption: snapshot.memory.swapTotalBytes > 0 ? L("of %@", Fmt.bytes(Int64(snapshot.memory.swapTotalBytes))) : L("No swap in use"), tint: Palette.amber)
                            }
                            memoryBreakdown(snapshot.memory)
                            HStack {
                                Button {
                                    model.showFreeMemory = true
                                } label: {
                                    Label(L("Quit Selected Apps…"), systemImage: "wind")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accent)
                                Button {
                                    SystemActions.openFolder(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                                } label: {
                                    Label(L("Open Activity Monitor"), systemImage: "waveform.path.ecg")
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                            }
                        }
                    }
                    ChartCard(title: L("Memory in use"), subtitle: L("Percentage of physical memory, from live readings."), samples: model.liveSamples, metric: .memory, tint: Palette.violet, height: 150)
                    processSection(title: L("Largest memory users"), processes: snapshot.topMemory, isMemory: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("How memory works on a Mac")).font(.system(size: 11, weight: .semibold))
                        Text(L("macOS uses free memory for caches and reclaims it when apps need it. A high “in use” figure is not automatically a problem; the pressure reading matters more. Fettle does not request an administrator password or force a system-wide purge. Quit Selected Apps asks selected apps to quit, which is the safe way for a normal app to release their memory."))
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .card(padding: 13, radius: 13)
                    notesCard(snapshot.notes)
                }
            } else {
                loading
            }
        }
    }

    private func memoryGaugeCard(_ memory: MemoryReading) -> some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 13)
                Circle()
                    .trim(from: 0, to: min(1, memory.usedFraction))
                    .stroke(
                        AngularGradient(colors: [Palette.violet, Palette.blue, Palette.violet], center: .center),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(HealthFormat.percent(memory.usedFraction))
                        .font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(L("in use")).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            HStack(spacing: 5) {
                Circle().fill(color(for: memory.severity)).frame(width: 6, height: 6)
                Text(memory.pressure.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(color(for: memory.severity))
            }
            Text(L("Memory pressure from macOS")).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 15, radius: 16)
    }

    private func memoryBreakdown(_ memory: MemoryReading) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: L("Memory breakdown"), subtitle: L("Approximate values from vm_statistics."))
            memoryBar(L("Active"), memory.activeBytes, memory.totalBytes, Palette.violet)
            memoryBar(L("Wired"), memory.wiredBytes, memory.totalBytes, Palette.coral)
            memoryBar(L("Compressed"), memory.compressedBytes, memory.totalBytes, Palette.amber)
            memoryBar(L("Cached files"), memory.cachedBytes, memory.totalBytes, Palette.blue)
            memoryBar(L("Available"), memory.availableBytes, memory.totalBytes, Palette.green)
        }
        .card(padding: 13, radius: 13)
    }

    private func memoryBar(_ label: String, _ value: UInt64, _ total: UInt64, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(tint).frame(width: max(1.5, geometry.size.width * min(1, total > 0 ? Double(value) / Double(total) : 0)))
                }
            }
            .frame(height: 5)
            Text(Fmt.bytes(Int64(value))).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: - Disk

    private var diskPage: some View {
        Group {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        MetricTile(icon: "internaldrive", label: L("Free space"), value: snapshot.rootVolume.map { Fmt.bytes($0.availableBytes) } ?? "—", caption: snapshot.rootVolume?.name ?? L("No volume"), tint: Palette.accent)
                        MetricTile(icon: "arrow.down.circle", label: L("Reading"), value: HealthFormat.rate(snapshot.diskIO.readBytesPerSecond), caption: L("Disk reads now"), tint: Palette.blue)
                        MetricTile(icon: "arrow.up.circle", label: L("Writing"), value: HealthFormat.rate(snapshot.diskIO.writeBytesPerSecond), caption: L("Disk writes now"), tint: Palette.violet)
                        MetricTile(icon: "heart.text.square", label: L("Drive health"), value: snapshot.worstDrive?.smartLabel ?? "—", caption: snapshot.worstDrive?.model ?? L("No drive details"), tint: color(for: snapshot.worstDrive?.severity ?? .info))
                    }
                    ChartCard(title: L("Free space"), subtitle: L("Reported free space in GB over the last few minutes."), samples: model.liveSamples, metric: .disk, tint: Palette.accent, height: 140)
                    volumesCard(snapshot)
                    drivesCard(snapshot)
                    HStack {
                        Button {
                            model.requestEjectAll()
                        } label: {
                            Label(L("Eject All…"), systemImage: "eject.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(snapshot.ejectableVolumes.isEmpty || model.isEjecting)
                        Button {
                            SystemActions.openFolder(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                        } label: {
                            Label(L("Open Disk Utility"), systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if model.isEjecting { ProgressView().controlSize(.small) }
                    }
                    notesCard(snapshot.notes + [L("SMART is the drive's own health report. “Health unavailable” means the drive or its enclosure does not expose it, not that the drive is healthy or failing. External drives may need to be connected directly to report SMART.")])
                }
            } else {
                loading
            }
        }
    }

    private func volumesCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: L("Volumes"), subtitle: L("Mounted, visible volumes. System helper volumes are hidden."))
            if snapshot.volumes.isEmpty {
                Text(L("No volumes were reported.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                volumeHeader
                ForEach(snapshot.volumes) { volume in
                    HStack(spacing: 8) {
                        Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                            .font(.system(size: 11)).foregroundStyle(volume.isInternal ? Palette.accent : Palette.blue).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(volume.mountPath).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(volume.filesystem).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                        Text(Fmt.bytes(volume.availableBytes)).font(.system(size: 9.5, weight: .medium).monospacedDigit()).frame(width: 72, alignment: .trailing)
                        Text(Fmt.bytes(volume.totalBytes)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                        ProgressView(value: min(1, volume.usedFraction)).tint(Palette.accent).frame(width: 52)
                        Button {
                            SystemActions.openFolder(URL(fileURLWithPath: volume.mountPath))
                        } label: {
                            Image(systemName: "folder").font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(L("Open in Finder"))
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.25)
                }
            }
        }
        .card(padding: 14, radius: 14)
    }

    private var volumeHeader: some View {
        HStack(spacing: 8) {
            Text(L("Volume")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Format")).frame(width: 104, alignment: .leading)
            Text(L("Free")).frame(width: 72, alignment: .trailing)
            Text(L("Total")).frame(width: 72, alignment: .trailing)
            Text("").frame(width: 52)
            Text("").frame(width: 20)
        }
        .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
        .padding(.bottom, 2)
    }

    private func drivesCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: L("Drives and SMART health"), subtitle: L("Read from diskutil and the drive's own SMART data."))
            if snapshot.drives.isEmpty {
                Text(L("No physical drive details were reported.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.drives) { drive in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            IconTile(symbol: drive.isSolidState ? "internaldrive.fill" : "externaldrive.fill", tint: color(for: drive.severity), size: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(drive.model).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text("\(drive.isInternal ? L("Internal") : L("External")) · \(drive.busProtocol) · \(Fmt.bytes(drive.sizeBytes))")
                                    .font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 5) {
                                Circle().fill(color(for: drive.severity)).frame(width: 6, height: 6)
                                Text(drive.smartLabel).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color(for: drive.severity))
                            }
                        }
                        HStack(spacing: 14) {
                            if let used = drive.percentageUsed { tinyStat(L("Wear"), "\(used)%") }
                            if let hours = drive.powerOnHours { tinyStat(L("Power-on"), "\(hours) h") }
                            if let cycles = drive.powerCycles { tinyStat(L("Cycles"), "\(cycles)") }
                            if let unsafe = drive.unsafeShutdowns { tinyStat(L("Unsafe shutdowns"), "\(unsafe)") }
                            if let errors = drive.mediaErrors { tinyStat(L("Media errors"), "\(errors)") }
                            if let temperature = drive.temperatureCelsius { tinyStat(L("Temperature"), HealthFormat.temperature(temperature)) }
                        }
                        Divider().opacity(0.25)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .card(padding: 14, radius: 14)
    }

    private func tinyStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 9.5, weight: .medium).monospacedDigit())
        }
    }

    // MARK: - Battery

    private var batteryPage: some View {
        Group {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 14) {
                    if snapshot.battery.isPresent {
                        HStack(alignment: .top, spacing: 14) {
                            batteryGauge(snapshot.battery)
                                .frame(width: 270)
                            VStack(spacing: 10) {
                                HStack(spacing: 10) {
                                    MetricTile(icon: "battery.75", label: L("Charge"), value: snapshot.battery.percent.map { "\($0)%" } ?? "—", caption: snapshot.battery.isCharging ? L("Charging") : (snapshot.battery.isPluggedIn ? L("Plugged in") : L("On battery")), tint: Palette.green)
                                    MetricTile(icon: "clock", label: L("Time"), value: snapshot.battery.timeRemainingText, caption: snapshot.battery.isCharging ? L("Until full") : L("Remaining"), tint: Palette.blue)
                                    MetricTile(icon: "heart.text.square", label: L("Health"), value: snapshot.battery.healthPercent.map { "\($0)%" } ?? "—", caption: snapshot.battery.conditionText ?? L("Not reported"), tint: Palette.violet)
                                    MetricTile(icon: "arrow.triangle.2.circlepath", label: L("Cycles"), value: snapshot.battery.cycleCount.map(String.init) ?? "—", caption: snapshot.battery.conditionText ?? "—", tint: Palette.amber)
                                }
                                HStack(spacing: 10) {
                                    MetricTile(icon: "thermometer.medium", label: L("Temperature"), value: HealthFormat.temperature(snapshot.battery.temperatureCelsius), caption: L("Battery"), tint: Palette.coral)
                                    MetricTile(icon: "bolt.fill", label: L("Voltage"), value: snapshot.battery.voltageMillivolts.map { "\($0) mV" } ?? "—", caption: L("Battery"), tint: Palette.amber)
                                    MetricTile(icon: "powerplug.fill", label: L("Adapter"), value: snapshot.battery.adapterWatts.map { "\($0) W" } ?? (snapshot.battery.isPluggedIn ? L("Connected") : L("Not connected")), caption: snapshot.battery.isPluggedIn ? L("Connected") : L("On battery"), tint: Palette.green)
                                    MetricTile(icon: "leaf.fill", label: L("Low power"), value: snapshot.battery.lowPowerMode ? L("On") : L("Off"), caption: L("macOS setting"), tint: Palette.accent)
                                }
                            }
                        }
                        ChartCard(title: L("Battery charge"), subtitle: L("Live percentage while Fettle is open."), samples: model.liveSamples, metric: .battery, tint: Palette.green, height: 140)
                        HStack {
                            Button(L("Open Battery Settings")) { SystemActions.openSettings(.battery) }.buttonStyle(.bordered)
                            Button(L("Open Sleep & Power")) { app.select(.power) }.buttonStyle(.bordered)
                            Spacer()
                        }
                        notesCard(snapshot.battery.notes + [L("Battery condition, cycle count and maximum capacity are reported by macOS and the battery itself. Fettle does not change charging behaviour or power settings.")])
                    } else {
                        EmptyStateView(icon: "battery.0", title: L("No battery on this Mac"), message: L("The power adapter and sleep settings are still available in Sleep & Power."), actionTitle: L("Open Sleep & Power"), action: { app.select(.power) })
                            .frame(height: 300)
                        Button(L("Open Battery Settings")) { SystemActions.openSettings(.battery) }.buttonStyle(.bordered)
                    }
                }
            } else {
                loading
            }
        }
    }

    private func batteryGauge(_ battery: BatteryReading) -> some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 13)
                Circle()
                    .trim(from: 0, to: Double(battery.percent ?? 0) / 100)
                    .stroke(
                        AngularGradient(colors: [Palette.green, Palette.accentBright, Palette.green], center: .center),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(battery.percent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(battery.isCharging ? L("Charging") : (battery.isPluggedIn ? L("Plugged in") : L("On battery"))).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            HStack(spacing: 5) {
                Circle().fill(color(for: battery.severity)).frame(width: 6, height: 6)
                Text(battery.conditionText ?? L("Condition not reported")).font(.system(size: 10, weight: .semibold)).foregroundStyle(color(for: battery.severity))
            }
            Text(battery.timeRemainingText).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 15, radius: 16)
    }

    // MARK: - Network

    private var networkPage: some View {
        Group {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        MetricTile(icon: "arrow.down.circle", label: L("Downloading"), value: HealthFormat.rate(snapshot.network.receiveRate), caption: L("Current rate"), tint: Palette.blue)
                        MetricTile(icon: "arrow.up.circle", label: L("Uploading"), value: HealthFormat.rate(snapshot.network.sendRate), caption: L("Current rate"), tint: Palette.violet)
                        MetricTile(icon: "tray.and.arrow.down", label: L("Received"), value: Fmt.bytes(Int64(snapshot.network.totalReceived)), caption: L("Since boot"), tint: Palette.accent)
                        MetricTile(icon: "tray.and.arrow.up", label: L("Sent"), value: Fmt.bytes(Int64(snapshot.network.totalSent)), caption: L("Since boot"), tint: Palette.green)
                    }
                    NetworkChartCard(samples: model.liveSamples)
                    interfacesCard(snapshot)
                    HStack {
                        Button(L("Open Network Settings")) {
                            _ = SystemActions.open("x-apple.systempreferences:com.apple.Network-Settings.extension")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Text(L("Counters are reported by macOS since the Mac started. They may wrap after a very long uptime."))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    notesCard(snapshot.notes)
                }
            } else {
                loading
            }
        }
    }

    private func interfacesCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: L("Interfaces"), subtitle: L("Active network interfaces and their counters."))
            if snapshot.network.interfaces.isEmpty {
                Text(L("No network interfaces were reported.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text(L("Interface")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("Address")).frame(width: 150, alignment: .leading)
                    Text(L("Received")).frame(width: 86, alignment: .trailing)
                    Text(L("Sent")).frame(width: 86, alignment: .trailing)
                    Text(L("Now")).frame(width: 118, alignment: .trailing)
                }
                .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(snapshot.network.interfaces) { interface in
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(interface.name == snapshot.network.primaryInterface ? Palette.green : Palette.blue.opacity(0.6)).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(interface.displayName).font(.system(size: 10.5, weight: .medium))
                                Text(interface.name).font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(interface.address ?? "—").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(Fmt.bytes(Int64(interface.receivedBytes))).font(.system(size: 9).monospacedDigit()).frame(width: 86, alignment: .trailing)
                        Text(Fmt.bytes(Int64(interface.sentBytes))).font(.system(size: 9).monospacedDigit()).frame(width: 86, alignment: .trailing)
                        Text("\(HealthFormat.rate(interface.receiveRate)) ↓ \(HealthFormat.rate(interface.sendRate)) ↑")
                            .font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 118, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.25)
                }
            }
        }
        .card(padding: 14, radius: 14)
    }

    // MARK: - Activity

    @State private var activityRange: ActivityRange = .day
    @State private var activityMetric: HealthTrendMetric = .cpu
    @State private var showClearActivity = false

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(title: L("Activity history"), subtitle: L("Numeric readings stored only on this Mac. Process names and paths are not kept."))
                Spacer()
                Picker("", selection: $activityMetric) {
                    ForEach([HealthTrendMetric.cpu, .memory, .disk, .network, .battery]) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Picker("", selection: $activityRange) {
                    ForEach(ActivityRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button(L("Clear")) { showClearActivity = true }
                    .buttonStyle(.borderless)
                    .disabled(model.activity.samples.isEmpty)
            }
            let samples = model.activity.samples(since: activityRange.start)
            if samples.count > 1 {
                ChartCard(title: L("%@ over %@", activityMetric.title, activityRange.title), subtitle: L("%d readings", samples.count), samples: samples, metric: activityMetric, tint: Palette.accent, height: 190)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("Collecting activity history…")).font(.system(size: 12, weight: .medium))
                    Text(L("Fettle keeps one reading per minute for up to seven days. Leave it open for a while, or enable monitoring in Settings."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(26)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card(scheme)))
            }
            if !model.activity.samples.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle(title: L("Reading history"), subtitle: L("Newest first. This is not a cleanup log."))
                    HStack(spacing: 8) {
                        Text(L("Time")).frame(width: 130, alignment: .leading)
                        Text("CPU").frame(width: 54, alignment: .trailing)
                        Text(L("Memory")).frame(width: 88, alignment: .trailing)
                        Text(L("Disk free")).frame(width: 88, alignment: .trailing)
                        Text(L("Network")).frame(width: 88, alignment: .trailing)
                        Text(L("Battery")).frame(width: 62, alignment: .trailing)
                        Text(L("Pressure")).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    ForEach(model.activity.latest(120)) { sample in
                        HStack(spacing: 8) {
                            Text(Fmt.dateTime(sample.date)).font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(String(format: "%.0f%%", sample.cpuPercent)).font(.system(size: 9.5, weight: .medium).monospacedDigit()).frame(width: 54, alignment: .trailing)
                            Text(Fmt.bytes(Int64(sample.memoryUsedBytes))).font(.system(size: 9.5).monospacedDigit()).frame(width: 88, alignment: .trailing)
                            Text(Fmt.bytes(sample.diskFreeBytes)).font(.system(size: 9.5).monospacedDigit()).frame(width: 88, alignment: .trailing)
                            Text(HealthFormat.rate(sample.networkInBytesPerSecond + sample.networkOutBytesPerSecond)).font(.system(size: 9.5).monospacedDigit()).frame(width: 88, alignment: .trailing)
                            Text(sample.batteryPercent.map { "\($0)%" } ?? "—").font(.system(size: 9.5).monospacedDigit()).frame(width: 62, alignment: .trailing)
                            Text(sample.memoryPressure.title).font(.system(size: 9)).foregroundStyle(color(for: sample.memoryPressure.severity)).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider().opacity(0.22)
                    }
                }
                .card(padding: 14, radius: 14)
            }
            Text(L("Activity history keeps only numbers: CPU, memory, free space, network rates, battery percentage and thermal state. It never stores file names, browser data, credentials or process names."))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .alert(L("Clear activity history?"), isPresented: $showClearActivity) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Clear"), role: .destructive) { model.clearActivity() }
        } message: {
            Text(L("The stored readings will be removed. Cleanup history is separate and stays in place."))
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(L("Reading this Mac…")).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func processSection(title: String, processes: [ProcessReading], isMemory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle(title: title, subtitle: L("Quit asks the app to close. Force Quit can lose unsaved work."))
                Spacer()
                Button(L("All processes")) { showAllProcesses = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5))
            }
            if processes.isEmpty {
                Text(L("No process readings yet.")).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.vertical, 14)
            } else {
                ProcessTable(model: model, processes: processes, isMemory: isMemory)
            }
        }
        .card(padding: 14, radius: 14)
    }
}

// MARK: - Shared health components

struct HealthMetricCard: View {
    var icon: String
    var label: String
    var value: String
    var caption: String
    var tint: Color
    var severity: HealthSeverity
    var points: [TrendPoint]
    var domain: ClosedRange<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint)
                Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(value).font(.system(size: 21, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            if points.count > 2 {
                Sparkline(points: points, tint: tint, domain: domain)
                    .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 11, radius: 13)
    }

    private var color: Color {
        switch severity {
        case .critical: return Palette.coral
        case .warning: return Palette.amber
        case .good: return Palette.green
        case .info: return Palette.blue
        }
    }
}

struct Sparkline: View {
    var points: [TrendPoint]
    var tint: Color
    var domain: ClosedRange<Double>? = nil

    private var plotted: [TrendPoint] {
        guard domain == nil else { return points }
        guard let min = points.map(\.value).min(), let max = points.map(\.value).max(), max > min else {
            return points.map { TrendPoint(date: $0.date, value: 0.5) }
        }
        return points.map { TrendPoint(date: $0.date, value: ($0.value - min) / (max - min)) }
    }

    var body: some View {
        Chart(plotted) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain ?? 0...1)
    }
}

struct HealthTrendChart: View {
    var samples: [HealthHistorySample]
    var metric: HealthTrendMetric
    var tint: Color
    var height: CGFloat

    private var points: [TrendPoint] {
        var previous: Date?
        var segment = 0
        return samples.map { sample in
            if let previous, sample.date.timeIntervalSince(previous) > 90 { segment += 1 }
            previous = sample.date
            return TrendPoint(date: sample.date, value: metric.value(sample), segment: segment)
        }
    }

    private var upper: Double {
        let maximum = points.map(\.value).max() ?? 1
        switch metric {
        case .cpu, .memory, .battery: return 100
        case .disk: return max(1, maximum * 1.08)
        case .network: return max(1, maximum * 1.15)
        }
    }

    var body: some View {
        if points.count > 1 {
            Chart(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value), series: .value("Segment", point.segment))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...upper)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel().font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric == .disk ? String(format: "%.0f", number) : String(format: "%.0f", number))
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .frame(height: height)
        } else {
            Text(L("Collecting readings…"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
        }
    }
}

struct ChartCard: View {
    var title: String
    var subtitle: String
    var samples: [HealthHistorySample]
    var metric: HealthTrendMetric
    var tint: Color
    var height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title, subtitle: subtitle)
            HealthTrendChart(samples: samples, metric: metric, tint: tint, height: height)
        }
        .card(padding: 14, radius: 14)
    }
}

struct NetworkChartCard: View {
    var samples: [HealthHistorySample]

    private var upper: Double {
        let maximum = samples.map { max($0.networkInBytesPerSecond, $0.networkOutBytesPerSecond) / 1_000_000 }.max() ?? 1
        return max(0.5, maximum * 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: L("Network traffic"), subtitle: L("MB per second over the last few minutes."))
            if samples.count > 1 {
                Chart {
                    ForEach(samples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("MB/s", sample.networkInBytesPerSecond / 1_000_000)
                        )
                        .foregroundStyle(Palette.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.catmullRom)
                    }
                    ForEach(samples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("MB/s", sample.networkOutBytesPerSecond / 1_000_000)
                        )
                        .foregroundStyle(Palette.violet)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartYScale(domain: 0...upper)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel().font(.system(size: 8))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel().font(.system(size: 8))
                    }
                }
                .frame(height: 160)
                HStack(spacing: 14) {
                    HStack(spacing: 4) { Circle().fill(Palette.blue).frame(width: 6, height: 6); Text(L("Download")).font(.system(size: 9)).foregroundStyle(.secondary) }
                    HStack(spacing: 4) { Circle().fill(Palette.violet).frame(width: 6, height: 6); Text(L("Upload")).font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            } else {
                Text(L("Collecting readings…")).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .card(padding: 14, radius: 14)
    }
}

struct AppIconBadge: View {
    var bundleID: String?
    var fallback: String = "app.fill"
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let bundleID, let url = SystemActions.appURL(for: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
    }
}

struct ProcessTable: View {
    @ObservedObject var model: HealthModel
    var processes: [ProcessReading]
    var isMemory: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Process")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("CPU")).frame(width: 58, alignment: .trailing)
                Text(L("Memory")).frame(width: 80, alignment: .trailing)
                Text(L("Actions")).frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.vertical, 4)
            Divider()
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        if process.isApplication {
                            AppIconBadge(bundleID: process.bundleID, fallback: "app.fill", size: 14)
                        } else {
                            Image(systemName: "gearshape.2.fill")
                                .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(process.displayName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            Text(process.bundleID ?? process.path ?? "pid \(process.pid)")
                                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(process.cpuText).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(isMemory ? .secondary : Palette.blue).frame(width: 58, alignment: .trailing)
                    Text(process.memoryText).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(isMemory ? Palette.violet : .secondary).frame(width: 80, alignment: .trailing)
                    HStack(spacing: 4) {
                        Button(L("Quit")) { model.requestQuit(process, force: false) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9))
                            .disabled(!process.canManage)
                        Menu {
                            Button(L("Force Quit"), role: .destructive) { model.requestQuit(process, force: true) }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 9))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 18)
                        .disabled(!process.canManage)
                    }
                    .frame(width: 92, alignment: .trailing)
                }
                .padding(.vertical, 3)
                Divider().opacity(0.22)
            }
        }
    }
}

struct AllProcessesSheet: View {
    @ObservedObject var model: HealthModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort: ProcessSort = .cpu

    enum ProcessSort: String, CaseIterable, Identifiable {
        case cpu, memory, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: return L("CPU")
            case .memory: return L("Memory")
            case .name: return L("Name")
            }
        }
    }

    private var filtered: [ProcessReading] {
        let all = model.snapshot?.processes ?? []
        let matched = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? all
            : all.filter { $0.displayName.localizedCaseInsensitiveContains(query) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(query) }
        switch sort {
        case .cpu: return matched.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return matched.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name: return matched.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("All processes")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("%d user processes. Fettle never lists system-owned processes for quitting.", model.snapshot?.processes.count ?? 0))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search processes"), text: $query).textFieldStyle(.plain)
                Picker("", selection: $sort) {
                    ForEach(ProcessSort.allCases) { item in Text(item.title).tag(item) }
                }
                .labelsHidden().frame(width: 110)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            ProcessTable(model: model, processes: filtered, isMemory: sort == .memory)
                .frame(maxHeight: .infinity, alignment: .top)
            HStack {
                Text(L("Quit sends a normal close request. Force Quit can lose unsaved work."))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }
}

struct FreeMemorySheet: View {
    @ObservedObject var model: HealthModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<pid_t>()

    private var candidates: [ProcessReading] { model.freeMemoryCandidates }
    private var selectedBytes: UInt64 {
        candidates.filter { selected.contains($0.pid) }.reduce(0) { $0 + $1.memoryBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconTile(symbol: "wind", tint: Palette.accent, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Quit Selected Apps")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Ask selected apps to quit, then measure the memory macOS reports."))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(L("macOS manages memory itself, and a system-wide purge needs administrator rights that Fettle does not request. Quitting apps you are not using is the safe way to release their memory. Unsaved work may be lost, so save first."))
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L("%d apps · %@ selected", selected.count, Fmt.bytes(Int64(selectedBytes)))).font(.system(size: 10, weight: .medium))
                Spacer()
                Button(selected.count == candidates.count ? L("Deselect All") : L("Select All")) {
                    selected = selected.count == candidates.count ? [] : Set(candidates.map(\.pid))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9.5))
            }
            if candidates.isEmpty {
                Text(L("No running apps can be quit by Fettle right now.")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { process in
                            Toggle(isOn: Binding(
                                get: { selected.contains(process.pid) },
                                set: { value in
                                    if value { selected.insert(process.pid) } else { selected.remove(process.pid) }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    AppIconBadge(bundleID: process.bundleID, fallback: "app.fill", size: 17)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(process.displayName).font(.system(size: 11, weight: .medium))
                                        Text(process.bundleID ?? "pid \(process.pid)").font(.system(size: 8.5)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(process.memoryText).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .padding(.vertical, 5)
                            Divider().opacity(0.22)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                Button(L("Cancel")) { dismiss() }
                Spacer()
                Button {
                    model.performFreeMemory(pids: selected)
                } label: {
                    Label(L("Quit Selected Apps"), systemImage: "wind")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }
}

struct AccessibilitySheet: View {
    @ObservedObject var model: HealthModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "lock.shield", tint: Palette.amber, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Check apps with Accessibility")).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(L("This is an opt-in permission for one check.")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Text(L("Fettle asks macOS whether each open app answers a small Accessibility query. If an app cannot answer in under a second, it is reported as not responding. Fettle never reads window contents, keystrokes or documents, and the permission can be removed in System Settings at any time."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Without this permission, Fettle still shows apps that macOS says have not finished launching, and the rest of Mac Health works normally."))
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(L("Not Now")) { dismiss() }
                Spacer()
                Button(L("Open Accessibility Settings")) { model.openAccessibilitySettings() }
                    .buttonStyle(.bordered)
                Button(L("Ask macOS")) { model.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

enum ActivityRange: String, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return L("1 hour")
        case .day: return L("24 hours")
        case .week: return L("7 days")
        }
    }
    var start: Date {
        switch self {
        case .hour: return Date().addingTimeInterval(-3_600)
        case .day: return Date().addingTimeInterval(-86_400)
        case .week: return Date().addingTimeInterval(-7 * 86_400)
        }
    }
}
