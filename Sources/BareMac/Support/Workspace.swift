import AppKit
import BareMacCore
import SystemConfiguration

/// Small wrappers around Finder and System Settings. None of them move or change files.
@MainActor
enum Workspace {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
    }

    static func openAppManagementSettings() {
        NSWorkspace.shared.open(Permissions.appManagementSettingsURL)
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(Permissions.loginItemsSettingsURL)
    }

    static func openTrash(home: URL) {
        NSWorkspace.shared.open(LibraryPaths(home: home).trash)
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Asks an app to quit, the same way ⌘Q does. It can still ask to save documents.
    @discardableResult
    static func quit(bundleIdentifier: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        apps.forEach { $0.terminate() }
        return !apps.isEmpty
    }

    /// The Mac's name from System Settings › General › Sharing, read locally.
    static var computerName: String? {
        #if DEBUG
        if DebugModes.demoHome != nil { return "MacBook Air" }
        #endif
        return SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}
