import SwiftUI

/// Every screen in the sidebar.
enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview
    case systemJunk
    case leftovers
    case trash
    case uninstaller
    case startupItems
    case largeFiles
    case duplicates
    case spaceMap
    case history

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable {
        case main, clean, apps, files, activity
        var id: String { rawValue }
        var title: String? {
            switch self {
            case .main: nil
            case .clean: "Clean"
            case .apps: "Apps"
            case .files: "Files"
            case .activity: "Activity"
            }
        }
    }

    var section: Section {
        switch self {
        case .overview: .main
        case .systemJunk, .leftovers, .trash: .clean
        case .uninstaller, .startupItems: .apps
        case .largeFiles, .duplicates, .spaceMap: .files
        case .history: .activity
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .systemJunk: "System Junk"
        case .leftovers: "App Leftovers"
        case .trash: "Trash"
        case .uninstaller: "Uninstaller"
        case .startupItems: "Startup Items"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .spaceMap: "Space Map"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .systemJunk: "tray.full"
        case .leftovers: "app.dashed"
        case .trash: "trash"
        case .uninstaller: "shippingbox.and.arrow.backward"
        case .startupItems: "power"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "doc.on.doc"
        case .spaceMap: "rectangle.split.3x3"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// A tint used only for illustrations, never for controls (controls follow the system accent).
    var tint: Color {
        switch self {
        case .overview: .blue
        case .systemJunk: .teal
        case .leftovers: .indigo
        case .trash: .gray
        case .uninstaller: .orange
        case .startupItems: .green
        case .largeFiles: .purple
        case .duplicates: .pink
        case .spaceMap: .cyan
        case .history: .brown
        }
    }

    /// One plain sentence that says what the screen is for.
    var tagline: String {
        switch self {
        case .overview: "Your disk at a glance, measured live."
        case .systemJunk: "Caches, logs and damaged settings that apps rebuild on their own."
        case .leftovers: "Files left behind by apps you already removed."
        case .trash: "What's in your Trash. BareMac never empties it."
        case .uninstaller: "Remove an app together with every file it made."
        case .startupItems: "What starts when you log in, in plain words."
        case .largeFiles: "Your biggest files, and when you last opened them."
        case .duplicates: "Files with exactly the same content, byte for byte."
        case .spaceMap: "See which folders take the most space."
        case .history: "Everything BareMac moved, and a way to put it back."
        }
    }

    /// ⌘1 … ⌘9 and ⌘0.
    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .systemJunk: "2"
        case .leftovers: "3"
        case .trash: "4"
        case .uninstaller: "5"
        case .startupItems: "6"
        case .largeFiles: "7"
        case .duplicates: "8"
        case .spaceMap: "9"
        case .history: "0"
        }
    }

    /// Modules with a "Move to Trash" button.
    var canClean: Bool {
        switch self {
        case .systemJunk, .leftovers, .uninstaller, .largeFiles, .duplicates: true
        default: false
        }
    }

    /// Modules with a scan.
    var canScan: Bool { self != .history }
}
