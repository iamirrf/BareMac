import Foundation

/// The Library folders where apps keep their support files. App Leftovers and the
/// Uninstaller both read these, and `SafetyPolicy.appSupportZones` allows exactly
/// their direct children.
public enum LibraryZone: String, CaseIterable, Sendable, Hashable {
    case applicationSupport
    case caches
    case preferences
    case byHostPreferences
    case containers
    case groupContainers
    case savedApplicationState
    case httpStorages
    case webKit
    case logs
    case cookies
    case launchAgents
    case applicationScripts

    /// Path below the home folder.
    public var relativePath: String {
        switch self {
        case .applicationSupport: "Library/Application Support"
        case .caches: "Library/Caches"
        case .preferences: "Library/Preferences"
        case .byHostPreferences: "Library/Preferences/ByHost"
        case .containers: "Library/Containers"
        case .groupContainers: "Library/Group Containers"
        case .savedApplicationState: "Library/Saved Application State"
        case .httpStorages: "Library/HTTPStorages"
        case .webKit: "Library/WebKit"
        case .logs: "Library/Logs"
        case .cookies: "Library/Cookies"
        case .launchAgents: "Library/LaunchAgents"
        case .applicationScripts: "Library/Application Scripts"
        }
    }

    public func url(home: URL) -> URL {
        home.appending(path: relativePath, directoryHint: .isDirectory)
    }

    /// macOS protects these; BareMac only looks inside with Full Disk Access, so it
    /// never triggers a stream of permission prompts.
    public var needsFullDiskAccess: Bool {
        switch self {
        case .containers, .groupContainers, .cookies: true
        default: false
        }
    }

    /// Files macOS requires to have a specific extension here.
    public var requiredExtension: String? {
        switch self {
        case .preferences, .byHostPreferences, .launchAgents: "plist"
        case .cookies: "binarycookies"
        default: nil
        }
    }

    /// Whether leftovers in this folder are pre-selected. Caches, logs, window state
    /// and web data are safe to suggest. Settings and app data may hold things the
    /// user still wants (for example a notes app's database), so they start unchecked.
    public var isSuggestedForLeftovers: Bool {
        switch self {
        case .caches, .logs, .savedApplicationState, .httpStorages, .webKit, .cookies: true
        case .applicationSupport, .preferences, .byHostPreferences, .containers, .groupContainers,
             .launchAgents, .applicationScripts: false
        }
    }

    /// The app ID an item in this folder is named after, or `nil` if the name isn't
    /// shaped like one. Group Containers are resolved by `AppInventory` instead.
    ///
    /// - `com.example.app.plist` → `com.example.app`
    /// - `com.example.app.0A1B2C3D-…-9F.plist` (ByHost) → `com.example.app`
    /// - `com.example.app.savedState` → `com.example.app`
    public func identifier(fromItemName name: String) -> String? {
        var base = SafetyPolicy.identifier(fromFileName: name)
        if let required = requiredExtension, !name.lowercased().hasSuffix("." + required) { return nil }
        if self == .byHostPreferences {
            var parts = base.split(separator: ".").map(String.init)
            if let last = parts.last, Self.isHostIdentifier(last), parts.count > 2 {
                parts.removeLast()
                base = parts.joined(separator: ".")
            }
        }
        guard self != .groupContainers, BundleID.isPlausible(base) else { return nil }
        return base
    }

    /// ByHost files end in the Mac's hardware UUID or a 12-digit hex ID.
    static func isHostIdentifier(_ part: String) -> Bool {
        let hex = part.replacingOccurrences(of: "-", with: "")
        guard hex.allSatisfy(\.isHexDigit) else { return false }
        return (part.count == 36 && part.filter { $0 == "-" }.count == 4) || hex.count == 12
    }

    /// Plain-language description of an item in this folder.
    public func explanation(appName: String) -> String {
        switch self {
        case .applicationSupport: "Data and settings \(appName) keeps for itself. It may include things you made in the app."
        case .caches: "Temporary files \(appName) made to work faster. Safe to remove."
        case .preferences, .byHostPreferences: "\(appName)'s settings. Removing them resets the app's settings."
        case .containers: "\(appName)'s private data folder. It may include things you made in the app."
        case .groupContainers: "Data \(appName) shares with its helpers or sibling apps."
        case .savedApplicationState: "Window positions macOS saved for \(appName). Safe to remove."
        case .httpStorages, .webKit, .cookies: "Web data \(appName) saved, such as cookies and web caches. Safe to remove."
        case .logs: "Log files \(appName) wrote while it ran. Safe to remove."
        case .launchAgents: "A background task \(appName) set up to start when you log in."
        case .applicationScripts: "A scripts folder macOS made for \(appName)."
        }
    }

    /// Short label for lists.
    public var title: String {
        switch self {
        case .applicationSupport: "App data"
        case .caches: "Cache"
        case .preferences: "Settings"
        case .byHostPreferences: "Settings (this Mac)"
        case .containers: "App container"
        case .groupContainers: "Shared container"
        case .savedApplicationState: "Saved windows"
        case .httpStorages: "Web storage"
        case .webKit: "Web data"
        case .logs: "Logs"
        case .cookies: "Cookies"
        case .launchAgents: "Login task"
        case .applicationScripts: "Scripts folder"
        }
    }
}
