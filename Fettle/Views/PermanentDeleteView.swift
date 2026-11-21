import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PermanentDeleteView: View {
    @ObservedObject var model: PermanentDeleteModel
    @Environment(\.colorScheme) private var scheme
    @State private var isTargeted = false
    @State private var detailItem: ScanItem?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                module: .permanentDelete,
                title: L("Permanent Delete"),
                message: L("Drop files or folders here to review their exact paths and sizes. This action bypasses the Trash and cannot be undone.")
            ) {
                Button {
                    chooseFiles()
                } label: {
                    Label(L("Choose Files or Folders…"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.coral)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BannerView(
                        icon: "exclamationmark.octagon.fill",
                        title: L("Permanent deletion is not secure erasure"),
                        message: L("On SSDs, APFS snapshots, Time Machine backups and cloud copies can retain data even after a file is removed. Fettle cannot guarantee physical erasure."),
                        tint: Palette.coral
                    )
                    dropZone
                    if !model.items.isEmpty {
                        itemsList
                    }
                    if !model.refusals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("This location is protected")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.coral)
                            ForEach(Array(model.refusals.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.coral.opacity(0.06)))
                    }
                    HStack(spacing: 16) {
                        Label(L("This is separate from Disk Cleanup and the Uninstaller."), systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Label(L("Symlinks are removed as links. Their targets are never followed."), systemImage: "link")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Palette.background(scheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "xmark.bin.fill").foregroundStyle(Palette.coral)
                    Text(model.items.isEmpty ? L("No files were chosen.") : L("%d items selected · %@", model.items.count, Fmt.bytes(model.totalBytes)))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                Spacer()
                if model.isCalculating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Calculating…")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Button(L("Clear")) { model.clear() }
                    .buttonStyle(.borderless)
                    .disabled(model.items.isEmpty)
                Button {
                    model.requestDelete()
                } label: {
                    Label(L("Delete Permanently"), systemImage: "xmark.bin.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.coral)
                .controlSize(.large)
                .disabled(model.items.isEmpty || model.isCalculating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmationSheet(request: request) { model.performConfirmed(request) } onCancel: { model.confirmation = nil }
        }
        .sheet(item: $model.outcome) { outcome in OutcomeSheet(outcome: outcome) }
        .sheet(item: $detailItem) { item in ItemDetailView(item: item) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast).padding(.bottom, 70) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.coral.opacity(0.10)).frame(width: 72, height: 72)
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "xmark.bin")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.coral)
            }
            Text(isTargeted ? L("Drop files or folders") : L("Drop files or folders here to review their exact paths and sizes."))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(L("A separate, deliberate erase.")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L("Choose Files…")) { chooseFiles() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.coral.opacity(isTargeted ? 0.07 : 0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [7, 5]))
                        .foregroundStyle(Palette.coral.opacity(isTargeted ? 0.6 : 0.28))
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var itemsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Review before erasing")).font(.system(size: 12, weight: .semibold))
                Text("\(model.items.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(L("Exact path")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            .padding(.bottom, 6)
            ForEach(model.items) { item in
                HStack(spacing: 10) {
                    IconTile(symbol: item.fingerprint.isDirectory ? "folder.fill" : "doc.fill", tint: Palette.coral, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(item.path).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if item.fingerprint.isDirectory {
                            Text(L("Folders are removed with their contents.")).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(Fmt.bytes(item.size)).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    Button { detailItem = item } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button {
                        model.remove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Remove from list"))
                }
                .padding(.vertical, 6)
                Divider().opacity(0.35)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add Files…")
        panel.message = L("Files stay on this Mac until you confirm.")
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let string = item as? String {
                    url = URL(string: string)
                }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            model.add(urls: urls)
        }
    }
}
