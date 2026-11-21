import SwiftUI
import AppKit

enum Palette {
    static let accent = Color(red: 0.05, green: 0.63, blue: 0.60)
    static let accentBright = Color(red: 0.20, green: 0.82, blue: 0.75)
    static let deep = Color(red: 0.03, green: 0.16, blue: 0.20)
    static let deepest = Color(red: 0.02, green: 0.10, blue: 0.14)
    static let coral = Color(red: 0.94, green: 0.44, blue: 0.36)
    static let amber = Color(red: 0.95, green: 0.68, blue: 0.26)
    static let violet = Color(red: 0.50, green: 0.45, blue: 0.85)
    static let blue = Color(red: 0.27, green: 0.56, blue: 0.92)
    static let green = Color(red: 0.28, green: 0.70, blue: 0.45)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [accentBright, accent, Color(red: 0.03, green: 0.38, blue: 0.46)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var sidebarGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.04, green: 0.22, blue: 0.26), deepest], startPoint: .top, endPoint: .bottom)
    }

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.055, green: 0.075, blue: 0.085) : Color(red: 0.945, green: 0.965, blue: 0.96)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.86)
    }

    static func cardStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.white
    }

    static func stroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }

    static func tint(for category: ItemCategory) -> Color {
        switch category {
        case .cache, .appCache, .browserCache: return blue
        case .logs, .appLogs: return Color(red: 0.49, green: 0.55, blue: 0.62)
        case .crashReports: return coral
        case .temporary: return amber
        case .trash: return Color(red: 0.58, green: 0.47, blue: 0.40)
        case .largeFile: return violet
        case .brokenAlias: return amber
        case .invalidLaunchAgent: return coral
        case .brokenPreference: return amber
        case .leftover: return violet
        case .app: return accent
        case .appPreferences: return blue
        case .appSupport: return Color(red: 0.40, green: 0.64, blue: 0.38)
        case .appData: return coral
        case .appLaunchAgent: return amber
        case .sharedContainer: return Color(red: 0.55, green: 0.55, blue: 0.55)
        case .cookies: return amber
        case .browsingHistory: return blue
        case .downloadHistory: return green
        case .websiteData: return violet
        case .recentItems: return Color(red: 0.55, green: 0.55, blue: 0.62)
        case .systemExtension, .browserExtension: return violet
        case .loginItem: return accent
        }
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 20
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Palette.stroke(scheme), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.18 : 0.045), radius: 12, y: 4)
            )
    }
}

extension View {
    func card(padding: CGFloat = 20, radius: CGFloat = 18) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }
}

struct BrandMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Palette.brandGradient)
            WaveShape()
                .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .padding(size * 0.20)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.accent.opacity(0.35), radius: size * 0.18, y: size * 0.06)
    }
}

struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.06))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.midY - rect.height * 0.22),
            control2: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.midY + rect.height * 0.22)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.06),
            control1: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.midY - rect.height * 0.22),
            control2: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.midY + rect.height * 0.18)
        )
        return path
    }
}

struct IconTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct Pill: View {
    var text: String
    var icon: String?
    var tint: Color = Palette.accent
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModuleHeader<Actions: View>: View {
    var module: ModuleID
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: module.symbol, tint: Palette.accent, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(0)
            HStack(spacing: 8) { actions }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}

struct ScanProgressBar: View {
    var progress: Double
    var phase: String
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(phase.isEmpty ? L("Scanning…") : phase)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.percent(progress))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("Cancel"), action: onCancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Palette.brandGradient)
                        .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
                }
            }
            .frame(height: 5)
        }
        .card(padding: 14, radius: 13)
    }
}

struct BannerView: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = Palette.accent
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.075)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1))
    }
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.10)).frame(width: 76, height: 76)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Palette.accent)
            }
            Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct MetricTile: View {
    var icon: String
    var label: String
    var value: String
    var caption: String?
    var tint: Color = Palette.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.3).lineLimit(1).minimumScaleFactor(0.62)
            }
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            if let caption {
                Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, radius: 14)
    }
}

struct CheckCircle: View {
    var selected: Bool
    var enabled: Bool = true
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Palette.accent : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(selected ? Palette.accent : Color.primary.opacity(enabled ? 0.24 : 0.10), lineWidth: 1.4)
                )
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct ScanItemRow: View {
    var item: ScanItem
    var selected: Bool
    var selectable: Bool
    var showLocation: Bool = false
    var onToggle: () -> Void
    var onReveal: () -> Void
    var onInfo: () -> Void
    var onIgnore: (() -> Void)?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onToggle) {
                CheckCircle(selected: selected, enabled: selectable)
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .help(selectable ? L("Select") : L("Information only"))

            if item.category == .app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable().frame(width: 30, height: 30)
            } else {
                IconTile(symbol: item.category.symbol, tint: Palette.tint(for: item.category), size: 30)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isAppData { Pill(text: L("App data"), tint: Palette.coral) }
                    if item.isRunningApp { Pill(text: L("Running"), tint: Palette.amber) }
                    if item.isProtected && !item.isRunningApp { Pill(text: L("Protected"), tint: Palette.coral) }
                    if item.isInformational { Pill(text: L("Information only"), icon: "info.circle", tint: .secondary) }
                    if item.isExternal { Pill(text: L("External drive"), icon: "externaldrive", tint: Palette.blue) }
                }
                HStack(spacing: 5) {
                    if showLocation, !item.location.isEmpty {
                        Text(item.location).foregroundStyle(.tertiary).lineLimit(1)
                        Text("·").foregroundStyle(.quaternary)
                    }
                    Text(item.displayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(item.size))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            HStack(spacing: 2) {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .help(L("Reveal in Finder"))
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help(L("Show Details"))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if item.canReveal { Button(L("Reveal in Finder"), action: onReveal) }
            Button(L("Copy Path")) { FileSafety.copyPath(item.path) }
            Button(L("Show Details"), action: onInfo)
            if let onIgnore, !item.isInformational {
                Divider()
                Button(L("Add to Ignore List"), action: onIgnore)
            }
        }
    }
}

struct ItemDetailView: View {
    var item: ScanItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: item.category.symbol, tint: Palette.tint(for: item.category), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(item.category.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.bytes(item.size)).font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            Divider()
            detailRow(L("Exact path"), item.path)
            if !item.location.isEmpty { detailRow(L("Location"), item.location) }
            if let detail = item.detail { detailRow(L("Details"), detail) }
            if let bundleID = item.bundleID { detailRow("Bundle ID", bundleID) }
            if !item.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Evidence")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Palette.accent).frame(width: 4, height: 4).padding(.top, 6)
                            Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if item.isRunningApp {
                BannerView(icon: "exclamationmark.triangle.fill", title: L("Running"), message: L("This app is running. Quit it before removing its files, or the removal will be skipped."), tint: Palette.amber)
            }
            Spacer(minLength: 0)
            HStack {
                Button(L("Copy Path")) { FileSafety.copyPath(item.path) }
                Spacer()
                Button(L("Reveal in Finder")) { FileSafety.revealInFinder(item.url) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                Button(L("Close")) { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 560, height: 420)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SkippedList: View {
    var skipped: [SkippedItem]
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(L("What Fettle skipped")).font(.system(size: 12, weight: .semibold))
                    Text("\(skipped.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(skipped.prefix(60)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "minus.circle").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.path).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(entry.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                    if skipped.count > 60 {
                        Text("+ \(skipped.count - 60)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.stroke(scheme), lineWidth: 1))
    }
}

struct SelectionBar: View {
    var count: Int
    var bytes: Int64
    var primaryTitle: String
    var primaryIcon: String = "trash"
    var isDestructive: Bool = false
    var isEnabled: Bool
    var onPrimary: () -> Void
    var onClear: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                Text(count == 0 ? L("Nothing selected") : L("%d items selected · %@", count, Fmt.bytes(bytes)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            if count > 0 {
                Button(L("Clear"), action: onClear).buttonStyle(.borderless).controlSize(.small)
            }
            Spacer()
            Button(action: onPrimary) {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(isDestructive ? Palette.coral : Palette.accent)
            .controlSize(.large)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Palette.background(scheme))
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ConfirmationSheet: View {
    var request: ConfirmationRequest
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @State private var typed = ""
    @State private var showItems = false
    @Environment(\.colorScheme) private var scheme

    private var canConfirm: Bool {
        guard let required = request.requiresTyping else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == required.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill((request.isPermanent ? Palette.coral : Palette.accent).opacity(0.14)).frame(width: 44, height: 44)
                    Image(systemName: request.isPermanent ? "exclamationmark.triangle.fill" : "arrow.down.to.line")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(request.isPermanent ? Palette.coral : Palette.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.system(size: 19, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text(request.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                Label(L("%d items", request.itemCount), systemImage: "list.bullet")
                Label(Fmt.bytes(request.byteCount), systemImage: "externaldrive")
                Spacer()
                Button(showItems ? L("Hide item details") : L("Show item details")) {
                    withAnimation(.easeOut(duration: 0.18)) { showItems.toggle() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            if showItems {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(request.items.prefix(100)) { item in
                            HStack(spacing: 8) {
                                Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(item.displayPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.bytes(item.size)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.35)
                        }
                        if request.items.count > 100 {
                            Text("+ \(request.items.count - 100)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
                        }
                    }
                }
                .frame(maxHeight: 170)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            }

            if request.isPermanent {
                BannerView(
                    icon: "exclamationmark.octagon.fill",
                    title: L("This cannot be undone."),
                    message: L("On SSDs, APFS snapshots, Time Machine backups and cloud copies can retain data even after a file is removed. Fettle cannot guarantee physical erasure."),
                    tint: Palette.coral
                )
            }

            if let required = request.requiresTyping {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Type DELETE")).font(.system(size: 11, weight: .semibold))
                    TextField(required, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }

            Divider()
            HStack {
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onConfirm) {
                    Text(request.actionLabel)
                }
                .buttonStyle(.borderedProminent)
                .tint(request.isPermanent ? Palette.coral : Palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 590)
        .interactiveDismissDisabled(request.isPermanent)
    }
}

struct OutcomeSheet: View {
    var outcome: OperationOutcome
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill((outcome.failureCount > 0 ? Palette.amber : Palette.accent).opacity(0.14)).frame(width: 46, height: 46)
                    Image(systemName: outcome.failureCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(outcome.failureCount > 0 ? Palette.amber : Palette.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.title).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(outcome.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                MetricTile(icon: "checkmark.circle", label: L("Success"), value: "\(outcome.successCount)", tint: Palette.accent)
                MetricTile(icon: "arrow.uturn.left.circle", label: L("Skipped"), value: "\(outcome.skippedCount)", tint: Palette.amber)
                MetricTile(icon: "xmark.octagon", label: L("Failed"), value: "\(outcome.failureCount)", tint: Palette.coral)
                MetricTile(icon: "externaldrive", label: L("Size"), value: Fmt.bytes(outcome.touchedBytes), tint: Palette.blue)
            }

            if let before = outcome.freeSpaceBefore, let after = outcome.freeSpaceAfter {
                HStack {
                    Text(L("Actual free space")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.bytes(before)) → \(Fmt.bytes(after))").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            }

            if !outcome.results.isEmpty {
                DisclosureGroup(isExpanded: $showAll) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(showAll ? outcome.results : Array(outcome.results.prefix(12))) { result in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: result.success ? "checkmark.circle" : (result.skipped ? "minus.circle" : "xmark.circle"))
                                        .foregroundStyle(result.success ? Palette.green : (result.skipped ? Palette.amber : Palette.coral))
                                        .font(.system(size: 10))
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(result.path).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                        if let message = result.message {
                                            Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            if !showAll && outcome.results.count > 12 {
                                Button(L("Show item details")) { showAll = true }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                } label: {
                    Text(L("Item results") + " · \(outcome.results.count)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct DeleteTrashBar: View {
    var count: Int
    var bytes: Int64
    var action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill").foregroundStyle(Palette.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Trash is separate")).font(.system(size: 11.5, weight: .semibold))
                Text(L("Emptying the Trash is its own confirmed action and is never part of routine cleanup.")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("%d items · %@", count, Fmt.bytes(bytes))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            Button(L("Empty Trash…"), action: action)
                .buttonStyle(.bordered)
                .tint(Palette.coral)
                .disabled(count == 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.coral.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.coral.opacity(0.16), lineWidth: 1))
    }
}
