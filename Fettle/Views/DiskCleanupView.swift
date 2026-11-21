import SwiftUI
import AppKit

struct DiskCleanupView: View {
    @ObservedObject var model: DiskCleanupModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var detailItem: ScanItem?
    @State private var showSkipped = false
    @State private var showDrivePicker = false
    @State private var showProtectedInfo = false

    private var visibleItems: [ScanItem] {
        model.filteredItems(query: app.searchText)
    }

    private var groups: [CategoryGroup] {
        let order = ItemCategory.allCases
        return order.compactMap { category in
            let items = visibleItems.filter { $0.category == category }
            guard !items.isEmpty else { return nil }
            return CategoryGroup(category: category, items: items.sorted {
                if $0.location != $1.location { return $0.location < $1.location }
                return $0.size > $1.size
            })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isScanning {
                ScanProgressBar(progress: model.progress, phase: model.phase) { model.cancel() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
            modeBanner
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            if model.mode == .largeFiles {
                HStack(spacing: 10) {
                    Text(L("Minimum size")).font(.system(size: 11, weight: .medium))
                    Picker("", selection: Binding(
                        get: { Int(model.minimumSizeMB) },
                        set: { model.minimumSizeMB = Int64($0); app.settings.largeFileThresholdMB = $0 }
                    )) {
                        ForEach([10, 50, 100, 500, 1_000], id: \.self) { value in
                            Text("\(value) MB").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button(L("Scan Again")) {
                        if let root = model.largeFileRoot {
                            model.startLargeFileScan(root: root, minimumMB: model.minimumSizeMB)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Text(L("Nothing is selected by default.")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            if let report = model.report {
                stats(report)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                resultsList
            } else if !model.isScanning {
                EmptyStateView(
                    icon: "internaldrive",
                    title: L("Scan your Mac to see what can go."),
                    message: L("Read-only scan. Your selection starts empty and nothing changes until you confirm."),
                    actionTitle: L("Scan for junk"),
                    action: { model.startScan() }
                )
            }
        }
        .background(Palette.background(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.report != nil {
                bottomBar
            }
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) {
                model.performConfirmed(request)
            } onCancel: {
                model.confirmation = nil
            }
        }
        .sheet(item: $model.outcome) { outcome in
            OutcomeSheet(outcome: outcome)
        }
        .sheet(item: $detailItem) { item in
            ItemDetailView(item: item)
        }
        .sheet(isPresented: $showSkipped) {
            SkippedSheet(skipped: model.skipped)
        }
        .sheet(isPresented: $showDrivePicker) {
            DrivePickerSheet(volumes: model.driveChoices) { volume in
                showDrivePicker = false
                model.startExternalScan(volume)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast).padding(.bottom, 70)
            }
        }
        .onAppear {
            model.refreshDrives()
            if model.report == nil && model.minimumSizeMB != Int64(app.settings.largeFileThresholdMB) {
                model.minimumSizeMB = Int64(app.settings.largeFileThresholdMB)
            }
        }
    }

    private var header: some View {
        ModuleHeader(
            module: .disk,
            title: model.mode == .largeFiles ? L("Large files") : (model.mode == .external ? L("External drive") : L("Disk Cleanup")),
            message: model.mode == .largeFiles
                ? L("Choose a folder to look for large files. Nothing is selected automatically.")
                : L("Fettle looks at caches, logs, crash reports and temporary files for your account. Backups, app resources and personal documents stay out.")
        ) {
            Button {
                if model.mode == .cleanup { model.startScan() } else { model.switchToCleanup() }
            } label: {
                Label(model.report == nil ? L("Scan") : L("Scan Again"), systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(.large)
            .disabled(model.isScanning)

            Menu {
                Button(L("Scan for junk")) { model.switchToCleanup() }
                Divider()
                Button(L("Large files…")) { chooseLargeFileFolder() }
                Button(L("Scan external drive…")) {
                    model.refreshDrives()
                    if model.driveChoices.isEmpty {
                        model.toast(L("No external drive was found."))
                    } else {
                        showDrivePicker = true
                    }
                }
                if model.mode != .cleanup {
                    Divider()
                    Button(L("Close")) { model.switchToCleanup() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help(L("More options"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var modeBanner: some View {
        if model.mode == .largeFiles, let root = model.largeFileRoot {
            BannerView(
                icon: "doc.zipper",
                title: L("Large files in %@", root.lastPathComponent),
                message: L("Minimum size") + ": " + "\(model.minimumSizeMB) MB · " + L("Nothing is selected by default."),
                tint: Palette.violet,
                actionTitle: L("Choose Folder…"),
                action: { chooseLargeFileFolder() }
            )
        } else if model.mode == .external, let volume = model.externalVolume {
            BannerView(
                icon: "externaldrive.fill",
                title: volume.name,
                message: L("Items on an external drive are never selected automatically. Review the volume, Trash and temporary files before cleaning."),
                tint: Palette.blue,
                actionTitle: L("Close"),
                action: { model.switchToCleanup() }
            )
        }
    }

    private func stats(_ report: ScanReport) -> some View {
        let found = visibleItems.filter { $0.category != .trash && !$0.isInformational }.count
        return SummaryCard(
            label: L("Estimated removable"),
            value: Fmt.bytes(model.estimatedBytes),
            caption: "\(found) " + L("items found"),
            facts: [
                SummaryFact(icon: "trash.circle", label: L("Trash"), value: Fmt.bytes(model.trashBytes), tint: Palette.amber),
                SummaryFact(icon: "minus.circle", label: L("Skipped"), value: "\(model.skipped.count)", tint: Palette.amber, help: L("Skipped with a reason"), action: { showSkipped = true })
            ]
        ) {
            SelectionSummary(count: model.selectedIDs.count, bytes: model.selectedItems().reduce(0) { $0 + $1.size }) {
                let selectableCount = visibleItems.filter { model.isSelectable($0) }.count
                if model.selectedIDs.count == selectableCount {
                    model.deselectAll()
                } else {
                    model.selectAll(query: app.searchText)
                }
            }
        }
    }

    private var resultsList: some View {
        List(selection: $model.selectedIDs) {
            ForEach(groups) { group in
                Section {
                    let locations = Dictionary(grouping: group.items, by: { $0.location })
                    ForEach(locations.keys.sorted(), id: \.self) { location in
                        locationRow(location, items: locations[location] ?? [])
                        ForEach(locations[location] ?? []) { item in
                            ScanItemRow(
                                item: item,
                                selected: model.selectedIDs.contains(item.id),
                                selectable: model.isSelectable(item),
                                showLocation: false,
                                onToggle: { model.toggle(item) },
                                onReveal: { FileSafety.revealInFinder(item.url) },
                                onInfo: { detailItem = item },
                                onIgnore: { app.ignore(item) }
                            )
                            .tag(item.id)
                            .selectionDisabled(!model.isSelectable(item))
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    categoryHeader(group)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .overlay {
            if visibleItems.isEmpty {
                let isSearching = !app.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                EmptyStateView(
                    icon: isSearching ? "magnifyingglass" : "checkmark.seal",
                    title: isSearching ? L("No results") : L("All clean"),
                    message: isSearching ? L("Try a different search.") : L("Fettle found nothing to remove.")
                )
            }
        }
    }

    private func categoryHeader(_ group: CategoryGroup) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: group.category.symbol, tint: Palette.tint(for: group.category), size: 24)
            Text(group.category.title).font(.system(size: 12, weight: .semibold))
            Text("\(group.items.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Text(Fmt.bytes(group.items.reduce(0) { $0 + $1.size }))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func locationRow(_ location: String, items: [ScanItem]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(location).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text("\(items.count)").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.leading, 26)
        .padding(.vertical, 1)
        .selectionDisabled(true)
        .listRowBackground(Color.clear)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if model.mode == .cleanup && !model.trashItems.filter({ !$0.isExternal }).isEmpty {
                DeleteTrashBar(count: model.trashItems.filter { !$0.isExternal }.count, bytes: model.trashBytes) {
                    model.requestEmptyTrash()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            SelectionBar(
                count: model.selectedIDs.count,
                bytes: model.selectedItems().reduce(0) { $0 + $1.size },
                primaryTitle: model.mode == .external ? L("Permanent Delete") : L("Remove"),
                primaryIcon: "trash",
                isDestructive: model.mode == .external,
                isEnabled: !model.selectedItems().isEmpty && !model.isWorking
            ) {
                model.requestRemoveSelected()
            } onClear: {
                model.deselectAll()
            }
        }
        .background(.regularMaterial)
    }

    private func chooseLargeFileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose Folder…")
        panel.message = L("Choose a folder to look for large files. Nothing is selected automatically.")
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.largeFileThresholdMB = Int(model.minimumSizeMB)
            model.startLargeFileScan(root: url, minimumMB: model.minimumSizeMB)
        }
    }
}

struct CategoryGroup: Identifiable {
    var category: ItemCategory
    var items: [ScanItem]
    var id: String { category.rawValue }
}

struct SkippedSheet: View {
    var skipped: [SkippedItem]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("What Fettle skipped")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Why items are skipped")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close")) { dismiss() }.buttonStyle(.bordered)
            }
            if skipped.isEmpty {
                Text(L("Nothing was skipped.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(skipped) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "minus.circle").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.path).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Text(entry.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 480)
    }
}

struct DrivePickerSheet: View {
    var volumes: [VolumeInfo]
    var onSelect: (VolumeInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Select the drive you want to inspect.")).font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.borderless)
            }
            if volumes.isEmpty {
                Text(L("No external drive was found.")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(volumes) { volume in
                        Button {
                            onSelect(volume)
                        } label: {
                            HStack(spacing: 10) {
                                IconTile(symbol: "externaldrive.fill", tint: Palette.blue, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.name).font(.system(size: 12.5, weight: .semibold))
                                    Text("\(Fmt.bytes(volume.available)) " + L("free") + " · " + Fmt.bytes(volume.total))
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
