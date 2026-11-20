import Foundation
import ServiceManagement

public struct StartupItem: Sendable, Identifiable, Hashable {
    public enum Scope: String, Sendable, Hashable { case userAgent, systemAgent, systemDaemon, loginHelper }

    public var id: String
    public let scope: Scope
    public let label: String
    public let plistURL: URL?
    public let programPath: String?
    public let programExists: Bool
    public let owner: AppRef?
    public let displayName: String
    /// Plain words, for example "Starts when you log in and keeps running."
    public let summary: String
    /// `nil` when BareMac can't know.
    public let isEnabled: Bool?
    public let isLoaded: Bool?
    /// Only your own background items can be switched, through `launchctl`.
    public let canToggle: Bool
    public let managementNote: String?
}

public struct StartupItemsResult: Sendable {
    public let userAgents: [StartupItem]
    public let systemAgents: [StartupItem]
    public let systemDaemons: [StartupItem]
    public let loginHelpers: [StartupItem]
}

/// Background items, explained in plain language.
public struct StartupItemsScanner: Sendable {
    public let environment: ScanEnvironment
    public let inventory: AppInventory?
    public let launchControl: any LaunchControlling

    public static let systemNote = "Installed for all users. Change it in System Settings › General › Login Items."

    public init(environment: ScanEnvironment, inventory: AppInventory?, launchControl: any LaunchControlling) {
        self.environment = environment
        self.inventory = inventory
        self.launchControl = launchControl
    }

    @concurrent public func scan() async throws -> StartupItemsResult {
        let overrides = (try? launchControl.disabledLabels()) ?? [:]
        let loaded = try? launchControl.loadedLabels()

        let user = try items(in: environment.paths.launchAgents, scope: .userAgent, overrides: overrides, loaded: loaded)
        let agents = try items(in: environment.systemLaunchAgentsDirectory, scope: .systemAgent, overrides: [:], loaded: nil)
        let daemons = try items(in: environment.systemLaunchDaemonsDirectory, scope: .systemDaemon, overrides: [:], loaded: nil)
        let helpers = loginHelpers()
        return StartupItemsResult(userAgents: user, systemAgents: agents, systemDaemons: daemons, loginHelpers: helpers)
    }

    // MARK: Launch agents and daemons

    private func items(in folder: URL, scope: StartupItem.Scope, overrides: [String: Bool], loaded: Set<String>?) throws -> [StartupItem] {
        var result: [StartupItem] = []
        for url in DirectoryListing.of(folder).urls where url.pathExtension.lowercased() == "plist" {
            try checkCancellation()
            guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
            let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            let exists = program.map { $0.hasPrefix("/") ? fileStatus($0) != nil : true } ?? false
            let owner = owner(label: label, program: program, plist: plist)
            var summary = Self.summary(for: plist)
            if program != nil, !exists { summary += " Its program is missing, so it can't run." }

            let isEnabled: Bool?
            let isLoaded: Bool?
            if scope == .userAgent {
                if let disabled = overrides[label] {
                    isEnabled = !disabled
                } else if let disabledKey = plist["Disabled"] as? Bool {
                    isEnabled = !disabledKey
                } else {
                    isEnabled = true
                }
                isLoaded = loaded.map { $0.contains(label) }
            } else {
                isEnabled = environment.useLaunchServices ? Self.legacyStatus(url) : nil
                isLoaded = nil
            }

            let validLabel = (try? SystemLaunchControl.validate(label)) != nil
            result.append(StartupItem(
                id: url.path, scope: scope, label: label, plistURL: url, programPath: program, programExists: exists,
                owner: owner, displayName: owner?.name ?? Self.readableLabel(label), summary: summary,
                isEnabled: isEnabled, isLoaded: isLoaded,
                canToggle: scope == .userAgent && validLabel,
                managementNote: scope == .userAgent ? nil : Self.systemNote
            ))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Whether macOS's Background Task Management allows a legacy plist (System Settings' toggle).
    static func legacyStatus(_ url: URL) -> Bool? {
        switch SMAppService.statusForLegacyPlist(at: url) {
        case .enabled: true
        case .requiresApproval: false
        default: nil
        }
    }

    private func owner(label: String, program: String?, plist: [String: Any]) -> AppRef? {
        let associated: [String] = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        if let inventory {
            for identifier in associated {
                if let app = inventory.app(withIdentifier: identifier) { return app.ref }
            }
        }
        if let program, let range = program.range(of: ".app/") {
            let appPath = String(program[..<range.lowerBound]) + ".app"
            let appURL = URL(filePath: appPath, directoryHint: .isDirectory)
            if let info = AppInventory.bundleInfo(at: appURL), let identifier = info["CFBundleIdentifier"] as? String {
                let outer = inventory?.apps.first { $0.allIdentifiers.contains { BundleID.isRelated($0, identifier) } }
                return outer?.ref ?? AppRef(name: AppInventory.displayName(of: appURL), bundleIdentifier: identifier, url: appURL)
            }
        }
        if let inventory, let app = inventory.apps.first(where: { $0.allIdentifiers.contains { BundleID.isRelated($0, label) } }) {
            return app.ref
        }
        return nil
    }

    // MARK: Login helpers inside apps

    private func loginHelpers() -> [StartupItem] {
        guard let inventory else { return [] }
        var result: [StartupItem] = []
        for app in inventory.apps where !app.isInSystemFolder {
            let folder = app.url.appending(path: "Contents/Library/LoginItems", directoryHint: .isDirectory)
            let helpers = DirectoryListing.of(folder).urls.filter { $0.pathExtension.lowercased() == "app" }
            guard !helpers.isEmpty else { continue }
            let label = helpers.compactMap { AppInventory.bundleInfo(at: $0)?["CFBundleIdentifier"] as? String }.first ?? app.bundleIdentifier
            result.append(StartupItem(
                id: "helper:\(app.url.path)", scope: .loginHelper, label: label, plistURL: nil, programPath: helpers.first?.path,
                programExists: true, owner: app.ref, displayName: app.name, summary: "Can start a helper when you log in.",
                isEnabled: nil, isLoaded: nil, canToggle: false,
                managementNote: "macOS manages whether it does. See System Settings › General › Login Items."
            ))
        }
        return result
    }

    // MARK: Plain language

    static func summary(for plist: [String: Any]) -> String {
        var parts: [String] = []
        let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        let keepAlive: Bool = {
            if let value = plist["KeepAlive"] as? Bool { return value }
            return plist["KeepAlive"] is [String: Any]
        }()
        if runAtLoad {
            parts.append(keepAlive ? "Starts when you log in and keeps running." : "Starts when you log in.")
        } else if keepAlive {
            parts.append("Keeps running in the background.")
        }
        if let interval = plist["StartInterval"] as? Int, interval > 0 {
            parts.append("Runs \(Self.every(interval)).")
        }
        if plist["StartCalendarInterval"] != nil {
            parts.append("Runs on a schedule.")
        }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil {
            parts.append("Runs when certain files change.")
        }
        if parts.isEmpty {
            if plist["MachServices"] != nil || plist["Sockets"] != nil || plist["LaunchEvents"] != nil {
                parts.append("Starts when an app or macOS asks for it.")
            } else {
                parts.append("Runs only when its app starts it.")
            }
        }
        return parts.joined(separator: " ")
    }

    static func every(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "every \(seconds) seconds"
        case 60: return "every minute"
        case ..<3600: return "every \(seconds / 60) minutes"
        case 3600: return "every hour"
        case ..<86400: return "every \(seconds / 3600) hours"
        case 86400: return "every day"
        default: return "every \(seconds / 86400) days"
        }
    }

    /// "com.example.backup-agent" → "Backup Agent".
    static func readableLabel(_ label: String) -> String {
        let last = label.split(separator: ".").last.map(String.init) ?? label
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Turns your own background items off and on, and logs every change.
public struct StartupController: Sendable {
    public let launchControl: any LaunchControlling
    public let log: ActionLog

    public enum ControlError: Error, LocalizedError {
        case notYours

        public var errorDescription: String? {
            "Only your own background items can be changed here. Items for all users are changed in System Settings › General › Login Items."
        }
    }

    public init(launchControl: any LaunchControlling, log: ActionLog) {
        self.launchControl = launchControl
        self.log = log
    }

    /// Stops it now and keeps it from starting at login (`launchctl disable` + `bootout`).
    public func turnOff(_ item: StartupItem) throws -> ActionRecord {
        guard item.scope == .userAgent, item.canToggle else { throw ControlError.notYours }
        try launchControl.disable(label: item.label)
        try launchControl.bootout(label: item.label)
        return try record(item, kind: .startupItemTurnedOff)
    }

    /// Lets it start again (`launchctl enable` + `bootstrap`).
    public func turnOn(_ item: StartupItem) throws -> ActionRecord {
        guard item.scope == .userAgent, item.canToggle, let plist = item.plistURL else { throw ControlError.notYours }
        try launchControl.enable(label: item.label)
        try launchControl.bootstrap(plist: plist)
        return try record(item, kind: .startupItemTurnedOn)
    }

    private func record(_ item: StartupItem, kind: ActionRecord.Kind) throws -> ActionRecord {
        let record = ActionRecord(
            batchID: UUID(), kind: kind, origin: "Startup Items", category: "startupItem", label: item.displayName,
            originalPath: item.plistURL?.path ?? item.label, trashedPath: nil, bytes: 0, fileCount: 0
        )
        try log.append(record)
        return record
    }
}
