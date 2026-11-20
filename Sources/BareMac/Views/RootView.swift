import AppKit
import BareMacCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 214, ideal: 236, max: 300)
        } detail: {
            ModuleView(module: model.selection)
        }
        .sheet(isPresented: sheetBinding) {
            ConfirmSheet().environment(model)
        }
        .alert("BareMac couldn't do that", isPresented: errorBinding) {
            Button("OK") { model.clean.errorMessage = nil }
        } message: {
            Text(model.clean.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.didBecomeActive()
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { model.clean.isPresentingSheet },
            set: { isPresented in
                if !isPresented, model.clean.stage == .confirming { model.clean.cancel(engine: model.engine) }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.clean.errorMessage != nil }, set: { if !$0 { model.clean.errorMessage = nil } })
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(Module.Section.allCases) { section in
                let modules = Module.allCases.filter { $0.section == section }
                if let title = section.title {
                    Section(title) { rows(modules) }
                } else {
                    Section { rows(modules) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SafetyFooter()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }

    private var selection: Binding<Module?> {
        Binding(get: { model.selection }, set: { if let module = $0 { model.selection = module } })
    }

    @ViewBuilder
    private func rows(_ modules: [Module]) -> some View {
        ForEach(modules) { module in
            Label {
                Text(module.title)
            } icon: {
                Image(systemName: module.symbol)
            }
            .badge(badge(for: module))
            .tag(module)
            .accessibilityLabel(accessibility(for: module))
        }
    }

    private func badge(for module: Module) -> Text? {
        if model.isScanning(module), module != .overview { return Text("…") }
        return model.badge(for: module).map { Text($0).monospacedDigit() }
    }

    private func accessibility(for module: Module) -> String {
        if let badge = model.badge(for: module) { return "\(module.title), \(badge)" }
        return module.title
    }
}

/// The promise, always in view.
struct SafetyFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Trash only, never deleted", systemImage: "arrow.uturn.backward")
            Label("No internet connection, ever", systemImage: "wifi.slash")
            Label("Open source", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(.rounded(14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BareMac only moves items to the Trash, never connects to the internet, and is open source.")
    }
}

struct ModuleView: View {
    let module: Module

    var body: some View {
        switch module {
        case .overview: OverviewView()
        case .systemJunk: SystemJunkView()
        case .leftovers: LeftoversView()
        case .trash: TrashView()
        case .uninstaller: UninstallerView()
        case .startupItems: StartupItemsView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .spaceMap: SpaceMapView()
        case .history: HistoryView()
        }
    }
}
