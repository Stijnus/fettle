import SwiftUI
import AppKit

struct UpdaterView: View {
    private var upToDateSummary: String {
        let count = model.records.filter { $0.source == .sparkle && $0.status == .upToDate }.count
        return count == 1
            ? L("1 app publishes an update feed Fettle can read, and it reports its installed version is current. Other apps update themselves, through the App Store or through Software Update.")
            : L("%d apps publish an update feed Fettle can read, and each reports its installed version is current. Other apps update themselves, through the App Store or through Software Update.", count)
    }

    @ObservedObject var model: UpdaterModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var detail: AppUpdateRecord?
    @State private var showOther = false
    @State private var showAppStore = true

    private var query: String {
        app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleAvailable: [AppUpdateRecord] {
        filter(model.availableRecords)
    }

    private var visibleAppStore: [AppUpdateRecord] {
        filter(model.appStoreRecords)
    }

    private var visibleApple: [AppUpdateRecord] {
        filter(model.appleRecords)
    }

    private var visibleOther: [AppUpdateRecord] {
        filter(model.otherRecords + model.upToDateRecords)
    }

    private func filter(_ records: [AppUpdateRecord]) -> [AppUpdateRecord] {
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.appName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
                || ($0.latestVersion?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.source.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .updater,
                title: L("App Updater"),
                message: L("Check the update feed each app publishes, review what is available, and open the vendor's page. Fettle never installs an update itself.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.lastScan == nil ? L("Check for App Updates") : L("Check Again"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)

                Menu {
                    Button(L("Open App Store updates")) { SystemActions.open("macappstore://showUpdatesPage") }
                    Button(L("Open Software Update")) {
                        SystemActions.open("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
                    }
                    Divider()
                    Button(L("Open Applications folder")) { SystemActions.openFolder(URL(fileURLWithPath: "/Applications")) }
                    Button(L("App update settings")) {
                        app.menuBar.openSettings()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
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
                EmptyStateView(
                    icon: "arrow.triangle.2.circlepath",
                    title: L("Check installed apps for updates"),
                    message: L("Fettle reads each app's own update feed, never its documents or passwords. App Store and Apple apps are routed to their supported update pages."),
                    actionTitle: L("Check for App Updates"),
                    action: { model.startScan() }
                )
                Spacer(minLength: 0)
            } else {
                stats
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)

                if let note = model.notes.first {
                    InfoNote(
                        icon: "lock.shield.fill",
                        title: L("Read-only update check"),
                        message: note
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }

                if model.records.isEmpty && model.isScanning {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(L("Checking installed apps…")).font(.system(size: 12, weight: .medium))
                        Text(model.phase).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
        }
        .background(Palette.background(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.availableRecords.isEmpty {
                SelectionBar(
                    count: model.selectedIDs.count,
                    bytes: model.selectedBytes,
                    primaryTitle: L("Review…"),
                    primaryIcon: "checklist",
                    isEnabled: !model.selectedRecords.isEmpty && !model.isOpening,
                    onPrimary: { model.beginReview() },
                    onClear: { model.deselectAll() }
                )
            }
        }
        .sheet(isPresented: $model.showReview) {
            UpdaterReviewSheet(model: model, detail: $detail, onClose: { model.showReview = false })
                .environmentObject(app)
        }
        .sheet(item: $model.outcome) { outcome in
            OutcomeSheet(outcome: outcome)
        }
        .sheet(item: $detail) { record in
            AppUpdateDetailSheet(record: record, model: model) { detail = nil }
                .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast).padding(.bottom, 70)
            }
        }
        .task {
            // The person starts the first check. This keeps network access
            // explicit; automatic checks are opt-in in Settings.
            if model.records.isEmpty && !model.isScanning && model.lastScan != nil {
                model.startScan()
            }
        }
    }

    private var stats: some View {
        SummaryCard(
            label: L("Available updates"),
            value: "\(model.availableRecords.count)",
            caption: model.availableRecords.isEmpty ? L("Nothing waiting") : L("Ready to review"),
            facts: [
                SummaryFact(icon: "app.fill", label: L("Apps checked"), value: "\(model.records.count)", tint: Palette.blue, help: "\(model.skipped.count) " + L("skipped")),
                SummaryFact(icon: "checkmark.seal.fill", label: L("Up to date"), value: "\(model.upToDateRecords.count)", tint: Palette.green, help: L("From the app's own feed")),
                SummaryFact(icon: "clock", label: L("Last check"), value: model.lastScan.map { Fmt.relativeDate($0) } ?? L("Not checked yet"), tint: Palette.violet, help: model.lastScan.map { Fmt.dateTime($0) })
            ]
        )
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !query.isEmpty && visibleAvailable.isEmpty && visibleAppStore.isEmpty && visibleApple.isEmpty && visibleOther.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: L("No results"), message: L("Try a different app name, bundle identifier or version."))
                        .frame(height: 260)
                }

                if !visibleAvailable.isEmpty {
                    sectionHeader(L("Available updates"), count: visibleAvailable.count, icon: "arrow.down.circle.fill", tint: Palette.accent)
                    VStack(spacing: 0) {
                        ForEach(visibleAvailable) { record in
                            UpdaterRow(
                                record: record,
                                selected: model.selectedIDs.contains(record.id),
                                onToggle: { model.toggle(record) },
                                onOpen: { model.openSingle(record) },
                                onInfo: { detail = record },
                                onReveal: { model.reveal(record) },
                                onIgnore: { model.ignore(record) },
                                onCopy: { model.copyDownload(record) }
                            )
                            Divider().opacity(0.35)
                        }
                    }
                    .card(padding: 10, radius: 14)
                } else if model.lastScan != nil && !model.isScanning {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("No app updates are available.")).font(.system(size: 12.5, weight: .semibold))
                            Text(upToDateSummary)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.green.opacity(0.07)))
                }

                if !visibleAppStore.isEmpty {
                    DisclosureGroup(isExpanded: $showAppStore) {
                        VStack(spacing: 0) {
                            ForEach(visibleAppStore) { record in
                                UpdaterRow(
                                    record: record,
                                    selected: false,
                                    onToggle: {},
                                    onOpen: { model.openSingle(record) },
                                    onInfo: { detail = record },
                                    onReveal: { model.reveal(record) },
                                    onIgnore: { model.ignore(record) },
                                    onCopy: { model.copyDownload(record) }
                                )
                                Divider().opacity(0.35)
                            }
                        }
                        .card(padding: 10, radius: 14)
                        .padding(.top, 8)
                    } label: {
                        sectionHeader(L("Managed by the App Store"), count: visibleAppStore.count, icon: "storefront.fill", tint: Palette.blue)
                    }
                }

                if !visibleApple.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 0) {
                            ForEach(visibleApple) { record in
                                UpdaterRow(
                                    record: record,
                                    selected: false,
                                    onToggle: {},
                                    onOpen: { model.openSingle(record) },
                                    onInfo: { detail = record },
                                    onReveal: { model.reveal(record) },
                                    onIgnore: { model.ignore(record) },
                                    onCopy: { model.copyDownload(record) }
                                )
                                Divider().opacity(0.35)
                            }
                        }
                        .card(padding: 10, radius: 14)
                        .padding(.top, 8)
                    } label: {
                        sectionHeader(L("Updated by macOS"), count: visibleApple.count, icon: "applelogo", tint: Palette.violet)
                    }
                }

                if !model.skipped.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 0) {
                            ForEach(model.skipped) { item in
                                HStack(spacing: 8) {
                                    IconTile(symbol: "arrow.turn.down.right", tint: Palette.amber, size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.path).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        Text(item.reason).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                Divider().opacity(0.35)
                            }
                        }
                        .card(padding: 10, radius: 14)
                        .padding(.top, 8)
                    } label: {
                        sectionHeader(L("Skipped apps"), count: model.skipped.count, icon: "arrow.turn.down.right", tint: Palette.amber)
                    }
                }

                if !visibleOther.isEmpty {
                    DisclosureGroup(isExpanded: $showOther) {
                        VStack(spacing: 0) {
                            ForEach(visibleOther) { record in
                                UpdaterRow(
                                    record: record,
                                    selected: false,
                                    onToggle: {},
                                    onOpen: { model.openSingle(record) },
                                    onInfo: { detail = record },
                                    onReveal: { model.reveal(record) },
                                    onIgnore: { model.ignore(record) },
                                    onCopy: { model.copyDownload(record) }
                                )
                                Divider().opacity(0.35)
                            }
                        }
                        .card(padding: 10, radius: 14)
                        .padding(.top, 8)
                    } label: {
                        sectionHeader(L("Other checked apps"), count: visibleOther.count, icon: "app.badge.checkmark", tint: Palette.blue)
                    }
                }

                if model.records.isEmpty && !model.isScanning {
                    EmptyStateView(icon: "app.dashed", title: L("No apps were found"), message: L("Add an app folder in the Uninstaller, then check again."))
                        .frame(height: 260)
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 9))
                    Text(L("Fettle does not install or run an update. Your browser, the App Store or Software Update finishes the job."))
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func sectionHeader(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 9.5, weight: .bold).monospacedDigit()).foregroundStyle(tint)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.12)))
            Spacer()
        }
    }
}

// MARK: - Row

struct UpdaterRow: View {
    var record: AppUpdateRecord
    var selected: Bool
    var onToggle: () -> Void
    var onOpen: () -> Void
    var onInfo: () -> Void
    var onReveal: () -> Void
    var onIgnore: () -> Void
    var onCopy: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch record.status {
        case .available: return Palette.accent
        case .appStore: return Palette.blue
        case .appleSoftwareUpdate: return Palette.violet
        case .failed: return Palette.coral
        case .incompatible: return Palette.amber
        case .upToDate: return Palette.green
        case .noChannel: return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if record.status == .available {
                Button(action: onToggle) {
                    CheckCircle(selected: selected)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: record.bundleURL.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(record.appName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if record.isRunning { Pill(text: L("Running"), tint: Palette.amber) }
                    if let openedAt = record.openedAt {
                        Pill(text: L("Opened %@", Fmt.relativeDate(openedAt)), tint: Palette.green)
                    }
                }
                Text(record.bundleID).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Text(record.errorMessage ?? detailLine)
                    .font(.system(size: 9.5)).foregroundStyle(record.status == .failed ? Palette.coral : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.versionComparison)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(record.status == .available ? Palette.accent : .secondary)
                HStack(spacing: 5) {
                    Pill(text: record.source.shortTitle, icon: record.source.symbol, tint: tint)
                    if let size = record.updateSize {
                        Text(Fmt.bytes(size)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            if record.status.isActionable {
                Button(record.status == .available ? L("Open") : record.actionTitle) { onOpen() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onInfo) { Image(systemName: "info.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Show Details"))
                .opacity(hovering ? 1 : 0.45)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if record.status.isActionable {
                Button(record.actionTitle, action: onOpen)
                if record.status == .available {
                    Button(L("Copy update page address"), action: onCopy)
                }
            }
            Button(L("Reveal in Finder"), action: onReveal)
            Button(L("Show Details"), action: onInfo)
            Button(L("Add to Ignore List"), action: onIgnore)
        }
    }

    private var detailLine: String {
        switch record.status {
        case .available:
            return record.source == .sparkle ? L("A newer version is available.") : record.actionTitle
        case .upToDate:
            return L("The app's feed reports this version is current.")
        case .appStore:
            return L("This app is managed by the App Store.")
        case .appleSoftwareUpdate:
            return L("Apple apps update through Software Update.")
        case .noChannel:
            return L("This app does not publish a readable update feed.")
        case .incompatible:
            return L("This update requires a newer macOS.")
        case .failed:
            return L("The update feed could not be read.")
        }
    }
}

// MARK: - Review

struct UpdaterReviewSheet: View {
    @ObservedObject var model: UpdaterModel
    @Binding var detail: AppUpdateRecord?
    var onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var chosen: [AppUpdateRecord] {
        model.reviewRecords.filter { model.reviewIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Review app updates")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Check each version, then open the vendor's page. Fettle never runs an installer."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close"), action: onClose).buttonStyle(.borderless)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.reviewRecords) { record in
                        reviewRow(record)
                    }
                    BannerView(
                        icon: "exclamationmark.triangle.fill",
                        title: L("Installation stays with the vendor"),
                        message: L("Fettle opens the download or store page. If the app is running, quit it before you install. No file is downloaded or executed by Fettle."),
                        tint: Palette.amber
                    )
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Button(L("Select All")) { model.reviewIDs = Set(model.reviewRecords.map { $0.id }) }
                    .buttonStyle(.borderless)
                Button(L("Deselect All")) { model.reviewIDs.removeAll() }
                    .buttonStyle(.borderless)
                Spacer()
                Text(L("%d selected", chosen.count)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Button(L("Open Update Pages")) {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        model.requestOpenSelected()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(Palette.background(scheme))
        .frame(width: 780, height: 620)
        .sheet(item: $detail) { record in
            AppUpdateDetailSheet(record: record, model: model) { detail = nil }
        }
    }

    private func reviewRow(_ record: AppUpdateRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleReview(record) } label: {
                CheckCircle(selected: model.reviewIDs.contains(record.id))
            }
            .buttonStyle(.plain)
            Image(nsImage: NSWorkspace.shared.icon(forFile: record.bundleURL.path))
                .resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.appName).font(.system(size: 13.5, weight: .bold, design: .rounded))
                    Pill(text: record.source.shortTitle, icon: record.source.symbol, tint: Palette.accent)
                    if let opened = record.openedAt {
                        Pill(text: L("Opened %@", Fmt.relativeDate(opened)), tint: Palette.green)
                    }
                }
                Text(record.bundleID).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(L("Current: %@", record.currentVersion), systemImage: "app")
                    Label(L("Latest: %@", record.latestVersion ?? "—"), systemImage: "arrow.down")
                    if let size = record.updateSize { Label(Fmt.bytes(size), systemImage: "externaldrive") }
                    if let date = record.releaseDate { Label(Fmt.dateTime(date), systemImage: "calendar") }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                if let notes = record.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = record.actionURL {
                    Text(url.absoluteString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(record.versionComparison)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.accent)
                Button(L("Details")) { detail = record }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
    }
}

// MARK: - Detail

struct AppUpdateDetailSheet: View {
    var record: AppUpdateRecord
    @ObservedObject var model: UpdaterModel
    var onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: record.bundleURL.path))
                    .resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.appName).font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(record.bundleID).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        MetricTile(icon: "app", label: L("Current version"), value: record.currentVersion, tint: Palette.blue)
                        MetricTile(icon: "arrow.down", label: L("Latest version"), value: record.latestVersion ?? "—", tint: record.status == .available ? Palette.accent : Palette.violet)
                        MetricTile(icon: "square.and.arrow.down", label: L("Update size"), value: record.updateSize.map { Fmt.bytes($0) } ?? "—", tint: Palette.green)
                    }
                    infoRow(L("Status"), record.status.title)
                    infoRow(L("Update source"), record.source.title)
                    if let url = record.feedURL { infoRow(L("Update feed"), url.absoluteString, monospaced: true) }
                    if let url = record.actionURL { infoRow(record.status == .appStore ? L("App Store page") : (record.status == .appleSoftwareUpdate ? L("Software Update page") : L("Update page")), url.absoluteString, monospaced: true) }
                    if let date = record.releaseDate { infoRow(L("Release date"), Fmt.dateTime(date)) }
                    if let minimum = record.minimumSystemVersion { infoRow(L("Requires macOS"), minimum) }
                    if let error = record.errorMessage {
                        BannerView(icon: "info.circle", title: record.status.title, message: error, tint: record.status == .failed ? Palette.coral : Palette.blue)
                    }
                    if let notes = record.releaseNotes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("What's New")).font(.system(size: 12, weight: .semibold))
                            Text(notes).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 8) {
                Button(L("Reveal in Finder")) { model.reveal(record) }
                    .buttonStyle(.borderless)
                Button(L("Copy Update Page")) { model.copyDownload(record) }
                    .buttonStyle(.borderless)
                    .disabled(record.actionURL == nil)
                Spacer()
                Button(L("Add to Ignore List")) { model.ignore(record); onClose() }
                    .buttonStyle(.borderless)
                if record.status.isActionable {
                    Button(record.actionTitle) { model.openSingle(record); onClose() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                }
            }
            .padding(16)
        }
        .background(Palette.background(scheme))
        .frame(width: 620, height: 560)
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 10, design: .monospaced) : .system(size: 11.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
