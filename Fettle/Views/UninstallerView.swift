import SwiftUI
import AppKit

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var detailItem: ScanItem?
    @State private var showLeftovers = false
    @State private var showFolders = false

    private var visibleApps: [AppRecord] {
        let query = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
                || $0.version.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .uninstaller,
                title: L("Uninstaller"),
                message: L("Fettle lists apps and matches support files by exact bundle identifier. Shared containers and ambiguous matches are never removed.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.apps.isEmpty ? L("Scan") : L("Scan Again"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)

                Menu {
                    Button(L("Add app folder…")) { chooseFolder() }
                    ForEach(model.appFolders, id: \.self) { folder in
                        Button(L("Remove from scan") + ": " + PathDisplay.short(folder)) { model.removeAppFolder(folder) }
                    }
                    Divider()
                    Button(L("Scan for leftovers…")) { showLeftovers = true }
                    Button(L("Rescan after uninstaller")) { model.startScan() }
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

            if model.apps.isEmpty && !model.isScanning {
                EmptyStateView(
                    icon: "trash.square",
                    title: L("List installed apps"),
                    message: L("Fettle reads /Applications, your Applications folder and any folder you add. Nothing is selected by default."),
                    actionTitle: L("Scan installed apps"),
                    action: { model.startScan() }
                )
            } else {
                stats
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                if !model.runningApps.isEmpty {
                    BannerView(
                        icon: "exclamationmark.triangle.fill",
                        title: L("Running apps"),
                        message: model.runningApps.count == 1
                            ? L("%@ is running. Quit it before removing its files, or the removal will be skipped.", model.runningApps[0].name)
                            : L("%@ are running. Quit them before removing their files, or the removal will be skipped.", Fmt.list(model.runningApps.map(\.name))),
                        tint: Palette.amber,
                        actionTitle: model.runningApps.count == 1 ? L("Quit App") : L("Quit %d Apps", model.runningApps.count),
                        action: { model.quitRunningApps() }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
                if !model.notes.isEmpty {
                    bannerForNotes
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                }
                HStack(spacing: 8) {
                    Text(L("Apps")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.selectAllApps(visibleApps) } label: { Label(L("Select All"), systemImage: "checkmark.circle") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
                if model.isScanning && model.apps.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(L("Scanning installed apps…")).font(.system(size: 12, weight: .medium))
                        Text(model.phase).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    appList
                }
            }
        }
        .background(Palette.background(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.apps.isEmpty {
                SelectionBar(
                    count: model.selectedAppIDs.count,
                    bytes: model.selectedBytes,
                    primaryTitle: L("Review…"),
                    primaryIcon: "checklist",
                    isEnabled: !model.selectedApps.isEmpty && !model.isWorking
                ) {
                    model.beginReview()
                } onClear: {
                    model.selectedAppIDs.removeAll()
                }
            }
        }
        .sheet(isPresented: $model.showReview) {
            UninstallerReviewSheet(model: model, detailItem: $detailItem, onClose: { model.showReview = false })
                .environmentObject(app)
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) {
                switch request.action {
                case .removeApps:
                    model.performConfirmed(request)
                case .moveSelectedToTrash:
                    model.performLeftoverRemoval(request)
                default:
                    model.confirmation = nil
                }
            } onCancel: {
                model.confirmation = nil
            }
        }
        .sheet(item: $model.outcome) { outcome in OutcomeSheet(outcome: outcome) }
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .sheet(isPresented: $showLeftovers) {
            LeftoversSheet(model: model)
                .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 70) }
        }
        .task {
            if model.apps.isEmpty && !model.isScanning { model.startScan() }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            MetricTile(icon: "app.fill", label: L("Apps"), value: "\(model.apps.count)", caption: "\(model.availableApps.count) " + L("can be removed"), tint: Palette.accent)
            MetricTile(icon: "externaldrive", label: L("Selected"), value: "\(model.selectedApps.count)", caption: Fmt.bytes(model.selectedBytes), tint: Palette.blue)
            MetricTile(icon: "person.crop.circle.badge.exclamationmark", label: L("Running apps"), value: "\(model.runningApps.count)", caption: L("Quit before removing"), tint: Palette.amber)
            MetricTile(icon: "folder", label: L("Scanned folders"), value: "\(2 + model.appFolders.count)", caption: "/Applications, ~/Applications", tint: Palette.violet)
        }
    }

    private var bannerForNotes: some View {
        BannerView(
            icon: "shield.lefthalf.filled",
            title: L("Exact identifier match"),
            message: L("Shared containers may contain data from several apps, so Fettle leaves them alone."),
            tint: Palette.blue
        )
    }

    private var appList: some View {
        List(selection: $model.selectedAppIDs) {
            ForEach(visibleApps) { appRecord in
                AppRow(
                    record: appRecord,
                    selected: model.selectedAppIDs.contains(appRecord.id),
                    selectable: model.isSelectable(appRecord),
                    onToggle: { model.toggle(appRecord) },
                    onQuit: { model.quitApp(appRecord) },
                    onVendor: { model.openVendorUninstaller(appRecord) },
                    onInfo: {
                        if let item = model.appItem(appRecord) { detailItem = item }
                    }
                )
                .tag(appRecord.id)
                .selectionDisabled(!model.isSelectable(appRecord))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if visibleApps.isEmpty && !model.isScanning {
                EmptyStateView(icon: "magnifyingglass", title: L("No results"), message: L("Try a different search."))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add app folder")
        panel.message = L("Fettle lists apps in this folder and matches their support files by exact bundle identifier.")
        if panel.runModal() == .OK, let url = panel.url {
            model.addAppFolder(url)
        }
    }
}

struct AppRow: View {
    var record: AppRecord
    var selected: Bool
    var selectable: Bool
    var onToggle: () -> Void
    var onQuit: () -> Void
    var onVendor: () -> Void
    var onInfo: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onToggle) { CheckCircle(selected: selected, enabled: selectable) }
                .buttonStyle(.plain)
                .disabled(!selectable)
            Image(nsImage: NSWorkspace.shared.icon(forFile: record.bundleURL.path))
                .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if record.isSystem { Pill(text: L("Protected"), tint: Palette.coral) }
                    if record.isRunning { Pill(text: L("Running"), tint: Palette.amber) }
                    if record.accessError != nil { Pill(text: L("Permission denied"), tint: Palette.coral) }
                    if record.vendorUninstaller != nil { Pill(text: L("Vendor uninstaller"), tint: Palette.violet) }
                }
                Text("\(record.bundleID) · \(L("Version")) \(record.version)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(record.source).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if !record.associations.isEmpty {
                Text(Fmt.associatedFiles(record.associations.count))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            Text(Fmt.bytes(record.size))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
            HStack(spacing: 4) {
                if record.isRunning {
                    Button(L("Quit"), action: onQuit).buttonStyle(.borderless).controlSize(.mini)
                }
                if record.vendorUninstaller != nil {
                    Button(L("Open"), action: onVendor).buttonStyle(.borderless).controlSize(.mini)
                }
                if record.fingerprint != nil {
                    Button(action: onInfo) { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).help(L("Show Details"))
                }
            }
            .font(.system(size: 10.5))
            .opacity(hovering ? 1 : 0.5)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct UninstallerReviewSheet: View {
    @ObservedObject var model: UninstallerModel
    @Binding var detailItem: ScanItem?
    var onClose: () -> Void
    @EnvironmentObject private var app: AppModel

    private var allAssociationsForSelected: [ScanItem] {
        model.reviewAssociations
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Apps and associated files")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Select the app and the associated items you want to remove.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close"), action: onClose).buttonStyle(.borderless)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.reviewApps) { appRecord in
                        appSection(appRecord)
                    }
                    if model.reviewApps.contains(where: { !$0.sharedContainers.isEmpty }) {
                        BannerView(
                            icon: "person.2.fill",
                            title: L("Shared containers are protected"),
                            message: L("Shared containers may contain data from several apps, so Fettle leaves them alone."),
                            tint: Palette.blue
                        )
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button(L("Select All")) {
                    model.reviewAppIDs = Set(model.reviewApps.map { $0.id })
                    model.selectAllAssociations(includeData: false)
                }
                .buttonStyle(.borderless)
                Button(L("Deselect All")) {
                    model.reviewAppIDs.removeAll()
                    model.reviewAssociationIDs.removeAll()
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(model.reviewAppIDs.count) " + L("Apps") + " · " + Fmt.associatedFiles(model.reviewAssociationIDs.count))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Button(L("Remove…")) {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        model.requestRemoval()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.coral)
                .disabled(model.reviewAppIDs.isEmpty && model.reviewAssociationIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 620)
    }

    private func appSection(_ appRecord: AppRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { model.toggleReviewApp(appRecord) } label: {
                    CheckCircle(selected: model.reviewAppIDs.contains(appRecord.id))
                }
                .buttonStyle(.plain)
                Image(nsImage: NSWorkspace.shared.icon(forFile: appRecord.bundleURL.path))
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(appRecord.name).font(.system(size: 14, weight: .bold, design: .rounded))
                        if appRecord.isRunning { Pill(text: L("Running"), tint: Palette.amber) }
                        if appRecord.isSystem { Pill(text: L("Protected"), tint: Palette.coral) }
                    }
                    Text("\(appRecord.bundleID) · \(L("Version")) \(appRecord.version) · \(Fmt.bytes(appRecord.size))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if appRecord.isRunning {
                    Button(L("Quit App")) { model.quitApp(appRecord) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if appRecord.vendorUninstaller != nil {
                    Button(L("Open Vendor Uninstaller")) { model.openVendorUninstaller(appRecord) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let error = appRecord.accessError {
                BannerView(icon: "lock.fill", title: L("Permission denied"), message: error, tint: Palette.coral)
            }
            if appRecord.isRunning {
                BannerView(icon: "exclamationmark.triangle.fill", title: L("Running"), message: L("This app is still running. Quit it and rescan before removing it."), tint: Palette.amber)
            }
            let associations = model.reviewAssociations.filter { $0.bundleID == appRecord.bundleID }
            if associations.isEmpty {
                Text(L("No associated files were found. Only the app itself will be removed."))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(associations) { item in
                        HStack(spacing: 9) {
                            Button { model.toggleReviewAssociation(item) } label: {
                                CheckCircle(selected: model.reviewAssociationIDs.contains(item.id))
                            }
                            .buttonStyle(.plain)
                            IconTile(symbol: item.category.symbol, tint: Palette.tint(for: item.category), size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(item.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    if item.isAppData { Pill(text: L("App data"), tint: Palette.coral) }
                                }
                                Text(item.displayPath).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.bytes(item.size)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            Button { detailItem = item } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            Button {
                                app.ignore(item)
                                model.reviewAssociations.removeAll { $0.id == item.id }
                                model.reviewAssociationIDs.remove(item.id)
                            } label: {
                                Image(systemName: "eye.slash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L("Add to Ignore List"))
                        }
                        .padding(.vertical, 5)
                        .padding(.leading, 30)
                        Divider().opacity(0.3)
                    }
                }
                if associations.contains(where: { $0.isAppData }) {
                    Text(L("This item contains app data. Review it carefully."))
                        .font(.system(size: 10)).foregroundStyle(Palette.coral)
                }
            }
            if !appRecord.sharedContainers.isEmpty {
                Text(L("Shared containers are protected") + ": " + appRecord.sharedContainers.joined(separator: ", "))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
    }
}

struct LeftoversSheet: View {
    @ObservedObject var model: UninstallerModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @State private var detailItem: ScanItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Leftovers from removed apps")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Removed apps leave a receipt only if they were installed by an installer. Fettle confirms a leftover only when an identifier is clearly unowned and appears in two or more standard locations."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("Close")) { dismiss() }.buttonStyle(.borderless)
            }
            .padding(20)
            Divider()
            if model.isScanningLeftovers {
                ScanProgressBar(progress: model.leftoverProgress, phase: model.leftoverPhase) {
                    model.cancelLeftoverScan()
                }
                .padding(20)
            } else if let report = model.leftoverReport {
                if report.items.isEmpty {
                    EmptyStateView(icon: "checkmark.seal", title: L("No confirmed leftovers were found."), message: L("Uncertain items stay visible in Maintenance."))
                } else {
                    List(selection: $model.leftoverSelectedIDs) {
                        ForEach(report.items) { item in
                            ScanItemRow(
                                item: item,
                                selected: model.leftoverSelectedIDs.contains(item.id),
                                selectable: true,
                                showLocation: true,
                                onToggle: {
                                    if model.leftoverSelectedIDs.contains(item.id) { model.leftoverSelectedIDs.remove(item.id) } else { model.leftoverSelectedIDs.insert(item.id) }
                                },
                                onReveal: { FileSafety.revealInFinder(item.url) },
                                onInfo: { detailItem = item },
                                onIgnore: { app.ignore(item) }
                            )
                            .tag(item.id)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } else {
                EmptyStateView(icon: "questionmark.folder", title: L("Scan for leftovers…"), message: L("Fettle looks for identifiers that no installed app claims and that appear in two or more standard locations."), actionTitle: L("Scan for leftovers…"), action: { model.startLeftoverScan() })
            }
            Divider()
            HStack {
                if model.leftoverReport != nil {
                    Button(L("Scan Again")) { model.startLeftoverScan() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button(L("Move to Trash…")) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        model.requestLeftoverRemoval()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.coral)
                .disabled(model.leftoverSelectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .task {
            if model.leftoverReport == nil && !model.isScanningLeftovers { model.startLeftoverScan() }
        }
    }
}
