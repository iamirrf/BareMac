import BareMacCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.history
        let batches = store.batches
        ModuleScaffold(
            module: .history,
            state: batches.isEmpty ? .empty : .content,
            headline: Headline(bytes: nil, text: "\(batches.count)", caption: "actions, written to a plain-text log you can read. Put anything back with one click."),
            copy: ModuleCopy(
                readyTitle: "",
                readyMessage: "",
                emptyTitle: "Nothing moved yet",
                emptyMessage: "When BareMac moves something to the Trash or turns a background item off, it shows up here with a way to undo it.",
                emptySymbol: "clock.arrow.circlepath",
                accents: ["arrow.uturn.backward", "doc.text"]
            )
        ) {
            Button("Show Log in Finder") { Workspace.reveal(model.log.fileURL) }
                .secondaryButton()
                .disabled(!FileManager.default.fileExists(atPath: model.log.fileURL.path))
        } content: {
            List {
                ForEach(batches) { batch in
                    Section {
                        ForEach(batch.records) { record in
                            HistoryRow(record: record, status: store.status(of: record))
                        }
                    } header: {
                        HStack {
                            SectionTitle(
                                title: title(batch),
                                subtitle: "\(Format.dateTime(batch.date)) · \(Format.count(batch.records.count, "item"))",
                                bytes: batch.kind == .trashed ? batch.bytes : nil
                            )
                            let restorable = store.restorable(in: batch)
                            if batch.kind == .trashed, restorable.count > 1 {
                                Button("Put All Back") { model.restore(restorable) }
                                    .secondaryButton()
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .onAppear { model.history.reload(log: model.log) }
    }

    private func title(_ batch: HistoryStore.Batch) -> String {
        switch batch.kind {
        case .trashed: "\(batch.origin): moved \(Format.bytes(batch.bytes)) to the Trash"
        case .startupItemTurnedOff: "Turned off a background item"
        case .startupItemTurnedOn: "Turned on a background item"
        case .restored: "Put back"
        }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: ActionRecord
    let status: HistoryStore.RecordStatus

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(url: URL(filePath: status == .inTrash ? (record.trashedPath ?? record.originalPath) : record.originalPath), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.label).lineLimit(1)
                Text(Format.path(record.originalPath, home: model.environment.home))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.originalPath)
            }
            Spacer()
            if record.kind == .trashed { SizeLabel(bytes: record.bytes) }
            switch status {
            case .inTrash:
                Button("Put Back") { model.restore([record]) }
                    .secondaryButton()
                    .accessibilityLabel("Put back \(record.label)")
            case .restored:
                Tag(text: "Put back", symbol: "checkmark", tint: .green)
            case .gone:
                Tag(text: "No longer in the Trash", tint: .secondary)
                    .help("The Trash was emptied, so this can't come back.")
            case .startupChange:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Form {
                Section("Large & Old Files") {
                    Picker("Show files bigger than", selection: Binding(get: { model.largeFiles.minimumMB }, set: { model.largeFiles.minimumMB = $0 })) {
                        ForEach(LargeFilesStore.thresholds, id: \.self) { Text(Format.bytes(Int64($0) * 1_000_000)).tag($0) }
                    }
                }
                Section("Duplicates") {
                    Picker("Compare files bigger than", selection: Binding(get: { model.duplicates.minimumKB }, set: { model.duplicates.minimumKB = $0 })) {
                        ForEach(DuplicatesStore.thresholds, id: \.self) { Text(Format.bytes(Int64($0) * 1_000)).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Full Disk Access") {
                    LabeledContent("Status", value: model.hasFullDiskAccess ? "Allowed" : "Not allowed")
                    Text("With Full Disk Access, BareMac can measure your Trash, device backups and App Store app caches. It only reads names and sizes.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Privacy & Security Settings") { Workspace.openFullDiskAccessSettings() }
                }
                Section("Network") {
                    Label("BareMac never connects to the internet. No analytics, no update checks, no license checks.", systemImage: "wifi.slash")
                }
                Section("Action log") {
                    LabeledContent("Location", value: Format.path(model.log.fileURL, home: model.environment.home))
                    Button("Show in Finder") { Workspace.reveal(model.log.fileURL) }
                        .disabled(!FileManager.default.fileExists(atPath: model.log.fileURL.path))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 400)
    }
}
