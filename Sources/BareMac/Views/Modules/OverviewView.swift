import BareMacCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !model.hasFullDiskAccess {
                    PermissionBanner()
                }
                DiskCard(disk: model.disk)
                HStack(alignment: .top, spacing: 18) {
                    ReclaimableCard()
                    TrashCard()
                        .frame(maxWidth: 320)
                }
                ModuleGrid()
                SafetyStrip()
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background {
            Backdrop(tint: .blue)
                .ignoresSafeArea()
                .extendsUnderSidebar()
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.scan(.overview) } label: { Label("Measure Again", systemImage: "arrow.clockwise") }
                    .help("Measure the disk and rescan (⌘R)")
                    .disabled(model.isScanning(.overview))
            }
        }
    }
}

/// Total, used and free space, straight from the volume.
private struct DiskCard: View {
    let disk: DiskSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(disk?.volumeName ?? "Startup Disk")
                        .font(.system(size: 26, weight: .semibold))
                    if let name = Workspace.computerName {
                        Text(name).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let disk {
                    VStack(alignment: .trailing, spacing: 2) {
                        HeadlineNumber(headline: Headline(bytes: disk.availableBytes, caption: "free"))
                        Text("free of \(Format.bytes(disk.totalBytes))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let disk {
                CapacityBar(disk: disk)
                HStack(spacing: 18) {
                    Legend(color: .accentColor, title: "Used", value: disk.usedBytes)
                    if disk.purgeableBytes > 0 {
                        Legend(color: .accentColor.opacity(0.35), title: "Purgeable", value: disk.purgeableBytes)
                    }
                    Legend(color: Color.secondary.opacity(0.25), title: "Free", value: disk.availableBytes)
                    Spacer()
                }
                if disk.purgeableBytes > 0 {
                    Text("macOS can free \(Format.bytes(disk.purgeableBytes)) of purgeable space on its own when it needs room, such as local snapshots and files it can download again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("BareMac couldn't read the startup disk's size.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .glass(.rounded(26))
        .accessibilityElement(children: .combine)
    }
}

private struct CapacityBar: View {
    let disk: DiskSnapshot

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = max(Double(disk.totalBytes), 1)
            let used = width * Double(disk.usedBytes - min(disk.purgeableBytes, disk.usedBytes)) / total
            let purgeable = width * Double(min(disk.purgeableBytes, disk.usedBytes)) / total
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor.gradient).frame(width: max(0, used))
                Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: max(0, purgeable))
                Rectangle().fill(Color.secondary.opacity(0.18))
            }
            .clipShape(Capsule())
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(Int((disk.usedFraction * 100).rounded())) percent used")
    }
}

private struct Legend: View {
    let color: Color
    let title: String
    let value: Int64

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
            Text(Format.bytes(value)).monospacedDigit()
        }
        .font(.callout)
    }
}

/// What BareMac suggests moving, measured, with a way into each module.
private struct ReclaimableCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggested to move to the Trash")
                .font(.headline)
            if model.junk.result == nil && model.leftovers.result == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.isScanning(.overview) ? "Measuring caches, logs and leftovers…" : "Not measured yet")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 48)
            } else {
                HeadlineNumber(headline: Headline(bytes: model.suggestedBytes, caption: "suggested"))
            }
            VStack(spacing: 6) {
                ModuleLine(module: .systemJunk, value: model.junk.result?.suggestedBytes, scanning: model.junk.task.isRunning)
                ModuleLine(module: .leftovers, value: model.leftovers.result?.suggestedBytes, scanning: model.leftovers.task.isRunning || (model.inventory.isRunning && model.leftovers.result == nil))
            }
            Text("Every number here was measured on your Mac just now. Nothing moves until you review the list and confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(.rounded(26))
    }
}

private struct ModuleLine: View {
    @Environment(AppModel.self) private var model
    let module: Module
    let value: Int64?
    let scanning: Bool

    var body: some View {
        Button {
            model.selection = module
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .foregroundStyle(module.tint)
                    .frame(width: 22)
                Text(module.title)
                Spacer()
                if scanning && value == nil {
                    ProgressView().controlSize(.mini)
                } else if let value {
                    Text(Format.bytes(value)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("\(module.title), \(value.map(Format.spokenBytes) ?? "not measured")")
        .accessibilityHint("Opens \(module.title)")
    }
}

private struct TrashCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Trash", systemImage: "trash").font(.headline)
            if let result = model.trash.result {
                if result.isReadable {
                    HeadlineNumber(headline: Headline(bytes: result.total.allocatedBytes, caption: "in the Trash"))
                    Text("This space comes back only when you empty the Trash in Finder. BareMac never empties it for you.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("macOS hides the Trash until BareMac has Full Disk Access.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if result.movedByBareMacBytes > 0 {
                        Text("BareMac put \(Format.bytes(result.movedByBareMacBytes)) there.")
                            .font(.callout).monospacedDigit()
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Button("Open Trash in Finder") { Workspace.openTrash(home: model.environment.home) }
                .secondaryButton()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glass(.rounded(26))
    }
}

private struct ModuleGrid: View {
    @Environment(AppModel.self) private var model
    private let modules: [Module] = [.uninstaller, .largeFiles, .duplicates, .startupItems, .spaceMap, .history]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
            ForEach(modules) { module in
                Button { model.selection = module } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: module.symbol)
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(module.tint.gradient)
                        Text(module.title).font(.headline)
                        Text(status(for: module))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glass(.rounded(22), interactive: true)
                .accessibilityHint("Opens \(module.title)")
            }
        }
    }

    private func status(for module: Module) -> String {
        if model.isScanning(module) { return "Scanning…" }
        switch module {
        case .largeFiles:
            if let result = model.largeFiles.result { return "\(Format.count(result.files.count, "large file")) · \(Format.bytes(result.totalBytes))" }
        case .duplicates:
            if let result = model.duplicates.result { return "\(Format.count(result.groups.count, "group")) · \(Format.bytes(result.reclaimableBytes)) in extra copies" }
        case .startupItems:
            if let result = model.startup.result {
                let count = result.userAgents.count + result.systemAgents.count + result.systemDaemons.count + result.loginHelpers.count
                return Format.count(count, "background item")
            }
        case .uninstaller:
            if let inventory = model.inventory.value { return "\(Format.count(inventory.apps.filter { !$0.isApple && !$0.isInSystemFolder }.count, "app")) you can remove" }
        case .history:
            let batches = model.history.batches.count
            return batches == 0 ? "Nothing moved yet" : Format.count(batches, "action")
        default:
            break
        }
        return module.tagline
    }
}

private struct SafetyStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            Pill(symbol: "arrow.uturn.backward", title: "Trash only", detail: "Never deletes, never empties the Trash")
            Pill(symbol: "wifi.slash", title: "Zero network", detail: "No analytics, no update checks")
            Pill(symbol: "chevron.left.forwardslash.chevron.right", title: "Open source", detail: "Read every line")
            Spacer(minLength: 0)
            Button("How BareMac stays safe") { Workspace.open(Links.safety) }
                .buttonStyle(.link)
        }
    }

    private struct Pill: View {
        let symbol: String
        let title: String
        let detail: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(.capsule)
            .accessibilityElement(children: .combine)
        }
    }
}
