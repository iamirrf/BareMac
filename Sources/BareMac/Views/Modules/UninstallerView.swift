import BareMacCore
import SwiftUI

struct UninstallerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.uninstaller
        let apps = store.apps(model.context)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search apps", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                    .accessibilityLabel("Search installed apps")
                if model.inventory.value == nil {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Listing installed apps…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(apps, selection: appSelection(apps)) { app in
                        HStack(spacing: 10) {
                            ItemIcon(url: app.url, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.version.map { "Version \($0)" } ?? app.bundleIdentifier)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(app.id)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.inset)
                    .overlay {
                        if apps.isEmpty {
                            Text(store.search.isEmpty ? "No apps you can remove were found." : "No apps match “\(store.search)”.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 290)
            .background(.background.opacity(0.4))

            Divider()

            detail
        }
        .navigationTitle(Module.uninstaller.title)
    }

    private func appSelection(_ apps: [InstalledApp]) -> Binding<String?> {
        Binding(
            get: { model.uninstaller.selectedAppID },
            set: { id in
                if let id, let app = apps.first(where: { $0.id == id }) {
                    model.uninstaller.select(app, context: model.context)
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        let store = model.uninstaller
        let state: ModuleState = store.selectedAppID == nil ? .notScanned : store.footprint.moduleState { $0.allItems.isEmpty }
        ModuleScaffold(
            module: .uninstaller,
            state: state,
            headline: store.result.map { Headline(bytes: $0.bytes, caption: "used by \($0.app.name) and its files. \(Format.count($0.allItems.count, "item")) found.") },
            copy: ModuleCopy(
                readyTitle: "Pick an app to see everything it installed",
                readyMessage: "BareMac lists the app and every file it made, matched by its app ID. You see each one before anything moves.",
                emptyTitle: "Nothing found",
                emptyMessage: "BareMac couldn't find this app's files.",
                accents: ["app", "folder", "gearshape"]
            )
        ) {
            if let footprint = store.result {
                List {
                    if !footprint.notes.isEmpty || footprint.isRunning {
                        Section {
                            ForEach(footprint.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                            }
                            if footprint.isRunning {
                                HStack {
                                    Label("\(footprint.app.name) is open.", systemImage: "exclamationmark.circle")
                                    Spacer()
                                    Button("Quit \(footprint.app.name)") {
                                        Workspace.quit(bundleIdentifier: footprint.app.bundleIdentifier)
                                        Task {
                                            try? await Task.sleep(for: .seconds(1.5))
                                            await model.refreshRunningApps()
                                            model.uninstaller.rescan(model.context)
                                        }
                                    }
                                    .secondaryButton()
                                }
                            }
                        }
                    }
                    Section("The app") {
                        ItemRow(item: footprint.bundleItem, isChecked: store.isChecked(footprint.bundleItem)) {
                            store.toggle(footprint.bundleItem)
                        }
                        if footprint.bundleItem.infoReason?.contains("App Management") == true || footprint.bundleItem.infoReason?.contains("all users") == true {
                            Button("Open App Management Settings") { Workspace.openAppManagementSettings() }
                                .buttonStyle(.link)
                        }
                    }
                    if !footprint.relatedItems.isEmpty {
                        Section {
                            ForEach(footprint.relatedItems) { item in
                                ItemRow(item: item, isChecked: store.isChecked(item), badges: item.isSuggested ? [] : [Tag(text: "Check", symbol: "questionmark", tint: .orange)], showOwnerIcon: false) {
                                    store.toggle(item)
                                }
                            }
                        } header: {
                            SectionTitle(
                                title: "Files it made",
                                subtitle: "Matched by app ID are checked. Items matched only by name start unchecked.",
                                bytes: footprint.relatedItems.totalBytes,
                                state: .some(store.state(of: footprint.relatedItems)),
                                onSetAll: { store.set(footprint.relatedItems, to: $0) }
                            )
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}
