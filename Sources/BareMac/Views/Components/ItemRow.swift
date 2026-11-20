import AppKit
import BareMacCore
import SwiftUI

/// Finder icons, cached so long lists scroll smoothly.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

/// The icon for an item: its app's icon when BareMac knows the app, else Finder's icon for the file.
struct ItemIcon: View {
    let url: URL
    var owner: AppRef?
    var size: CGFloat = 28
    var dashed = false

    var body: some View {
        Image(nsImage: IconCache.shared.icon(forPath: iconPath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(dashed ? 0.55 : 1)
            .overlay(alignment: .bottomTrailing) {
                if dashed {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.background).padding(-1))
                }
            }
            .accessibilityHidden(true)
    }

    private var iconPath: String {
        if let appURL = owner?.url, FileManager.default.fileExists(atPath: appURL.path) { return appURL.path }
        return url.path
    }
}

/// Right-aligned, monospaced size with the exact byte count on hover.
struct SizeLabel: View {
    let bytes: Int64
    var isComplete = true
    var emphasized = false

    var body: some View {
        Text((isComplete ? "" : "≥ ") + Format.bytes(bytes))
            .font(emphasized ? .body.weight(.semibold) : .body)
            .monospacedDigit()
            .foregroundStyle(emphasized ? .primary : .secondary)
            .help(ByteText.exact(bytes) + (isComplete ? "" : " counted; some files couldn't be read"))
    }
}

/// One found item: checkbox, icon, name, plain explanation, path and measured size.
/// Information-only items show why they can't be selected.
struct ItemRow: View {
    @Environment(AppModel.self) private var model

    let item: FoundItem
    let isChecked: Bool
    var canCheck: Bool = true
    var badges: [Tag] = []
    var showOwnerIcon = true
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(get: { isChecked }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isCleanable || (!canCheck && !isChecked))
                .accessibilityLabel("Include \(item.name)")
                .opacity(item.isCleanable ? 1 : 0.35)

            ItemIcon(url: item.url, owner: showOwnerIcon ? item.owner : nil, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    ForEach(Array(badges.enumerated()), id: \.offset) { $0.element }
                    if !item.isCleanable {
                        Tag(text: "Info only", symbol: "info.circle")
                    }
                }
                Text(item.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let note = item.note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                if let reason = item.infoReason {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(Format.path(item.url, home: model.environment.home))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }
            Spacer(minLength: 12)
            SizeLabel(bytes: item.bytes, isComplete: item.measurement.isComplete)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Workspace.reveal(item.url) }
        .contextMenu { ItemMenu(url: item.url) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .accessibilityAction(named: isChecked ? "Don't include" : "Include") { onToggle() }
        .accessibilityAction(named: "Show in Finder") { Workspace.reveal(item.url) }
    }

    private var accessibilityText: String {
        var parts = [item.name, Format.spokenBytes(item.bytes), item.explanation]
        if !item.isCleanable { parts.append("Information only. " + (item.infoReason ?? "")) }
        if let note = item.note { parts.append(note) }
        parts.append(isChecked ? "Included" : "Not included")
        return parts.joined(separator: ", ")
    }
}

/// Reveal, copy path and Quick Look for any file BareMac shows.
struct ItemMenu: View {
    let url: URL

    var body: some View {
        Button("Show in Finder") { Workspace.reveal(url) }
        Button("Copy Path") { Workspace.copyPath(url) }
    }
}

/// A section title with a tri-state checkbox that includes or excludes everything in it.
struct SectionTitle: View {
    let title: String
    let subtitle: String?
    let bytes: Int64?
    /// `true` all, `false` none, `nil` some; hidden when there is nothing to select.
    var state: Bool??
    var onSetAll: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let state, let onSetAll {
                Toggle(isOn: Binding(get: { state ?? false }, set: { onSetAll($0) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .modifier(MixedState(isMixed: state == nil))
                    .accessibilityLabel("Include everything in \(title)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let bytes {
                SizeLabel(bytes: bytes, emphasized: true)
            }
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }
}

/// Shows a checkbox's "mixed" dash when only some items are included.
private struct MixedState: ViewModifier {
    let isMixed: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isMixed {
                RoundedRectangle(cornerRadius: 1).frame(width: 8, height: 2).foregroundStyle(.tint).allowsHitTesting(false)
            }
        }
    }
}
