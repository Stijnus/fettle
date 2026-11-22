import SwiftUI

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var detailItem: ScanItem?
    @State private var showSkipped = false

    private var visible: [ScanItem] { model.filteredItems(query: app.searchText) }
    private var actionable: [ScanItem] { visible.filter { !$0.isInformational } }
    private var informational: [ScanItem] { visible.filter { $0.isInformational } }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .maintenance,
                title: L("Maintenance"),
                message: L("Fettle checks broken aliases, damaged preferences, invalid personal startup agents and leftovers from uninstalled apps. Uncertain items stay informational.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.report == nil ? L("Check") : L("Scan Again"), systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            if !model.isScanning, let entry = model.report?.firstUnreadable {
                BannerView(icon: "lock", title: L("Partial scan"), message: entry.path + " · " + entry.reason,
                           tint: Palette.amber, actionTitle: L("Open Privacy Settings"), action: { SystemActions.openPrivacySettings() })
                    .padding(.horizontal, 24)
            }
            if model.isScanning {
                ScanProgressBar(progress: model.progress, phase: model.phase) { model.cancel() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if model.report != nil {
                stats
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                InfoNote(
                    icon: "shield.lefthalf.filled",
                    title: L("Repair covers your broken aliases, damaged preferences, invalid personal LaunchAgents and confirmed leftovers."),
                    message: L("System files, live preferences and security settings are never changed.")
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
                HStack(spacing: 8) {
                    Spacer()
                    Button { showSkipped = true } label: { Label(L("Skipped") + " \(model.skipped.count)", systemImage: "minus.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                    Button { model.selectAll(query: app.searchText) } label: { Label(L("Select All"), systemImage: "checkmark.circle") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
                resultsList
            } else if !model.isScanning {
                EmptyStateView(
                    icon: "wrench.and.screwdriver",
                    title: L("Check for broken aliases, damaged preferences, invalid startup agents and confirmed leftovers."),
                    message: L("Scans are read-only. Nothing is selected until you choose a finding to repair."),
                    actionTitle: L("Run maintenance check"),
                    action: { model.startScan() }
                )
            }
        }
        .background(Palette.background(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.report != nil {
                SelectionBar(
                    count: model.selectedIDs.count,
                    bytes: model.selectedItems().reduce(0) { $0 + $1.size },
                    primaryTitle: L("Repair"),
                    primaryIcon: "wrench.adjustable",
                    isEnabled: !model.selectedItems().isEmpty && !model.isWorking
                ) {
                    model.repairSelected()
                } onClear: {
                    model.deselectAll()
                }
            }
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) { model.performConfirmed(request) } onCancel: { model.confirmation = nil }
        }
        .sheet(item: $model.outcome) { outcome in OutcomeSheet(outcome: outcome) }
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .sheet(isPresented: $showSkipped) { SkippedSheet(skipped: model.skipped) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 70) }
        }
        .task {
            if model.report == nil && !model.isScanning { model.startScan() }
        }
    }

    private var stats: some View {
        SummaryCard(
            label: L("Findings"),
            value: "\(model.findingCount)",
            caption: Fmt.bytes(model.estimatedBytes),
            facts: [
                SummaryFact(icon: "link.badge.plus", label: L("Broken aliases"), value: "\(model.brokenAliases.count)", tint: Palette.amber, help: L("User-owned links only")),
                SummaryFact(icon: "bolt.slash", label: L("Invalid startup agents"), value: "\(model.invalidAgents.count)", tint: Palette.coral, help: L("Personal LaunchAgents")),
                SummaryFact(icon: "doc.badge.gearshape", label: L("Broken preferences"), value: "\(model.brokenPreferences.count)", tint: Palette.blue),
                SummaryFact(icon: "questionmark.folder", label: L("Confirmed leftovers"), value: "\(model.leftovers.count)", tint: Palette.violet),
                SummaryFact(icon: "info.circle", label: L("Uncertain items"), value: "\(model.uncertain.count)", tint: .secondary, help: L("Kept informational"))
            ]
        )
    }

    private var resultsList: some View {
        List(selection: $model.selectedIDs) {
            if !actionable.isEmpty {
                Section {
                    ForEach(actionable) { item in
                        row(item)
                    }
                } header: {
                    listHeader(L("Findings"), count: actionable.count, size: actionable.reduce(0) { $0 + $1.size }, tint: Palette.accent)
                }
            }
            if !informational.isEmpty {
                Section {
                    ForEach(informational) { item in
                        row(item)
                    }
                } header: {
                    listHeader(L("Informational"), count: informational.count, size: informational.reduce(0) { $0 + $1.size }, tint: .secondary)
                } footer: {
                    Text(L("Uncertain items are never repaired by Fettle. They are shown so you can inspect them."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if visible.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: L("No problems found."), message: L("Your personal startup definitions look valid."))
            }
        }
    }

    private func row(_ item: ScanItem) -> some View {
        ScanItemRow(
            item: item,
            selected: model.selectedIDs.contains(item.id),
            selectable: !item.isInformational,
            onToggle: { model.toggle(item) },
            onReveal: { FileSafety.revealInFinder(item.url) },
            onInfo: { detailItem = item },
            onIgnore: { app.ignore(item) }
        )
        .tag(item.id)
        .selectionDisabled(item.isInformational)
        .contextMenu {
            Button(L("Reveal in Finder")) { FileSafety.revealInFinder(item.url) }
            Button(L("Copy Path")) { FileSafety.copyPath(item.path) }
            Button(L("Show Details")) { detailItem = item }
            if !item.isInformational {
                Divider()
                Button(L("Add to Ignore List")) { app.ignore(item) }
            }
        }
    }

    private func listHeader(_ title: String, count: Int, size: Int64, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Text(Fmt.bytes(size)).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }
}
