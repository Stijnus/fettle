import SwiftUI

struct OverviewView: View {
    @ObservedObject var health: HealthModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showClearHistory = false
    @State private var historyMode: HistoryMode = .cleanup

    enum HistoryMode: String, CaseIterable, Identifiable {
        case cleanup, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cleanup: return L("Cleanup")
            case .activity: return L("Activity")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GlobalSearchResults(query: app.searchText)
                } else {
                    header
                    heroCard
                    healthStrip
                    resultsByModule
                    HStack(alignment: .top, spacing: 16) {
                        historyCard
                        quickActions
                            .frame(width: 280)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .background(Palette.background(scheme))
        .alert(L("Clear history?"), isPresented: $showClearHistory) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Clear"), role: .destructive) { app.history.clear() }
        } message: {
            Text(L("Completed cleanups and removals appear here."))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Care for your Mac, calmly."))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                Text(L("A local-first checkup for storage, startup items and privacy. Nothing leaves this Mac."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Pill(text: L("Local only"), icon: "lock.fill", tint: Palette.accent)
                Pill(text: L("Read-only"), icon: "eye", tint: Palette.blue)
            }
            .padding(.top, 8)
        }
    }

    private var heroCard: some View {
        HStack(spacing: 24) {
            DiskGauge(volume: app.diskUsage)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Estimated removable files"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(hasScanResults ? Fmt.bytes(app.estimatedRemovableBytes) : L("Not scanned yet"))
                    .font(.system(size: hasScanResults ? 38 : 30, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(hasScanResults ? L("Nothing is selected until you review it.") : L("Scan your Mac to see what can go."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if app.isGlobalScanning {
                        Button {
                            app.cancelGlobalScan()
                        } label: {
                            Label(L("Stop Scan"), systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.coral)
                        .controlSize(.large)
                    } else {
                        Button {
                            app.startGlobalScan()
                        } label: {
                            Label(L("Scan"), systemImage: "sparkle.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .controlSize(.large)
                    }
                    Button(L("Review")) { app.select(.disk) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .padding(.top, 6)
                if app.isGlobalScanning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: app.globalProgress)
                            .tint(Palette.accent)
                            .frame(width: 290)
                        Text(app.globalPhase)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 0) {
                heroFact(icon: "externaldrive", label: L("Actual free space"), value: app.diskUsage.map { Fmt.bytes($0.available) } ?? "—", tint: Palette.violet)
                Divider().opacity(0.4)
                heroFact(icon: "trash.circle", label: L("Trash"), value: app.trashBytesLive.map(Fmt.bytes) ?? "—", tint: Palette.amber)
                Divider().opacity(0.4)
                heroFact(icon: "clock", label: L("Last scan"), value: app.lastScanDate.map { Fmt.relativeDate($0) } ?? L("Never scanned"), tint: Palette.blue)
                    .help(app.lastScanDate.map { Fmt.dateTime($0) } ?? "")
            }
            .frame(width: 270)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 22, radius: 20)
    }

    /// True once a scan that feeds the removable estimate has results.
    private var hasScanResults: Bool {
        app.disk.report != nil || app.maintenance.report != nil || app.privacy.report != nil
    }

    private func heroFact(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: icon, tint: tint, size: 28)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.vertical, 9)
    }

    private var healthStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Mac Health")).font(.system(size: 11, weight: .semibold))
                    Text(health.statusHeadline).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let snapshot = health.snapshot {
                healthMini(L("CPU"), snapshot.cpu.warmedUp ? HealthFormat.percent(snapshot.cpu.usageFraction) : "—", Palette.blue)
                healthMini(L("Memory"), HealthFormat.percent(snapshot.memory.usedFraction), Palette.violet)
                healthMini(L("Disk free"), snapshot.rootVolume.map { Fmt.bytes($0.availableBytes) } ?? "—", Palette.accent)
                healthMini(L("Network"), HealthFormat.rate(snapshot.network.receiveRate), Palette.green)
            } else {
                Text(L("Reading this Mac…")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Button(L("Open")) { app.select(.health) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
        )
    }

    private var healthColor: Color {
        switch health.highestSeverity {
        case nil: return .secondary
        case .critical: return Palette.coral
        case .warning: return Palette.amber
        case .good: return Palette.green
        case .info: return Palette.blue
        }
    }

    private func healthMini(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
        }
        .frame(width: 88, alignment: .leading)
    }

    private var resultsByModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: L("Results by module"), subtitle: L("Open a module from the sidebar to see details."))
                Spacer()
                Button(L("Scan Again")) { app.startGlobalScan() }
                    .buttonStyle(.borderless)
                    .disabled(app.isGlobalScanning)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach([ModuleID.health, .disk, .maintenance, .uninstaller, .updater, .privacy, .extensions, .loginItems, .power], id: \.self) { module in
                    ModuleStatusCard(module: module, summary: app.summary(for: module)) {
                        app.select(module)
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: L("History"), subtitle: nil)
                Spacer()
                Picker("", selection: $historyMode) {
                    ForEach(HistoryMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                if historyMode == .cleanup, !app.history.events.isEmpty {
                    Button(L("Clear")) { showClearHistory = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if historyMode == .cleanup {
                if app.history.events.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("No cleanup history yet")).font(.system(size: 13, weight: .semibold))
                        Text(L("Completed cleanups and removals appear here.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(app.history.events.prefix(8)) { event in
                            HStack(spacing: 10) {
                                IconTile(symbol: event.module.symbol, tint: Palette.accent, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.displayAction).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text("\(event.module.title) · \(Fmt.dateTime(event.date))")
                                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(Fmt.bytes(event.bytes)).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    Text(event.displayOutcome).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            Divider().opacity(0.35)
                        }
                    }
                }
            } else {
                if health.activity.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("No activity readings yet")).font(.system(size: 13, weight: .semibold))
                        Text(L("Mac Health keeps one numeric reading per minute while Fettle is open.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(health.activity.latest(8)) { sample in
                            HStack(spacing: 10) {
                                IconTile(symbol: "waveform.path.ecg", tint: Palette.blue, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L("CPU %@ · Memory %@", String(format: "%.0f%%", sample.cpuPercent), Fmt.bytes(Int64(sample.memoryUsedBytes))))
                                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(Fmt.dateTime(sample.date)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(Fmt.bytes(sample.diskFreeBytes)).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    Text(L("free")).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            Divider().opacity(0.35)
                        }
                    }
                    Button(L("Open Activity History")) { app.select(.health); health.page = .activity }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9.5))
                }
            }
        }
        .card(padding: 16, radius: 16)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L("Quick actions"), subtitle: nil)
            quickAction(icon: "waveform.path.ecg", title: L("Open Mac Health"), detail: health.statusHeadline, module: .health)
            quickAction(icon: "arrow.triangle.2.circlepath", title: L("Check app updates"), detail: app.updater.lastScan == nil ? L("Not checked yet") : L("%d available", app.updater.availableRecords.count), module: .updater)
            quickAction(icon: "internaldrive", title: L("Open Disk Cleanup"), detail: L("Caches, logs and Trash"), module: .disk)
            quickAction(icon: "trash", title: L("Review Trash"), detail: app.trashBytesLive.map(Fmt.bytes) ?? "—", module: .disk)
            quickAction(icon: "person.badge.key", title: L("Check login items"), detail: "\(app.loginItems.records.count)", module: .loginItems)
            quickAction(icon: "xmark.bin", title: L("Permanent delete a file"), detail: L("A separate, deliberate erase."), module: .permanentDelete)
        }
        .card(padding: 16, radius: 16)
    }

    private func quickAction(icon: String, title: String, detail: String, module: ModuleID) -> some View {
        Button {
            app.select(module)
        } label: {
            HStack(spacing: 9) {
                IconTile(symbol: icon, tint: Palette.tint(for: module == .permanentDelete ? .appData : .cache), size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

struct DiskGauge: View {
    var volume: VolumeInfo?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 12)
            Circle()
                .trim(from: 0, to: volume?.usedFraction ?? 0)
                .stroke(
                    AngularGradient(colors: [Palette.accent, Palette.accentBright, Palette.blue, Palette.accent], center: .center),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(volume.map { Fmt.percent($0.usedFraction) } ?? "—")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(L("used space"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
    }
}

struct ModuleStatusCard: View {
    var module: ModuleID
    var summary: ModuleSummary
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var tint: Color { module.tint }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconTile(symbol: module.symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    if let note = summary.note {
                        Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if module == .power {
                        Text(L("Read-only, no changes")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    } else if summary.bytes > 0 {
                        Text(Fmt.bytes(summary.bytes)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(L("%d items", summary.itemCount)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    if summary.itemCount > 0 {
                        Text("\(summary.itemCount)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(tint)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Palette.card(scheme))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(hovering ? tint.opacity(0.35) : Palette.stroke(scheme), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct GlobalSearchResults: View {
    @EnvironmentObject private var app: AppModel
    var query: String

    private struct Hit: Identifiable {
        var id: String
        var module: ModuleID
        var item: ScanItem?
        var name: String
        var detail: String
        var size: Int64?
    }

    private var hits: [Hit] {
        var results: [Hit] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for item in app.disk.items where matches(item, q) {
            results.append(Hit(id: "disk|\(item.id)", module: .disk, item: item, name: item.name, detail: item.displayPath, size: item.size))
        }
        for item in app.maintenance.items where matches(item, q) {
            results.append(Hit(id: "maint|\(item.id)", module: .maintenance, item: item, name: item.name, detail: item.displayPath, size: item.size))
        }
        for item in app.privacy.items where matches(item, q) {
            results.append(Hit(id: "privacy|\(item.id)", module: .privacy, item: item, name: item.name, detail: item.displayPath, size: item.size))
        }
        for appRecord in app.uninstaller.apps where appRecord.name.localizedCaseInsensitiveContains(q) || appRecord.bundleID.localizedCaseInsensitiveContains(q) {
            results.append(Hit(id: "app|\(appRecord.id)", module: .uninstaller, item: nil, name: appRecord.name, detail: appRecord.bundleID, size: appRecord.size))
        }
        for record in app.extensions.records where record.name.localizedCaseInsensitiveContains(q) || record.host.localizedCaseInsensitiveContains(q) {
            results.append(Hit(id: "ext|\(record.id)", module: .extensions, item: nil, name: record.name, detail: "\(record.host) · \(record.version)", size: nil))
        }
        for record in app.loginItems.records where record.name.localizedCaseInsensitiveContains(q) || record.publisher.localizedCaseInsensitiveContains(q) {
            results.append(Hit(id: "login|\(record.id)", module: .loginItems, item: nil, name: record.name, detail: record.publisher, size: nil))
        }
        for record in app.updater.records where record.appName.localizedCaseInsensitiveContains(q) || record.bundleID.localizedCaseInsensitiveContains(q) || (record.latestVersion?.localizedCaseInsensitiveContains(q) ?? false) {
            let detail = record.latestVersion.map { "\(record.bundleID) · \($0)" } ?? record.bundleID
            results.append(Hit(id: "updater|\(record.id)", module: .updater, item: nil, name: record.appName, detail: detail, size: record.updateSize))
        }
        return results
    }

    private func matches(_ item: ScanItem, _ q: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(q) || item.path.localizedCaseInsensitiveContains(q) || item.category.title.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Search all results")).font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("\(hits.count) " + L("items")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Clear")) { app.searchText = "" }.buttonStyle(.borderless)
            }
            if hits.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: L("No results"), message: L("Try a different search."))
                    .frame(height: 320)
            } else {
                VStack(spacing: 0) {
                    ForEach(hits.prefix(80)) { hit in
                        Button {
                            app.select(hit.module)
                        } label: {
                            HStack(spacing: 10) {
                                IconTile(symbol: hit.module.symbol, tint: Palette.accent, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(hit.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(hit.module.title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.accent)
                                if let size = hit.size {
                                    Text(Fmt.bytes(size)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.35)
                    }
                    if hits.count > 80 {
                        Text("+ \(hits.count - 80)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
                .card(padding: 14, radius: 14)
            }
        }
        .padding(.top, 4)
    }
}
