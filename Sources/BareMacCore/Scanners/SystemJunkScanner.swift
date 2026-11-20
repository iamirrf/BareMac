import Foundation

public struct SystemJunkResult: Sendable {
    public enum SectionKind: String, Sendable, CaseIterable, Hashable {
        case userCaches, appCaches, logs, brokenPreferences, deviceBackups, languageFiles, systemLogs
    }

    public struct Section: Sendable, Identifiable, Hashable {
        public var id: SectionKind { kind }
        public let kind: SectionKind
        public let title: String
        public let explanation: String
        public let items: [FoundItem]
        public let notice: String?
        public var cleanableBytes: Int64 { items.cleanableBytes }
    }

    public let sections: [Section]
    public var allItems: [FoundItem] { sections.flatMap(\.items) }
    public var cleanableBytes: Int64 { allItems.cleanableBytes }
    public var suggestedBytes: Int64 { allItems.suggestedBytes }
}

/// Caches, logs, damaged settings, device backups, and (information only) unused app
/// languages and system logs.
public struct SystemJunkScanner: Sendable {
    public let environment: ScanEnvironment
    public let policy: SafetyPolicy
    public let inventory: AppInventory?
    public let runningBundleIdentifiers: Set<String>
    public let hasFullDiskAccess: Bool

    public init(environment: ScanEnvironment, policy: SafetyPolicy, inventory: AppInventory? = nil,
                runningBundleIdentifiers: Set<String> = [], hasFullDiskAccess: Bool = false) {
        self.environment = environment
        self.policy = policy
        self.inventory = inventory
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> SystemJunkResult {
        var reporter = JunkProgress(handler: progress, home: environment.home.path)
        let kinds = SystemJunkResult.SectionKind.allCases
        var sections: [SystemJunkResult.Section] = []
        for (index, kind) in kinds.enumerated() {
            try checkCancellation()
            reporter.section(index: index, of: kinds.count, phase: Self.title(kind))
            sections.append(try scanSection(kind, reporter: &reporter))
        }
        return SystemJunkResult(sections: sections)
    }

    // MARK: Sections

    private func scanSection(_ kind: SystemJunkResult.SectionKind, reporter: inout JunkProgress) throws -> SystemJunkResult.Section {
        var items: [FoundItem] = []
        var notice: String?
        let builder = ItemBuilder(policy: policy)
        let paths = environment.paths

        switch kind {
        case .userCaches:
            for url in DirectoryListing.of(paths.caches).urls {
                try checkCancellation()
                reporter.item(url.path, bytes: items.totalBytes)
                let owner = owner(forName: url.lastPathComponent)
                let running = owner.map(isRunning) ?? false
                let isApple = BundleID.isApple(url.lastPathComponent)
                let item = try builder.make(
                    url: url, category: .userCache, name: displayName(url.lastPathComponent, owner: owner),
                    explanation: "Temporary files \(owner?.name ?? "an app") made to work faster. Apps make them again when needed.",
                    owner: owner, suggested: !running && !isApple,
                    note: running ? "\(owner?.name ?? "The app") is open. Quit it first for the cleanest result." : nil
                )
                if item.bytes > 0 { items.append(item) }
            }

        case .appCaches:
            guard hasFullDiskAccess else {
                notice = "Give BareMac Full Disk Access to check caches of App Store apps."
                break
            }
            for container in DirectoryListing.of(paths.containers).urls where !BundleID.isApple(container.lastPathComponent) {
                let caches = container.appending(path: "Data/Library/Caches", directoryHint: .isDirectory)
                let owner = owner(forName: container.lastPathComponent)
                let running = owner.map(isRunning) ?? false
                for url in DirectoryListing.of(caches).urls {
                    try checkCancellation()
                    reporter.item(url.path, bytes: items.totalBytes)
                    let appName = owner?.name ?? BundleID.displayName(for: container.lastPathComponent)
                    let item = try builder.make(
                        url: url, category: .containerCache, name: "\(appName): \(url.lastPathComponent)",
                        explanation: "Temporary files \(appName) made to work faster. The app makes them again when needed.",
                        owner: owner, suggested: !running,
                        note: running ? "\(appName) is open. Quit it first for the cleanest result." : nil
                    )
                    if item.bytes > 0 { items.append(item) }
                }
            }

        case .logs:
            for url in DirectoryListing.of(paths.logs).urls {
                try checkCancellation()
                reporter.item(url.path, bytes: items.totalBytes)
                let name = url.lastPathComponent
                let owner = owner(forName: name)
                let explanation = name == "DiagnosticReports"
                    ? "Crash and freeze reports. Only useful when reporting a bug."
                    : "Log files \(owner?.name ?? displayName(name, owner: nil)) wrote while it ran. Apps don't need old logs to work."
                let item = try builder.make(
                    url: url, category: .log, name: name == "DiagnosticReports" ? "Crash reports" : displayName(name, owner: owner),
                    explanation: explanation, owner: owner, suggested: true
                )
                if item.bytes > 0 { items.append(item) }
            }

        case .brokenPreferences:
            for url in DirectoryListing.of(paths.preferences).urls where url.pathExtension.lowercased() == "plist" {
                try checkCancellation()
                guard let status = fileStatus(url.path), status.isRegularFile, Self.isBroken(url, size: status.logicalBytes) else { continue }
                let identifier = SafetyPolicy.identifier(fromFileName: url.lastPathComponent)
                let owner = owner(forName: identifier)
                items.append(try builder.make(
                    url: url, category: .brokenPreference, name: displayName(identifier, owner: owner),
                    explanation: "This settings file is damaged, so the app can't read it. The app makes a fresh one when needed.",
                    owner: owner, suggested: true
                ))
            }

        case .deviceBackups:
            let folder = paths.mobileSyncBackups
            let listing = DirectoryListing.of(folder)
            if !listing.isReadable {
                notice = "Give BareMac Full Disk Access to see device backups."
            }
            for url in listing.urls where fileStatus(url.path)?.isDirectory == true {
                try checkCancellation()
                reporter.item(url.path, bytes: items.totalBytes)
                let info = NSDictionary(contentsOf: url.appending(path: "Info.plist")) as? [String: Any] ?? [:]
                let device = info["Device Name"] as? String ?? "a device"
                let date = info["Last Backup Date"] as? Date
                let version = info["Product Version"] as? String
                var explanation = "Backup of \(device)"
                if let date { explanation += " from \(date.formatted(date: .long, time: .omitted))" }
                if let version { explanation += " (iOS \(version))" }
                explanation += ". Remove it only if you have a newer backup in iCloud or on another Mac."
                items.append(try builder.make(
                    url: url, category: .iosBackup, name: "Backup of \(device)", explanation: explanation, suggested: false
                ))
            }

        case .languageFiles:
            items = try languageItems(builder: builder, reporter: &reporter)

        case .systemLogs:
            for url in environment.systemLogDirectories where fileStatus(url.path) != nil {
                try checkCancellation()
                reporter.item(url.path, bytes: items.totalBytes)
                let measurement = try DiskMeasurer.measureForScan(url)
                items.append(try builder.make(
                    url: url, category: .informationOnly, name: url.path,
                    explanation: measurement.isComplete ? "System logs" : "System logs (at least this much; some are hidden from apps)",
                    measurement: measurement,
                    infoReason: "macOS manages these logs and clears old ones itself. BareMac doesn't touch system files."
                ))
            }
        }

        items.sort { $0.bytes > $1.bytes }
        return SystemJunkResult.Section(kind: kind, title: Self.title(kind), explanation: Self.explanation(kind), items: items, notice: notice)
    }

    // MARK: Language files

    private func languageItems(builder: ItemBuilder, reporter: inout JunkProgress) throws -> [FoundItem] {
        let wanted = Set(environment.preferredLanguages.map(Self.languageCode)).union(["base", "en"])
        var apps: [URL] = []
        if let inventory {
            apps = inventory.apps.filter { !$0.isApple && !$0.isInSystemFolder }.map(\.url)
        } else {
            for folder in environment.applicationsDirectories { apps += AppInventory.findApps(in: folder) }
        }
        var items: [FoundItem] = []
        for app in apps {
            try checkCancellation()
            reporter.item(app.path, bytes: items.totalBytes)
            let info = AppInventory.bundleInfo(at: app)
            if let identifier = info?["CFBundleIdentifier"] as? String, BundleID.isApple(identifier) { continue }
            var keep = wanted
            if let region = info?["CFBundleDevelopmentRegion"] as? String { keep.insert(Self.languageCode(region)) }
            let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
            var total = Measurement()
            var count = 0
            for folder in DirectoryListing.of(resources).urls where folder.pathExtension.lowercased() == "lproj" {
                let code = Self.languageCode(folder.deletingPathExtension().lastPathComponent)
                guard !keep.contains(code) else { continue }
                total += try DiskMeasurer.measureForScan(folder)
                count += 1
            }
            guard count > 0, total.allocatedBytes > 0 else { continue }
            let name = AppInventory.displayName(of: app)
            items.append(try builder.make(
                url: app, category: .informationOnly, name: name,
                explanation: "\(count) \(count == 1 ? "language" : "languages") you don't use",
                measurement: total,
                infoReason: "Removing language files changes an app's signed contents, which can stop it from opening. BareMac shows this only so you know where space goes."
            ))
        }
        return items
    }

    static let legacyLanguageNames: [String: String] = [
        "english": "en", "french": "fr", "german": "de", "japanese": "ja", "spanish": "es", "italian": "it",
        "dutch": "nl", "portuguese": "pt", "swedish": "sv", "danish": "da", "finnish": "fi", "norwegian": "no",
        "korean": "ko", "russian": "ru", "polish": "pl", "chinese": "zh",
    ]

    /// "en-GB" → "en", "zh_Hans" → "zh", "English" → "en", "nb" → "no".
    static func languageCode(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if let legacy = legacyLanguageNames[lowered] { return legacy }
        let code = String(lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(lowered))
        return code == "nb" || code == "nn" ? "no" : code
    }

    // MARK: Helpers

    static func isBroken(_ url: URL, size: Int64) -> Bool {
        if size == 0 { return true }
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil
    }

    private func owner(forName name: String) -> AppRef? {
        let identifier = SafetyPolicy.identifier(fromFileName: name)
        guard BundleID.isPlausible(identifier), let inventory else { return nil }
        if let app = inventory.app(withIdentifier: identifier) { return app.ref }
        if case let .installed(ref) = inventory.ownership(of: identifier) { return ref }
        return nil
    }

    private func isRunning(_ owner: AppRef) -> Bool {
        runningBundleIdentifiers.contains { BundleID.isRelated($0, owner.bundleIdentifier) }
    }

    private func displayName(_ name: String, owner: AppRef?) -> String {
        if let owner { return owner.name }
        return BundleID.isPlausible(name) ? BundleID.displayName(for: name) : name
    }

    static func title(_ kind: SystemJunkResult.SectionKind) -> String {
        switch kind {
        case .userCaches: "Caches"
        case .appCaches: "App Store app caches"
        case .logs: "Logs"
        case .brokenPreferences: "Damaged settings files"
        case .deviceBackups: "iPhone and iPad backups"
        case .languageFiles: "Unused app languages"
        case .systemLogs: "System logs"
        }
    }

    static func explanation(_ kind: SystemJunkResult.SectionKind) -> String {
        switch kind {
        case .userCaches: "Temporary files apps keep to work faster. They're made again when needed."
        case .appCaches: "The same kind of temporary files, kept inside App Store apps' private folders."
        case .logs: "Records apps write while they run. Apps don't need old ones."
        case .brokenPreferences: "Settings files macOS can't read anymore."
        case .deviceBackups: "Full backups of your devices. BareMac never picks these for you."
        case .languageFiles: "Translations inside apps for languages you don't use. Shown only — BareMac never changes apps."
        case .systemLogs: "Logs macOS keeps for itself. Shown only."
        }
    }
}

/// Throttled, section-aware progress reporting.
private struct JunkProgress {
    let handler: ProgressHandler?
    let home: String
    var throttle = ProgressThrottle()
    var phase = ""
    var sectionIndex = 0
    var sectionCount = 1
    var visited = 0

    init(handler: ProgressHandler?, home: String) {
        self.handler = handler
        self.home = home
    }

    mutating func section(index: Int, of count: Int, phase: String) {
        sectionIndex = index
        sectionCount = count
        self.phase = "Measuring \(phase.lowercased())"
        handler?(ScanProgress(phase: self.phase, itemsVisited: visited, fraction: Double(index) / Double(count)))
    }

    mutating func item(_ path: String, bytes: Int64) {
        visited += 1
        guard let handler, throttle.shouldEmit() else { return }
        handler(ScanProgress(
            phase: phase, currentPath: PathTools.abbreviated(path, home: home), itemsVisited: visited,
            bytesSeen: bytes, fraction: Double(sectionIndex) / Double(sectionCount)
        ))
    }
}
