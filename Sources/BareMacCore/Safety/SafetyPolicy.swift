import Darwin
import Foundation

/// The answer to "may BareMac move this?".
public enum SafetyVerdict: Sendable, Equatable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { self == .allowed }

    public var reason: String? {
        if case let .denied(reason) = self { return reason }
        return nil
    }
}

/// The allowlist. Every item the file engine moves must pass `evaluate` first —
/// at preview time and again right before it moves.
///
/// The rules are deliberately narrow:
/// - Only the signed-in user's home folder and the app folders are ever considered.
/// - Each category has an exact set of locations (for example *direct children* of
///   `~/Library/Caches`), never "anything below".
/// - Paths are resolved with `realpath(3)` first, so symlinks can't escape a zone.
/// - Some places are always off limits, whatever the category: the Trash itself,
///   keychains, iCloud Drive, Mail, Messages, Photos and BareMac's own action log.
public struct SafetyPolicy: Sendable {
    public let homePath: String
    public let applicationsPaths: [String]
    public let protectedBundleIdentifiers: Set<String>
    public let userID: uid_t

    /// Home-relative folders BareMac never touches, whatever the category.
    public static let protectedHomeSubtrees: [String] = [
        ".Trash",
        "Library/Keychains",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Mail",
        "Library/Messages",
        "Library/Photos",
        "Library/Accounts",
        "Library/Application Support/BareMac",
        "Library/Application Support/com.apple.TCC",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CloudDocs",
        "Library/Application Support/Knowledge",
        "Library/Group Containers/group.com.apple.notes",
    ]

    /// Caches macOS itself manages (iCloud, Find My, background downloads, photo
    /// analysis). Removing them makes macOS redo work or re-sync, so BareMac leaves
    /// them alone.
    public static let protectedCacheNames: Set<String> = [
        "com.apple.bird",
        "cloudkit",
        "com.apple.cloudd",
        "com.apple.cloudkit",
        "com.apple.nsurlsessiond",
        "familycircle",
        "com.apple.akd",
        "com.apple.icloudhelper",
        "com.apple.icloud.fmfd",
        "com.apple.findmy.fmipcore",
        "com.apple.findmy.fmfcore",
        "com.apple.homed",
        "com.apple.homekit",
        "com.apple.containermanagerd",
        "com.apple.passd",
        "com.apple.safari",
        "com.apple.mediaanalysisd",
        "com.apple.photoanalysisd",
        "com.apple.photolibraryd",
        "com.apple.ap.adprivacyd",
        "com.apple.amsengagementd",
        "com.apple.cloudphotosd",
    ]

    /// Library folders where app support files live. Used by `.appLeftover` and `.appFile`.
    public static let appSupportZones: [(folder: String, requiredExtension: String?)] = [
        ("Library/Application Support", nil),
        ("Library/Caches", nil),
        ("Library/Preferences", "plist"),
        ("Library/Preferences/ByHost", "plist"),
        ("Library/Containers", nil),
        ("Library/Group Containers", nil),
        ("Library/Saved Application State", nil),
        ("Library/HTTPStorages", nil),
        ("Library/WebKit", nil),
        ("Library/Logs", nil),
        ("Library/Cookies", "binarycookies"),
        ("Library/LaunchAgents", "plist"),
        ("Library/Application Scripts", nil),
    ]

    public init(environment: ScanEnvironment, protectedBundleIdentifiers: Set<String> = []) {
        self.init(
            home: environment.home,
            applicationsDirectories: environment.applicationsDirectories,
            protectedBundleIdentifiers: protectedBundleIdentifiers.union([environment.ownBundleIdentifier]),
            userID: environment.userID
        )
    }

    public init(home: URL, applicationsDirectories: [URL], protectedBundleIdentifiers: Set<String> = [], userID: uid_t = getuid()) {
        homePath = PathTools.canonicalRoot(home)
        applicationsPaths = applicationsDirectories.map(PathTools.canonicalRoot)
        self.protectedBundleIdentifiers = Set(protectedBundleIdentifiers.map { $0.lowercased() })
            .union([BareMacIdentity.bundleIdentifier.lowercased()])
        self.userID = userID
    }

    // MARK: - Evaluation

    public func evaluate(_ url: URL, as category: CleanCategory) -> SafetyVerdict {
        guard url.isFileURL else { return .denied("Only files on this Mac can be moved.") }
        let rawPath = url.path
        guard rawPath.hasPrefix("/") else { return .denied("The location isn't a full path.") }
        let rawComponents = rawPath.split(separator: "/")
        guard !rawComponents.contains(where: { $0 == ".." || $0 == "." }) else {
            return .denied("The path contains “.” or “..”, which BareMac never accepts.")
        }
        guard isUsableHome else { return .denied("BareMac can't identify a safe home folder.") }
        guard let status = fileStatus(rawPath) else { return .denied("The item no longer exists.") }
        guard status.isRegularFile || status.isDirectory || status.isSymlink else {
            return .denied("Only files and folders can be moved.")
        }
        guard let path = PathTools.resolvedParentPath(rawPath) else {
            return .denied("The item's folder can't be resolved.")
        }

        let inHome = PathTools.isStrictlyInside(path, homePath)
        let inApplications = applicationsPaths.contains { PathTools.isStrictlyInside(path, $0) }
        guard inHome || inApplications else {
            return .denied("It's outside your home folder and Applications, so BareMac won't touch it.")
        }
        if inHome, let protected = protectedSubtree(containing: path) {
            return .denied("“~/\(protected)” is always off limits.")
        }

        switch category {
        case .userCache:
            guard let name = matchZone(path, ["Library", "Caches", "*"]) else {
                return .denied("Caches must be directly inside ~/Library/Caches.")
            }
            if Self.protectedCacheNames.contains(name.lowercased()) {
                return .denied("macOS manages this cache, so BareMac leaves it alone.")
            }
            return .allowed

        case .containerCache:
            guard matchZone(path, ["Library", "Containers", "*", "Data", "Library", "Caches", "*"]) != nil else {
                return .denied("App caches must be directly inside an app container's Caches folder.")
            }
            let container = homeComponents(path)?[2] ?? ""
            if container.lowercased().hasPrefix("com.apple.") {
                return .denied("BareMac doesn't clean inside Apple's app containers.")
            }
            return .allowed

        case .log:
            guard matchZone(path, ["Library", "Logs", "*"]) != nil else {
                return .denied("Logs must be directly inside ~/Library/Logs.")
            }
            return .allowed

        case .brokenPreference:
            guard let name = matchZone(path, ["Library", "Preferences", "*"]) else {
                return .denied("Preferences must be directly inside ~/Library/Preferences.")
            }
            guard (name as NSString).pathExtension.lowercased() == "plist", status.isRegularFile else {
                return .denied("Only .plist files count as preferences.")
            }
            return .allowed

        case .iosBackup:
            guard matchZone(path, ["Library", "Application Support", "MobileSync", "Backup", "*"]) != nil,
                  status.isDirectory
            else {
                return .denied("Device backups must be folders directly inside MobileSync/Backup.")
            }
            return .allowed

        case .appLeftover:
            return evaluateAppSupportFile(path, status: status, allowPlainNames: false)

        case .appFile:
            return evaluateAppSupportFile(path, status: status, allowPlainNames: true)

        case .informationOnly:
            return .denied("BareMac only shows this. It never moves it.")

        case .appBundle:
            return evaluateAppBundle(path, status: status)

        case .userFile:
            return evaluateUserFile(path, status: status)
        }
    }

    // MARK: - Category rules

    /// Folder names in Library zones that belong to macOS or are shared by several
    /// apps from one developer. An uninstall never takes them, even when picked.
    public static let sharedFolderNames: Set<String> = [
        "apple", "mobilesync", "addressbook", "callhistorydb", "clouddocs", "knowledge", "crashreporter",
        "diagnosticreports", "icloud", "fileprovider", "syncservices", "dock", "google", "microsoft",
        "adobe", "jetbrains", "mozilla", "oracle", "java", "baremac",
    ]

    /// `.appLeftover` only accepts names shaped like app IDs (the scanner can't know a
    /// plain-named folder belonged to a removed app). `.appFile` (an uninstall the user
    /// started for one named app) also accepts plain folder names such as
    /// "Application Support/Slack", except macOS and shared vendor folders.
    private func evaluateAppSupportFile(_ path: String, status: Darwin.stat, allowPlainNames: Bool) -> SafetyVerdict {
        guard let components = homeComponents(path) else {
            return .denied("App files must be inside your Library folder.")
        }
        let name = components.last ?? ""
        let folder = components.dropLast().joined(separator: "/")
        guard let zone = Self.appSupportZones.first(where: { $0.folder == folder }) else {
            return .denied("App files must sit directly inside a known Library folder.")
        }
        if let required = zone.requiredExtension {
            guard (name as NSString).pathExtension.lowercased() == required, !status.isDirectory else {
                return .denied("Only .\(required) files are accepted in ~/\(folder).")
            }
        }
        let identifier = Self.identifier(fromFileName: name)
        if Self.sharedFolderNames.contains(identifier.lowercased()) {
            return .denied("“\(identifier)” is shared by macOS or several apps, so BareMac leaves it alone.")
        }
        guard identifier.contains(".") || allowPlainNames else {
            return .denied("BareMac only moves leftovers named after an app's ID.")
        }
        let lowered = identifier.lowercased()
        if lowered.hasPrefix("com.apple.") || lowered.hasPrefix("group.com.apple.") || lowered.contains(".com.apple.") {
            return .denied("BareMac never removes Apple's own files.")
        }
        if protectedBundleIdentifiers.contains(where: { lowered == $0 || lowered.hasPrefix($0 + ".") }) {
            return .denied("BareMac never removes its own files.")
        }
        return .allowed
    }

    private func evaluateAppBundle(_ path: String, status: Darwin.stat) -> SafetyVerdict {
        guard status.isDirectory, (path as NSString).pathExtension.lowercased() == "app" else {
            return .denied("Only .app bundles can be uninstalled.")
        }
        let depthOK = applicationsPaths.contains { root in
            guard let parts = PathTools.components(of: path, below: root) else { return false }
            return (1...2).contains(parts.count) && !parts.dropLast().contains { $0.hasSuffix(".app") }
        }
        guard depthOK else {
            return .denied("Apps must be in Applications (or one folder inside it).")
        }
        guard status.st_uid == userID else {
            return .denied("This app was installed for all users. Move it to the Trash in Finder; macOS will ask for your password.")
        }
        let infoPlist = URL(filePath: path).appending(path: "Contents/Info.plist")
        let identifier = (NSDictionary(contentsOf: infoPlist)?["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
        if identifier.hasPrefix("com.apple.") {
            return .denied("Apple's apps are part of macOS.")
        }
        if protectedBundleIdentifiers.contains(identifier) {
            return .denied("BareMac won't uninstall itself while it's running.")
        }
        return .allowed
    }

    private func evaluateUserFile(_ path: String, status: Darwin.stat) -> SafetyVerdict {
        guard status.isRegularFile else {
            return .denied("Only regular files can be picked here.")
        }
        guard let components = homeComponents(path), !components.isEmpty else {
            return .denied("Files must be inside your home folder.")
        }
        if components.first == "Library" {
            return .denied("Files inside ~/Library are handled by the other modules.")
        }
        if components.contains(where: { $0.hasPrefix(".") }) {
            return .denied("Hidden files and folders are left alone.")
        }
        var ancestor = homePath
        for component in components.dropLast() {
            ancestor += "/" + component
            if !(component as NSString).pathExtension.isEmpty, Self.isPackage(ancestor) {
                return .denied("It's inside “\(component)”, which macOS treats as a single document or app.")
            }
        }
        return .allowed
    }

    // MARK: - Helpers

    /// A home folder must be at least two levels deep and not inside a system folder.
    private var isUsableHome: Bool {
        let parts = homePath.split(separator: "/").map(String.init)
        let systemRoots: Set<String> = ["System", "usr", "bin", "sbin", "Library", "Applications", "opt", "cores", "dev", "etc"]
        guard parts.count >= 2, let first = parts.first else { return false }
        return !systemRoots.contains(first)
    }

    private func homeComponents(_ path: String) -> [String]? {
        PathTools.components(of: path, below: homePath)
    }

    /// Matches home-relative components against a pattern where `*` is any single
    /// component. Returns the last component on success.
    private func matchZone(_ path: String, _ pattern: [String]) -> String? {
        guard let components = homeComponents(path), components.count == pattern.count else { return nil }
        for (component, expected) in zip(components, pattern) where expected != "*" && component != expected {
            return nil
        }
        return components.last
    }

    private func protectedSubtree(containing path: String) -> String? {
        Self.protectedHomeSubtrees.first { subtree in
            PathTools.isInsideOrEqual(path, homePath + "/" + subtree)
        }
    }

    /// File suffixes macOS adds to app IDs in Library folders. Only these are stripped:
    /// app IDs are full of dots that are *not* file extensions.
    static let appFileSuffixes = [".plist", ".savedstate", ".binarycookies"]

    /// "com.example.app.plist" → "com.example.app"; "com.apple.sharedfilelist" stays as is.
    static func identifier(fromFileName name: String) -> String {
        let lowered = name.lowercased()
        for suffix in appFileSuffixes where lowered.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func isPackage(_ path: String) -> Bool {
        let values = try? URL(filePath: path, directoryHint: .isDirectory).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }
}
