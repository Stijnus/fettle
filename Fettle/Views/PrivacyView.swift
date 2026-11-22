import SwiftUI

struct PrivacyView: View {
    @ObservedObject var model: PrivacyModel
    @State private var refreshOnReturn = false
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var detailItem: ScanItem?
    @State private var categoryFilter: ItemCategory?
    @State private var showSkipped = false

    private var visible: [ScanItem] {
        var items = model.filteredItems(query: app.searchText).filter { $0.category != .recentItems }
        if let categoryFilter {
            items = items.filter { $0.category == categoryFilter }
        }
        return items
    }

    private var locations: [(String, [ScanItem])] {
        Dictionary(grouping: visible, by: { $0.location })
            .map { ($0.key, $0.value.sorted { lhs, rhs in
                if lhs.category != rhs.category { return PrivacyScanner.categoryOrder(lhs.category) < PrivacyScanner.categoryOrder(rhs.category) }
                return lhs.size > rhs.size
            }) }
            .sorted { $0.0 < $1.0 }
    }

    private var categoriesPresent: [ItemCategory] {
        let set = Set(model.items.map { $0.category })
        return [.browserCache, .cookies, .websiteData, .browsingHistory, .downloadHistory].filter { set.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .privacy,
                title: L("Privacy"),
                message: L("Fettle lists browser caches, cookies, history and download history. Passwords and saved credentials are never read. Clearing site data can sign you out of websites.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.report == nil ? L("Scan") : L("Scan Again"), systemImage: "hand.raised")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)
                Menu {
                    Section(L("Passwords & credentials")) {
                        ForEach(Array(Set(model.profiles.map { $0.browser }))) { browser in
                            Button(browser.displayName) {
                                model.openPasswordSettings(browser)
                            }
                        }
                    }
                    Divider()
                    Button(L("Open Privacy Settings")) {
                        refreshOnReturn = true; SystemActions.openPrivacySettings()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("More"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            if !model.isScanning, let entry = model.report?.firstUnreadable {
                BannerView(icon: "lock", title: L("Partial scan"), message: entry.path + " · " + entry.reason,
                           tint: Palette.amber, actionTitle: L("Open Privacy Settings"), action: { refreshOnReturn = true; SystemActions.openPrivacySettings() })
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
                    .padding(.bottom, 8)
                profileStrip
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                recentStrip
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                HStack(spacing: 8) {
                    Menu {
                        Button(L("All categories")) { categoryFilter = nil }
                        ForEach(categoriesPresent, id: \.self) { category in
                            Button(category.title) { categoryFilter = category }
                        }
                    } label: {
                        Label(categoryFilter?.title ?? L("All categories"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button { showSkipped = true } label: { Label(L("Skipped") + " \(model.skipped.count)", systemImage: "minus.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                    Spacer()
                    Button {
                        if !model.selectedIDs.isEmpty && model.selectedIDs.count >= visible.count {
                            model.selectedIDs.removeAll()
                        } else {
                            model.selectAll(query: app.searchText)
                        }
                    } label: {
                        Label(L("Select All"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
                resultsList
            } else if !model.isScanning {
                EmptyStateView(
                    icon: "hand.raised",
                    title: L("Scan browser data"),
                    message: L("Browsers are read where their profiles are available. Safari data is protected by macOS and may require permission."),
                    actionTitle: L("Scan browser data"),
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
                    primaryTitle: L("Clear"),
                    primaryIcon: "eraser",
                    isDestructive: true,
                    isEnabled: !model.selectedItems().isEmpty && !model.isWorking
                ) {
                    model.requestClear()
                } onClear: {
                    model.selectedIDs.removeAll()
                }
            }
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) { model.performClear(request) } onCancel: { model.confirmation = nil }
        }
        .sheet(item: $model.outcome) { outcome in OutcomeSheet(outcome: outcome) }
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .sheet(isPresented: $showSkipped) { SkippedSheet(skipped: model.skipped) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 70) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard refreshOnReturn else { return }
            refreshOnReturn = false
            if !model.isScanning { model.startScan() }
        }
        .task {
            if model.report == nil && !model.isScanning { model.startScan() }
        }
    }

    private var stats: some View {
        let cache = bytes(for: .browserCache)
        let cookies = bytes(for: .cookies) + bytes(for: .websiteData)
        let history = bytes(for: .browsingHistory)
        return SummaryCard(
            label: L("Browser data"),
            value: Fmt.bytes(cache + cookies + history),
            caption: model.profiles.first?.profileName ?? L("No supported browser profile was found."),
            facts: [
                SummaryFact(icon: "shippingbox", label: L("Cache"), value: Fmt.bytes(cache), tint: Palette.blue, help: L("Clearing cache does not sign you out.")),
                SummaryFact(icon: "circle.grid.cross", label: L("Cookies & site data"), value: Fmt.bytes(cookies), tint: Palette.amber, help: L("Cookies will sign you out")),
                SummaryFact(icon: "clock.arrow.circlepath", label: L("Browsing history"), value: Fmt.bytes(history), tint: Palette.violet, help: L("Local history only")),
                SummaryFact(icon: "globe", label: L("Profiles"), value: "\(model.profiles.count)", tint: Palette.accent)
            ]
        )
    }

    private func bytes(for category: ItemCategory) -> Int64 {
        model.items.filter { $0.category == category && !$0.isInformational && !$0.isProtected }.reduce(0) { $0 + $1.size }
    }

    private var profileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.profiles) { profile in
                    HStack(spacing: 7) {
                        Image(systemName: profile.browser == .safari ? "safari" : (profile.browser == .firefox ? "flame" : "globe"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profile.profileName == profile.browser.displayName ? profile.browser.displayName : "\(profile.browser.displayName) — \(profile.profileName)")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(profile.isRunning ? L("Running") : L("Available"))
                                .font(.system(size: 9))
                                .foregroundStyle(profile.isRunning ? Palette.amber : .secondary)
                        }
                        if profile.isRunning {
                            Button(L("Quit %@", profile.browser.displayName)) {
                                model.quitBrowser(profile.browser)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }
                        Button {
                            model.openPasswordSettings(profile.browser)
                        } label: {
                            Image(systemName: "key")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Open Password Settings"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                }
                Button {
                    showSkipped = true
                } label: {
                    Label(L("Skipped") + " \(model.skipped.count)", systemImage: "minus.circle")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var recentStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill").foregroundStyle(Palette.amber).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Recent items")).font(.system(size: 11.5, weight: .semibold))
                Text(L("Recent items are managed by macOS. Open Finder or the Apple menu to review and clear them."))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                if !model.recentItems.isEmpty {
                    Text(model.recentItems.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Button(L("Open Finder")) { refreshOnReturn = true; SystemActions.openFinderHome() }
                Button(L("Open Desktop & Dock Settings")) { refreshOnReturn = true; SystemActions.openSettings(.desktopDock) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .fixedSize()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.amber.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.amber.opacity(0.14), lineWidth: 1))
    }

    private var resultsList: some View {
        List(selection: $model.selectedIDs) {
            ForEach(locations.indices, id: \.self) { index in
                let location = locations[index]
                Section {
                    let grouped = Dictionary(grouping: location.1, by: { $0.category })
                    ForEach(categoriesPresent.filter { grouped[$0] != nil }, id: \.self) { category in
                        categoryRow(category, items: grouped[category] ?? [])
                        ForEach(grouped[category] ?? []) { item in
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
                    HStack(spacing: 7) {
                        Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(Palette.accent)
                        Text(location.0).font(.system(size: 11.5, weight: .semibold))
                        Text("\(location.1.count)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.bytes(location.1.reduce(0) { $0 + $1.size })).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if visible.isEmpty {
                let isSearching = !app.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                EmptyStateView(
                    icon: isSearching ? "magnifyingglass" : "checkmark.seal",
                    title: isSearching ? L("No results") : L("All clean"),
                    message: isSearching ? L("Try a different search.") : L("No browser data was found.")
                )
            }
        }
    }

    private func categoryRow(_ category: ItemCategory, items: [ScanItem]) -> some View {
        HStack(spacing: 6) {
            IconTile(symbol: category.symbol, tint: Palette.tint(for: category), size: 20)
            Text(category.title).font(.system(size: 10, weight: .semibold))
            Text("\(items.count)").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            if category == .cookies || category == .websiteData {
                Text(L("Cookies will sign you out")).font(.system(size: 9)).foregroundStyle(Palette.amber)
            } else if category == .downloadHistory {
                Text(L("Downloads stay on disk")).font(.system(size: 9)).foregroundStyle(Palette.green)
            }
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
        .selectionDisabled(true)
        .listRowBackground(Color.clear)
    }
}

extension BrowserKind: Identifiable {
    var id: String { rawValue }
}
