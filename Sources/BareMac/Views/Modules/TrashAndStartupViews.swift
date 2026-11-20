import BareMacCore
import SwiftUI

struct TrashView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.trash
        let state = store.task.moduleState { $0.isReadable && $0.items.isEmpty && $0.movedByBareMac.isEmpty }
        ModuleScaffold(
            module: .trash,
            state: state,
            headline: store.result.flatMap { result in
                result.isReadable
                    ? Headline(bytes: result.total.allocatedBytes, caption: "in your Trash. It's freed only when you empty the Trash in Finder — BareMac never empties it.")
                    : Headline(bytes: result.movedByBareMacBytes, caption: "that BareMac put in the Trash. Give it Full Disk Access to see everything else there.")
            },
            copy: ModuleCopy(
                readyTitle: "See what's in your Trash",
                readyMessage: "BareMac shows what the Trash holds and how much space it uses. It never empties it.",
                emptyTitle: "The Trash is empty",
                emptyMessage: "There's nothing in your Trash.",
                emptySymbol: "trash",
                accents: ["checkmark", "sparkle"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            Button("Open Trash in Finder") { Workspace.openTrash(home: model.environment.home) }
                .secondaryButton()
        } content: {
            if let result = store.result {
                List {
                    if !result.isReadable {
                        PermissionBanner(title: "macOS hides the Trash from apps", message: "To show what's in your Trash and its size, give BareMac Full Disk Access. BareMac still knows what it moved there itself.")
                            .listRowSeparator(.hidden)
                    }
                    if !result.movedByBareMac.isEmpty {
                        Section {
                            ForEach(result.movedByBareMac) { record in
                                HStack(spacing: 10) {
                                    ItemIcon(url: URL(filePath: record.trashedPath ?? record.originalPath), size: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(record.label).lineLimit(1)
                                        Text("From \(Format.path(record.originalPath, home: model.environment.home)) · \(Format.relative(record.date))")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    SizeLabel(bytes: record.bytes)
                                    Button("Put Back") { model.restore([record]) }
                                        .secondaryButton()
                                        .accessibilityLabel("Put back \(record.label)")
                                }
                                .accessibilityElement(children: .combine)
                            }
                        } header: {
                            SectionTitle(title: "Moved here by BareMac", subtitle: "Put any of these back where they were.", bytes: result.movedByBareMacBytes)
                        }
                    }
                    if result.isReadable && !result.items.isEmpty {
                        Section {
                            ForEach(result.items) { item in
                                HStack(spacing: 10) {
                                    ItemIcon(url: item.url, size: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).lineLimit(1)
                                        Text(Format.count(item.measurement.fileCount, "file")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    SizeLabel(bytes: item.bytes, isComplete: item.measurement.isComplete)
                                }
                                .contextMenu { ItemMenu(url: item.url) }
                                .accessibilityElement(children: .combine)
                            }
                        } header: {
                            SectionTitle(title: "Everything in the Trash", subtitle: "View only. Empty the Trash in Finder when you're ready.", bytes: result.total.allocatedBytes)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct StartupItemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.startup
        let state = store.task.moduleState { result in
            result.userAgents.isEmpty && result.systemAgents.isEmpty && result.systemDaemons.isEmpty && result.loginHelpers.isEmpty
        }
        ModuleScaffold(
            module: .startupItems,
            state: state,
            headline: store.result.map { result in
                let on = result.userAgents.filter { $0.isEnabled == true }.count
                return Headline(bytes: nil, text: "\(result.userAgents.count + result.systemAgents.count + result.systemDaemons.count + result.loginHelpers.count)", caption: "background items. \(on) of your own are turned on.")
            },
            copy: ModuleCopy(
                readyTitle: "See what starts when you log in",
                readyMessage: "BareMac lists background items in plain words. You can turn your own off and on again; items for all users are changed in System Settings.",
                emptyTitle: "No background items",
                emptyMessage: "Nothing is set up to start in the background.",
                emptySymbol: "power",
                accents: ["clock", "gearshape"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            Button("Login Items Settings…") { Workspace.openLoginItemsSettings() }
                .secondaryButton()
        } content: {
            if let result = store.result {
                List {
                    StartupSection(title: "Your background items", subtitle: "Started for you when you log in. Turning one off stops it now and at every login. You can turn it back on anytime.", items: result.userAgents)
                    StartupSection(title: "For all users", subtitle: "Installed for everyone on this Mac. Change these in System Settings › General › Login Items.", items: result.systemAgents + result.systemDaemons)
                    StartupSection(title: "Apps with login helpers", subtitle: "These apps include a helper that can open when you log in. macOS manages whether it does.", items: result.loginHelpers)
                    Section {
                        Label("Apps that open when you log in are listed in System Settings › General › Login Items.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog(
            "Turn off \(store.pendingTurnOff?.displayName ?? "this item")?",
            isPresented: Binding(get: { model.startup.pendingTurnOff != nil }, set: { if !$0 { model.startup.pendingTurnOff = nil } }),
            presenting: store.pendingTurnOff
        ) { item in
            Button("Turn Off") {
                model.startup.setEnabled(item, false, context: model.context) { model.history.reload(log: model.log) }
                model.startup.pendingTurnOff = nil
            }
            Button("Cancel", role: .cancel) { model.startup.pendingTurnOff = nil }
        } message: { item in
            Text("\(item.summary) It will stop now and won't start when you log in. Nothing is deleted, and you can turn it back on here.")
        }
        .alert("BareMac couldn't change that item", isPresented: Binding(get: { model.startup.errorMessage != nil }, set: { if !$0 { model.startup.errorMessage = nil } })) {
            Button("OK") { model.startup.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct StartupSection: View {
    let title: String
    let subtitle: String
    let items: [StartupItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in StartupRow(item: item) }
            } header: {
                SectionTitle(title: title, subtitle: subtitle, bytes: nil)
            }
        }
    }
}

private struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: StartupItem

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(url: item.owner?.url ?? item.plistURL ?? URL(filePath: "/System/Applications"), owner: item.owner, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if item.isLoaded == true { Tag(text: "Running", tint: .green) }
                    if !item.programExists { Tag(text: "Program missing", tint: .orange) }
                }
                Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(item.label).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if let note = item.managementNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.canToggle {
                Toggle(isOn: Binding(
                    get: { item.isEnabled ?? true },
                    set: { isOn in
                        if isOn {
                            model.startup.setEnabled(item, true, context: model.context) { model.history.reload(log: model.log) }
                        } else {
                            model.startup.pendingTurnOff = item
                        }
                    }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.startup.busy.contains(item.id))
                    .accessibilityLabel("\(item.displayName) starts at login")
            } else {
                Text(stateText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let plist = item.plistURL { ItemMenu(url: plist) }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        switch item.isEnabled {
        case .some(true): "On"
        case .some(false): "Off"
        case .none: "Managed by macOS"
        }
    }
}
