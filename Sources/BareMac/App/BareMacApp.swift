import AppKit
import BareMacCore
import SwiftUI

@main
struct BareMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("BareMac", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    await model.start()
                    #if DEBUG
                    Snapshotter.runIfRequested(model)
                    #endif
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { BareMacCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BareMacCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .appInfo) {
            Button("About BareMac") { AboutPanel.show() }
        }

        CommandMenu("Scan") {
            Button("Scan Again") { model.scan(model.selection) }
                .keyboardShortcut("r")
                .disabled(!model.selection.canScan || model.isScanning(model.selection))
            Button("Stop Scanning") { model.stop(model.selection) }
                .keyboardShortcut(".")
                .disabled(!model.isScanning(model.selection))
            Divider()
            Button("Move Selected to Trash…") { model.requestClean(model.selection) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canClean(model.selection))
        }

        CommandGroup(before: .sidebar) {
            ForEach(Module.allCases) { module in
                if let key = module.shortcut {
                    Button(module.title) { model.selection = module }
                        .keyboardShortcut(key)
                }
            }
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("How BareMac Stays Safe") { Workspace.open(Links.safety) }
            Button("BareMac Source Code") { Workspace.open(Links.repository) }
            Button("Report a Problem") { Workspace.open(Links.issues) }
            Divider()
            Button("Show Action Log in Finder") { Workspace.reveal(model.log.fileURL) }
                .disabled(!FileManager.default.fileExists(atPath: model.log.fileURL.path))
        }
    }
}

/// The standard About panel, with the safety promise in the credits.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(
            string: "The Mac cleaner that shows its work.\n\nTrash only · Zero network · Open source (MIT)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "BareMac",
            .applicationVersion: BareMacIdentity.version,
            .credits: credits,
        ])
        NSApplication.shared.activate()
    }
}
