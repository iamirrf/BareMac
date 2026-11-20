import BareMacCore
import QuickLook
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\LargeFileRow.bytes, order: .reverse)]
    @State private var highlighted = Set<String>()
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var store = model.largeFiles
        let rows = store.visibleFiles.map(LargeFileRow.init).sorted(using: sortOrder)
        let state = store.task.moduleState { $0.files.isEmpty }
        ModuleScaffold(
            module: .largeFiles,
            state: state,
            headline: store.result.map { _ in Headline(bytes: rows.reduce(0) { $0 + $1.bytes }, caption: caption(rows.count)) },
            copy: ModuleCopy(
                readyTitle: "Find your biggest files",
                readyMessage: "BareMac looks through your home folder, but not your Library or hidden folders. macOS may ask before BareMac looks in Desktop, Documents or Downloads. BareMac only reads names, sizes and dates.",
                emptyTitle: "No files over \(Format.bytes(Int64(store.minimumMB) * 1_000_000))",
                emptyMessage: "Try a smaller size in the menu above.",
                accents: ["film", "doc.zipper", "opticaldisc"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            filters(store: store)
        } content: {
            Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
                TableColumn("") { (row: LargeFileRow) in
                    LargeFileCheckbox(row: row, store: store)
                }
                .width(24)
                TableColumn("Name", value: \LargeFileRow.name) { (row: LargeFileRow) in
                    LargeFileNameCell(row: row)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Size", value: \LargeFileRow.bytes) { (row: LargeFileRow) in
                    SizeLabel(bytes: row.bytes)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Last Opened", value: \LargeFileRow.lastOpenedSort) { (row: LargeFileRow) in
                    LastOpenedCell(date: row.file.lastOpened)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Kind", value: \LargeFileRow.kindTitle) { (row: LargeFileRow) in
                    Text(row.kindTitle).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Folder", value: \LargeFileRow.folder) { (row: LargeFileRow) in
                    FolderCell(path: row.folder, home: model.environment.home)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Quick Look") { previewURL = row.file.item.url }
                    ItemMenu(url: row.file.item.url)
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) { Workspace.reveal(row.file.item.url) }
            }
            .onKeyPress(.space) {
                let chosen = rows.filter { highlighted.contains($0.id) }
                guard !chosen.isEmpty else { return .ignored }
                for row in chosen { store.toggle(row.file.item) }
                return .handled
            }
            .quickLookPreview($previewURL, in: rows.map(\.file.item.url))
            .safeAreaInset(edge: .top, spacing: 0) {
                if let result = store.result, !result.unreadableFolders.isEmpty || result.datalessSkipped > 0 {
                    footnote(result)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    previewURL = rows.first(where: { highlighted.contains($0.id) })?.file.item.url
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .keyboardShortcut("y")
                .disabled(highlighted.isEmpty)
                .help("Quick Look (⌘Y)")
            }
        }
    }

    private func caption(_ count: Int) -> String {
        "in \(Format.count(count, "file")) over \(Format.bytes(Int64(model.largeFiles.scannedMinimumMB ?? model.largeFiles.minimumMB) * 1_000_000)). Space (or the checkbox) includes a file; ⌘Y previews it."
    }

    @ViewBuilder
    private func filters(store: LargeFilesStore) -> some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Picker("Bigger than", selection: $store.minimumMB) {
                ForEach(LargeFilesStore.thresholds, id: \.self) { value in
                    Text(Format.bytes(Int64(value) * 1_000_000)).tag(value)
                }
            }
            .frame(width: 170)
            .onChange(of: store.minimumMB) { model.scan(.largeFiles) }
            Picker("Not opened in", selection: $store.notUsedMonths) {
                Text("Any time").tag(0)
                Text("3 months").tag(3)
                Text("6 months").tag(6)
                Text("1 year").tag(12)
                Text("2 years").tag(24)
            }
            .frame(width: 190)
            Picker("Kind", selection: $store.kind) {
                Text("All kinds").tag(FileKind?.none)
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(FileKind?.some(kind))
                }
            }
            .frame(width: 150)
        }
        .labelsHidden()
        .controlSize(.regular)
    }

    private func footnote(_ result: LargeFilesResult) -> some View {
        var parts: [String] = []
        if !result.unreadableFolders.isEmpty {
            parts.append("macOS didn't let BareMac look in \(result.unreadableFolders.map { ($0 as NSString).lastPathComponent }.prefix(3).joined(separator: ", ")).")
        }
        if result.datalessSkipped > 0 {
            parts.append("\(Format.count(result.datalessSkipped, "file")) stored only in iCloud were skipped, so nothing was downloaded.")
        }
        return Label(parts.joined(separator: " "), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

private struct LargeFileCheckbox: View {
    let row: LargeFileRow
    let store: LargeFilesStore

    var body: some View {
        Toggle(isOn: Binding(get: { store.isChecked(row.file.item) }, set: { _ in store.toggle(row.file.item) })) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Include \(row.name)")
    }
}

private struct LargeFileNameCell: View {
    let row: LargeFileRow

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(url: row.file.item.url, size: 20)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            if row.file.sharesStorage {
                Tag(text: "Shares storage", tint: .blue)
                    .help("This file is an APFS clone. Moving it frees only \(Format.bytes(row.file.reclaimableBytes)).")
            }
        }
    }
}

private struct LastOpenedCell: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(Format.relative(date)).foregroundStyle(.secondary).help(Format.dateTime(date))
        } else {
            Text("Not recorded").foregroundStyle(.tertiary).help("macOS hasn't recorded when this file was last opened.")
        }
    }
}

private struct FolderCell: View {
    let path: String
    let home: URL

    var body: some View {
        Text(Format.path(path, home: home))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

/// A sortable row for the Large & Old Files table.
struct LargeFileRow: Identifiable {
    let file: LargeFile
    var id: String { file.id }
    var name: String { file.item.name }
    var bytes: Int64 { file.item.bytes }
    var lastOpenedSort: Date { file.lastOpened ?? .distantPast }
    var kindTitle: String { file.kind.title }
    var folder: String { file.item.url.deletingLastPathComponent().path }

    init(_ file: LargeFile) {
        self.file = file
    }
}

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var store = model.duplicates
        let state = store.task.moduleState { $0.groups.isEmpty }
        ModuleScaffold(
            module: .duplicates,
            state: state,
            headline: store.result.map { Headline(bytes: $0.reclaimableBytes, caption: "in extra copies across \(Format.count($0.groups.count, "group")) of identical files. The newest copy of each always stays.") },
            copy: ModuleCopy(
                readyTitle: "Find files that are exactly the same",
                readyMessage: "BareMac compares sizes first, then the contents byte for byte with a secure hash, so only true copies are grouped. The newest copy is always kept.",
                emptyTitle: "No duplicates",
                emptyMessage: "No two files in your home folder have the same content.",
                accents: ["doc.on.doc", "equal.circle", "photo"]
            ),
            rescanProgress: store.task.isRunning && store.result != nil ? store.task.progress : nil
        ) {
            HStack(spacing: 8) {
                Picker("At least", selection: $store.minimumKB) {
                    ForEach(DuplicatesStore.thresholds, id: \.self) { value in
                        Text("Files over \(Format.bytes(Int64(value) * 1_000))").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: store.minimumKB) { model.scan(.duplicates) }
                Button("Select Suggested") { store.selectSuggested() }
                    .secondaryButton()
                    .disabled(store.result == nil)
                Button("Deselect All") { store.deselectAll() }
                    .secondaryButton()
                    .disabled(store.checked.isEmpty)
            }
        } content: {
            List {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(
                                file: file,
                                isKeeper: file.id == group.keeper.id,
                                isChecked: store.isChecked(file.item),
                                canCheck: store.canCheck(file, in: group),
                                onToggle: { store.toggle(file, in: group) },
                                onPreview: { previewURL = file.item.url }
                            )
                        }
                    } header: {
                        HStack(spacing: 10) {
                            ItemIcon(url: group.keeper.item.url, size: 26)
                            SectionTitle(
                                title: group.keeper.item.name,
                                subtitle: "\(Format.count(group.files.count, "copy", "copies")) · \(Format.bytes(group.fileSize)) each",
                                bytes: group.files.filter { store.isChecked($0.item) }.reduce(0) { $0 + $1.item.bytes }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .quickLookPreview($previewURL)
        }
    }
}

private struct DuplicateRow: View {
    @Environment(AppModel.self) private var model
    let file: DuplicateFile
    let isKeeper: Bool
    let isChecked: Bool
    let canCheck: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { isChecked }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canCheck && !isChecked)
                .help(canCheck || isChecked ? "Include this copy" : "At least one copy always stays.")
                .accessibilityLabel("Include this copy")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Format.path(file.item.url.deletingLastPathComponent(), home: model.environment.home))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isKeeper { Tag(text: "Newest · keep", symbol: "star.fill", tint: .green) }
                    if file.sharesStorage { Tag(text: "Shares storage", tint: .blue) }
                }
                Text("Changed \(Format.dateTime(file.modified))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = file.item.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onPreview) { Image(systemName: "eye") }
                .buttonStyle(.borderless)
                .help("Quick Look")
                .accessibilityLabel("Quick Look")
            SizeLabel(bytes: file.reclaimableBytes)
                .help("Moving this copy frees \(ByteText.exact(file.reclaimableBytes)).")
        }
        .padding(.vertical, 3)
        .contextMenu { ItemMenu(url: file.item.url) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.item.name) in \(file.item.url.deletingLastPathComponent().lastPathComponent), \(Format.spokenBytes(file.reclaimableBytes))\(isKeeper ? ", newest copy, kept" : "")\(isChecked ? ", included" : "")")
        .accessibilityAction(named: isChecked ? "Don't include" : "Include") { onToggle() }
    }
}
