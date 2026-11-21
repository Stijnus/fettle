import SwiftUI

struct ExtensionsView: View {
    @ObservedObject var model: ExtensionsModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme

    private var visible: [ExtensionRecord] {
        let query = app.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.records }
        return model.records.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.provider.localizedCaseInsensitiveContains(query)
        }
    }

    private var grouped: [(kind: ExtensionRecord.Kind, records: [ExtensionRecord])] {
        let order: [ExtensionRecord.Kind] = [.system, .safari, .chromium, .firefox]
        return order.compactMap { kind in
            let records = visible.filter { $0.kind == kind }
            return records.isEmpty ? nil : (kind, records)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .extensions,
                title: L("Extensions"),
                message: L("Fettle uses macOS and browser-provided information. It can only change extensions where macOS or the browser exposes a supported control; otherwise it opens the right settings.")
            ) {
                Button {
                    model.startScan()
                } label: {
                    Label(model.records.isEmpty ? L("Scan") : L("Scan Again"), systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .controlSize(.large)
                .disabled(model.isScanning)
                Button {
                    model.openLoginItemsSettings()
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
                EmptyStateView(icon: "puzzlepiece.extension", title: L("No extensions were reported."), message: L("Extension information is limited to what the system exposes."), actionTitle: L("Scan extensions"), action: { model.startScan() })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            MetricTile(icon: "puzzlepiece", label: L("System extensions"), value: "\(model.records.filter { $0.kind == .system }.count)", caption: L("System-managed"), tint: Palette.violet)
                            MetricTile(icon: "safari", label: L("Safari extensions"), value: "\(model.records.filter { $0.kind == .safari }.count)", caption: L("Managed in Safari"), tint: Palette.blue)
                            MetricTile(icon: "globe", label: L("Browser add-ons"), value: "\(model.records.filter { $0.kind == .chromium || $0.kind == .firefox }.count)", caption: L("Chrome, Edge, Opera and Firefox"), tint: Palette.accent)
                            MetricTile(icon: "person.crop.rectangle.stack", label: L("Profiles"), value: "\(model.profiles.count)", caption: model.profiles.first ?? L("No supported browser profile was found."), tint: Palette.amber)
                        }
                        ForEach(grouped, id: \.kind) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: sectionTitle(group.kind), subtitle: sectionSubtitle(group.kind))
                                VStack(spacing: 8) {
                                    ForEach(group.records) { record in
                                        ExtensionRow(record: record) { model.open(record) }
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
                .background(Palette.background(scheme))
            }
        }
        .background(Palette.background(scheme))
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 24) }
        }
        .task {
            if model.records.isEmpty && !model.isScanning { model.startScan() }
        }
    }

    private func sectionTitle(_ kind: ExtensionRecord.Kind) -> String {
        switch kind {
        case .system: return L("System extensions")
        case .safari: return L("Safari extensions")
        case .chromium: return L("Browser add-ons")
        case .firefox: return L("Browser add-ons")
        }
    }

    private func sectionSubtitle(_ kind: ExtensionRecord.Kind) -> String {
        switch kind {
        case .system: return L("macOS manages this extension. Fettle opens the matching settings pane.")
        case .safari: return L("System-managed")
        case .chromium: return L("This browser add-on is managed by its browser. Fettle opens the browser's extension page.")
        case .firefox: return L("This browser add-on is managed by its browser. Fettle opens the browser's extension page.")
        }
    }
}

struct ExtensionRow: View {
    var record: ExtensionRecord
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if let enabled = record.enabled {
                        Pill(text: enabled ? L("Enabled") : L("Disabled"), tint: enabled ? Palette.green : .secondary)
                    } else {
                        Pill(text: L("Unknown"), tint: .secondary)
                    }
                    if record.kind == .system { Pill(text: L("System-managed"), tint: Palette.violet) }
                }
                Text("\(record.host) · \(record.provider) · \(record.version.isEmpty ? "—" : record.version)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                if let note = record.note, !note.isEmpty {
                    Text(note).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button(record.kind == .system ? L("Open Login Items & Extensions") : (record.kind == .safari ? L("Open Safari") : L("Review in Browser")), action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? Palette.accent.opacity(0.25) : Palette.stroke(scheme), lineWidth: 1))
        )
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch record.kind {
        case .system: return "puzzlepiece"
        case .safari: return "safari"
        case .chromium: return "globe"
        case .firefox: return "flame"
        }
    }

    private var tint: Color {
        switch record.kind {
        case .system: return Palette.violet
        case .safari: return Palette.blue
        case .chromium: return Palette.accent
        case .firefox: return Palette.amber
        }
    }
}
