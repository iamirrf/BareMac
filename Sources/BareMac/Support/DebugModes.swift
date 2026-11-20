#if DEBUG
import AppKit
import BareMacCore
import SwiftUI

/// Debug-only helpers for screenshots. Compiled out of release builds.
///
/// - `BAREMAC_DEMO_HOME=/path` points every scanner at a synthetic home folder, so
///   screenshots never show anyone's real files.
/// - `BAREMAC_SNAPSHOT_DIR=/path` makes the app visit every screen, render its window
///   to PNG files, and quit. `BAREMAC_APPEARANCE=dark` renders in dark mode.
enum DebugModes {
    static var demoHome: URL? {
        ProcessInfo.processInfo.environment["BAREMAC_DEMO_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func environment() -> ScanEnvironment {
        guard let home = demoHome else { return .live() }
        return ScanEnvironment(
            home: home,
            applicationsDirectories: [home.appending(path: "Applications", directoryHint: .isDirectory)],
            systemLaunchAgentsDirectory: home.appending(path: "System/LaunchAgents"),
            systemLaunchDaemonsDirectory: home.appending(path: "System/LaunchDaemons"),
            preferredLanguages: ["en"]
        )
    }
}

@MainActor
enum Snapshotter {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["BAREMAC_SNAPSHOT_DIR"] else { return }
        if env["BAREMAC_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if env["BAREMAC_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        let suffix = env["BAREMAC_APPEARANCE"] == "dark" ? "-dark" : ""
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        Task { @MainActor in
            await waitUntilIdle(model)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.setContentSize(NSSize(width: 1440, height: 900))
                window.center()
            }
            for module in Module.allCases {
                model.selection = module
                switch module {
                case .largeFiles, .duplicates, .spaceMap:
                    model.scan(module)
                case .uninstaller:
                    if let app = model.uninstaller.apps(model.context).first(where: { $0.name.hasPrefix("Pixel") }) ?? model.uninstaller.apps(model.context).first {
                        model.uninstaller.select(app, context: model.context)
                    }
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(400))
                await waitUntilIdle(model)
                try? await Task.sleep(for: .seconds(1.5))
                capture(name: module.rawValue + suffix, directory: directory)
            }
            NSApp.terminate(nil)
        }
    }

    private static func waitUntilIdle(_ model: AppModel) async {
        for _ in 0..<600 {
            let busy = Module.allCases.contains { model.isScanning($0) }
            if !busy { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func capture(name: String, directory: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
#endif
