import BareMacCore
import SwiftUI

struct SystemJunkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.junk
        let state = store.task.moduleState { $0.allItems.isEmpty }
        ModuleScaffold(
            module: .systemJunk,
            state: state,
            headline: store.result.map { Headline(bytes: $0.cleanableBytes, caption: "of caches, logs and damaged settings can be moved to the Trash. BareMac suggests \(Format.bytes($0.suggestedBytes)).") },
            copy: ModuleCopy(
                readyTitle: "Find caches, logs and damaged settings",
                readyMessage: "BareMac looks only in your own Library folder. It measures every item and explains what it is before you decide.",
                emptyTitle: "Nothing to clean here",
                emptyMessage: "BareMac didn't find caches, logs or damaged settings worth moving.",
                accents: ["doc.text", "archivebox", "gearshape"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            if let result = store.result {
                List {
                    if !model.hasFullDiskAccess {
                        PermissionBanner(message: "macOS hides App Store app caches and device backups until you allow it. BareMac only reads names and sizes.")
                            .listRowSeparator(.hidden)
                    }
                    ForEach(result.sections.filter { !$0.items.isEmpty || $0.notice != nil }) { section in
                        Section {
                            if let notice = section.notice {
                                Label(notice, systemImage: "lock")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(section.items) { item in
                                ItemRow(item: item, isChecked: store.isChecked(item), badges: badges(item)) {
                                    store.toggle(item)
                                }
                            }
                        } header: {
                            SectionTitle(
                                title: section.title,
                                subtitle: section.explanation,
                                bytes: section.items.totalBytes,
                                state: section.items.contains(where: \.isCleanable) ? .some(store.state(of: section.items)) : .none,
                                onSetAll: { store.set(section.items, to: $0) }
                            )
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func badges(_ item: FoundItem) -> [Tag] {
        item.isSuggested ? [Tag(text: "Suggested", tint: .green)] : []
    }
}

struct LeftoversView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.leftovers
        let state: ModuleState = {
            if store.result == nil, model.inventory.isRunning { return .scanning(ScanProgress(phase: "Listing installed apps")) }
            return store.task.moduleState { $0.groups.isEmpty }
        }()
        ModuleScaffold(
            module: .leftovers,
            state: state,
            headline: store.result.map { Headline(bytes: $0.cleanableBytes, caption: "left behind by \(Format.count($0.groups.filter { !$0.isAmbiguous }.count, "app")) that are no longer installed.") },
            copy: ModuleCopy(
                readyTitle: "Find files from apps you removed",
                readyMessage: "BareMac matches Library files to apps by their app ID. If any installed app could still use a file, it is shown for information only.",
                emptyTitle: "No leftovers",
                emptyMessage: "Every app file BareMac found belongs to an app that is still installed.",
                accents: ["app.dashed", "puzzlepiece", "folder"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            if let result = store.result {
                List {
                    ForEach(result.notices, id: \.self) { notice in
                        Label(notice, systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(result.groups) { group in
                        Section {
                            if let note = group.note {
                                Label(note, systemImage: group.isAmbiguous ? "info.circle" : "trash")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.items) { item in
                                ItemRow(item: item, isChecked: store.isChecked(item), badges: item.isSuggested ? [Tag(text: "Suggested", tint: .green)] : [], showOwnerIcon: false) {
                                    store.toggle(item)
                                }
                            }
                        } header: {
                            HStack(spacing: 10) {
                                ItemIcon(url: group.app.url ?? URL(filePath: "/Applications"), owner: group.app, size: 26, dashed: group.app.url == nil)
                                SectionTitle(
                                    title: group.app.name,
                                    subtitle: subtitle(group),
                                    bytes: group.bytes,
                                    state: group.items.contains(where: \.isCleanable) ? .some(store.state(of: group.items)) : .none,
                                    onSetAll: { store.set(group.items, to: $0) }
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func subtitle(_ group: LeftoverGroup) -> String {
        let source: String = switch group.nameSource {
        case .appInTrash: "app in your Trash"
        case .knownApp: "known app"
        case .appID: "name from its app ID"
        }
        return "\(group.identifier) · \(source) · \(Format.count(group.items.count, "item"))"
    }
}
