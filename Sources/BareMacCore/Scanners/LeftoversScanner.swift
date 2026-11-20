import Foundation

public struct LeftoverGroup: Sendable, Identifiable, Hashable {
    public enum NameSource: String, Sendable, Hashable { case appInTrash, knownApp, appID }

    public var id: String { identifier }
    /// The root app ID, for example "com.example.gone".
    public let identifier: String
    public let app: AppRef
    public let nameSource: NameSource
    public let items: [FoundItem]
    /// Another installed app from the same developer may still use these, so they're information only.
    public let isAmbiguous: Bool
    public let note: String?

    public var bytes: Int64 { items.totalBytes }
    public var cleanableBytes: Int64 { items.cleanableBytes }
}

public struct LeftoversResult: Sendable {
    public let groups: [LeftoverGroup]
    public let notices: [String]
    public var cleanableBytes: Int64 { groups.reduce(0) { $0 + $1.cleanableBytes } }
    public var suggestedBytes: Int64 { groups.reduce(0) { $0 + $1.items.suggestedBytes } }
}

/// Files in Library folders named after apps that are no longer installed.
public struct LeftoversScanner: Sendable {
    public let environment: ScanEnvironment
    public let policy: SafetyPolicy
    public let inventory: AppInventory
    public let hasFullDiskAccess: Bool

    public init(environment: ScanEnvironment, policy: SafetyPolicy, inventory: AppInventory, hasFullDiskAccess: Bool = false) {
        self.environment = environment
        self.policy = policy
        self.inventory = inventory
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    private struct Candidate {
        let url: URL
        let zone: LibraryZone
        let identifier: String
        let ambiguousWith: String?
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> LeftoversResult {
        var notices: [String] = []
        var candidates: [Candidate] = []
        var throttle = ProgressThrottle()
        var visited = 0
        let home = environment.home.path

        if !hasFullDiskAccess {
            notices.append("Give BareMac Full Disk Access to check app containers and cookies too.")
        }

        let zones = LibraryZone.allCases.filter { hasFullDiskAccess || !$0.needsFullDiskAccess }
        for (index, zone) in zones.enumerated() {
            let folder = zone.url(home: environment.home)
            let listing = DirectoryListing.of(folder)
            if !listing.isReadable {
                notices.append("macOS didn't let BareMac look in ~/\(zone.relativePath).")
                continue
            }
            for url in listing.urls {
                try checkCancellation()
                visited += 1
                if let progress, throttle.shouldEmit() {
                    progress(ScanProgress(phase: "Matching app files", currentPath: PathTools.abbreviated(url.path, home: home),
                                          itemsVisited: visited, fraction: Double(index) / Double(zones.count)))
                }
                if let candidate = classify(url, zone: zone) { candidates.append(candidate) }
            }
        }

        // Group by root ID: the shortest candidate ID related to the others.
        let identifiers = Set(candidates.map { $0.identifier.lowercased() })
        func root(of identifier: String) -> String {
            let lowered = identifier.lowercased()
            return identifiers.filter { lowered == $0 || lowered.hasPrefix($0 + ".") }.min { $0.count < $1.count } ?? lowered
        }
        let grouped = Dictionary(grouping: candidates) { root(of: $0.identifier) }

        let builder = ItemBuilder(policy: policy)
        var groups: [LeftoverGroup] = []
        for (rootID, members) in grouped {
            try checkCancellation()
            let displayIdentifier = members.min { $0.identifier.count < $1.identifier.count }?.identifier ?? rootID
            let (app, source) = name(for: displayIdentifier)
            let ambiguousWith = members.compactMap(\.ambiguousWith).first
            var items: [FoundItem] = []
            for member in members {
                visited += 1
                if let progress, throttle.shouldEmit() {
                    progress(ScanProgress(phase: "Measuring leftovers", currentPath: PathTools.abbreviated(member.url.path, home: home), itemsVisited: visited))
                }
                let reason = ambiguousWith.map { "Another app from the same developer (\($0)) is still installed and may use this." }
                let suggested = member.zone.isSuggestedForLeftovers
                let item = try builder.make(
                    url: member.url, category: .appLeftover, name: member.zone.title,
                    explanation: member.zone.explanation(appName: app.name), owner: app,
                    suggested: suggested,
                    note: suggested || reason != nil ? nil : "May hold your data or settings for this app. Check before including it.",
                    infoReason: reason
                )
                if item.bytes > 0 || member.zone.requiredExtension != nil { items.append(item) }
            }
            guard !items.isEmpty else { continue }
            items.sort { $0.bytes > $1.bytes }
            groups.append(LeftoverGroup(
                identifier: displayIdentifier, app: app, nameSource: source, items: items,
                isAmbiguous: ambiguousWith != nil,
                note: source == .appInTrash ? "The app itself is in your Trash." : (ambiguousWith.map { "\($0) is still installed, so BareMac only shows these." })
            ))
        }
        groups.sort { $0.bytes > $1.bytes }
        return LeftoversResult(groups: groups, notices: notices)
    }

    /// `nil` when the item belongs to something installed, to Apple, to BareMac, or isn't named after an app.
    private func classify(_ url: URL, zone: LibraryZone) -> Candidate? {
        let name = url.lastPathComponent
        let identifier: String
        let ownership: AppInventory.Ownership
        if zone == .groupContainers {
            let resolved = inventory.ownershipOfGroupContainer(name)
            guard let found = resolved.identifier else { return nil }
            identifier = found
            ownership = resolved.ownership
        } else {
            guard let found = zone.identifier(fromItemName: name) else { return nil }
            identifier = found
            ownership = inventory.ownership(of: found)
        }
        guard !BundleID.isApple(identifier), !BundleID.isApple(name) else { return nil }
        guard !BundleID.isRelated(identifier, environment.ownBundleIdentifier), !BundleID.isRelated(identifier, BareMacIdentity.bundleIdentifier) else { return nil }
        if zone == .launchAgents, Self.launchAgentProgramExists(url) { return nil }

        switch ownership {
        case .installed:
            return nil
        case let .sameDeveloper(other):
            return Candidate(url: url, zone: zone, identifier: identifier, ambiguousWith: other)
        case .notInstalled:
            return Candidate(url: url, zone: zone, identifier: identifier, ambiguousWith: nil)
        }
    }

    /// A launch agent whose program still exists is an active background item, not a leftover.
    static func launchAgentProgramExists(_ plist: URL) -> Bool {
        guard let dictionary = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let program = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return program != nil }
        return fileStatus(program) != nil
    }

    private func name(for identifier: String) -> (AppRef, LeftoverGroup.NameSource) {
        if environment.useLaunchServices, let trashed = AppInventory.trashedApp(for: identifier) {
            return (AppRef(name: AppInventory.displayName(of: trashed), bundleIdentifier: identifier, url: trashed), .appInTrash)
        }
        if let known = BundleID.knownNames[identifier.lowercased()] {
            return (AppRef(name: known, bundleIdentifier: identifier), .knownApp)
        }
        return (AppRef(name: BundleID.displayName(for: identifier), bundleIdentifier: identifier), .appID)
    }
}
