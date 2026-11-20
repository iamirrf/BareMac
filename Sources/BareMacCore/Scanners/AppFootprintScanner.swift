import Foundation

/// An app plus every file BareMac could find that it made.
public struct AppFootprint: Sendable, Hashable {
    public let app: InstalledApp
    public let bundleItem: FoundItem
    public let relatedItems: [FoundItem]
    public let isRunning: Bool
    public let notes: [String]

    public var allItems: [FoundItem] { [bundleItem] + relatedItems }
    public var bytes: Int64 { allItems.totalBytes }
    public var suggestedBytes: Int64 { allItems.suggestedBytes }
}

/// Finds an app's bundle and support files for the Uninstaller.
public struct AppFootprintScanner: Sendable {
    public let environment: ScanEnvironment
    public let policy: SafetyPolicy
    public let inventory: AppInventory
    public let runningBundleIdentifiers: Set<String>
    public let hasFullDiskAccess: Bool

    public init(environment: ScanEnvironment, policy: SafetyPolicy, inventory: AppInventory,
                runningBundleIdentifiers: Set<String> = [], hasFullDiskAccess: Bool = false) {
        self.environment = environment
        self.policy = policy
        self.inventory = inventory
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// Apps the user may uninstall: not Apple's, not in a system folder, not BareMac.
    public func uninstallableApps() -> [InstalledApp] {
        inventory.apps.filter { app in
            !app.isApple && !app.isInSystemFolder
                && !BundleID.isRelated(app.bundleIdentifier, environment.ownBundleIdentifier)
                && !BundleID.isRelated(app.bundleIdentifier, BareMacIdentity.bundleIdentifier)
        }
    }

    /// Names that never identify one app.
    static let genericNames: Set<String> = ["electron", "app", "helper", "launcher", "main", "application", "updater", "setup", "installer"]

    @concurrent public func footprint(of app: InstalledApp, progress: ProgressHandler? = nil) async throws -> AppFootprint {
        let builder = ItemBuilder(policy: policy)
        let home = environment.home.path
        var throttle = ProgressThrottle()
        var visited = 0
        var notes: [String] = []
        let isRunning = runningBundleIdentifiers.contains { running in app.allIdentifiers.contains { BundleID.isRelated($0, running) } }

        progress?(ScanProgress(phase: "Measuring \(app.name)", currentPath: PathTools.abbreviated(app.url.path, home: home)))
        let bundleReason = isRunning ? "\(app.name) is open. Quit it first." : nil
        let bundleItem = try builder.make(
            url: app.url, category: .appBundle, name: app.name,
            explanation: "The app itself\(app.version.map { ", version \($0)" } ?? "").",
            owner: app.ref, suggested: true, infoReason: bundleReason
        )
        if isRunning { notes.append("\(app.name) is open. Quit it before uninstalling.") }
        if let reason = bundleItem.infoReason, !isRunning { notes.append(reason) }

        let info = AppInventory.bundleInfo(at: app.url)
        let nameMatches = Set([app.name, info?["CFBundleName"] as? String, app.executableName].compactMap { $0?.lowercased() })
            .filter { !Self.genericNames.contains($0) && !SafetyPolicy.sharedFolderNames.contains($0) && !$0.isEmpty }
        let sharesTeam = app.teamIdentifier.map { team in inventory.apps.contains { $0.id != app.id && $0.teamIdentifier == team } } ?? false

        var related: [FoundItem] = []
        var seen = Set<String>()
        let zones = LibraryZone.allCases.filter { hasFullDiskAccess || !$0.needsFullDiskAccess }
        if !hasFullDiskAccess {
            notes.append("Without Full Disk Access, BareMac can't look in app containers, so some of \(app.name)'s files may be missing from this list.")
        }

        for (index, zone) in zones.enumerated() {
            for url in DirectoryListing.of(zone.url(home: environment.home)).urls {
                try checkCancellation()
                visited += 1
                if let progress, throttle.shouldEmit() {
                    progress(ScanProgress(phase: "Finding \(app.name)'s files", currentPath: PathTools.abbreviated(url.path, home: home),
                                          itemsVisited: visited, bytesSeen: related.totalBytes, fraction: Double(index) / Double(zones.count)))
                }
                guard !seen.contains(url.path) else { continue }
                let name = url.lastPathComponent
                if BundleID.isApple(name) { continue }

                guard let match = match(name: name, zone: zone, app: app, nameMatches: nameMatches, sharesTeam: sharesTeam) else { continue }
                seen.insert(url.path)
                let item = try builder.make(
                    url: url, category: .appFile, name: zone.title,
                    explanation: zone.explanation(appName: app.name), owner: app.ref,
                    suggested: match.suggested, note: match.note
                )
                if item.bytes > 0 || zone.requiredExtension != nil { related.append(item) }
            }
        }
        related.sort { $0.bytes > $1.bytes }
        return AppFootprint(app: app, bundleItem: bundleItem, relatedItems: related, isRunning: isRunning, notes: notes)
    }

    private struct Match {
        let suggested: Bool
        let note: String?
    }

    private func match(name: String, zone: LibraryZone, app: InstalledApp, nameMatches: Set<String>, sharesTeam: Bool) -> Match? {
        let identifiers = app.allIdentifiers
        if zone == .groupContainers {
            let lowered = name.lowercased()
            if app.appGroups.contains(where: { $0.lowercased() == lowered }) { return Match(suggested: true, note: nil) }
            if lowered.hasPrefix("group."), identifiers.contains(where: { BundleID.isRelated($0, String(name.dropFirst(6))) }) {
                return Match(suggested: true, note: nil)
            }
            let parts = name.split(separator: ".", maxSplits: 1)
            if parts.count == 2, let team = app.teamIdentifier, String(parts[0]) == team {
                return sharesTeam
                    ? Match(suggested: false, note: "Shared with other apps from this developer.")
                    : Match(suggested: true, note: nil)
            }
            return nil
        }
        if let identifier = zone.identifier(fromItemName: name), identifiers.contains(where: { BundleID.isRelated($0, identifier) }) {
            return Match(suggested: true, note: nil)
        }
        let nameZones: Set<LibraryZone> = [.applicationSupport, .caches, .logs, .containers]
        if nameZones.contains(zone), nameMatches.contains(name.lowercased()) {
            return Match(suggested: false, note: "Matched by name. Check that it belongs to \(app.name).")
        }
        return nil
    }
}
