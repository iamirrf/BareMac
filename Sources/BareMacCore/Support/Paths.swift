import Darwin
import Foundation

/// Small, dependency-free helpers for working with file system paths.
///
/// BareMac compares paths as plain strings after resolving symbolic links with
/// `realpath(3)`, so a symlink can never trick a check into approving a location
/// outside the allowlist.
public enum PathTools {
    /// The canonical path of an existing item, with every symbolic link resolved.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves the parent directory of `path` but keeps the last component as-is,
    /// so the item itself is never followed if it is a symbolic link.
    public static func resolvedParentPath(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, let realParent = realPath(parent) else { return nil }
        return realParent == "/" ? "/" + name : realParent + "/" + name
    }

    /// `true` when `path` is strictly inside `directory` (never equal to it).
    public static func isStrictlyInside(_ path: String, _ directory: String) -> Bool {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(base) && path.count > base.count
    }

    /// `true` when `path` is `directory` itself or anywhere inside it.
    public static func isInsideOrEqual(_ path: String, _ directory: String) -> Bool {
        path == directory || isStrictlyInside(path, directory)
    }

    /// Path components of `path` below `directory`, or `nil` if it is not inside.
    public static func components(of path: String, below directory: String) -> [String]? {
        guard isStrictlyInside(path, directory) else { return nil }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return path.dropFirst(base.count).split(separator: "/").map(String.init)
    }

    /// Canonical form of a directory path used as an allowlist root.
    public static func canonicalRoot(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        return realPath(standardized) ?? standardized
    }

    /// Replaces the home folder prefix with `~` for compact display.
    public static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if isStrictlyInside(path, home) { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

/// Well-known folders inside a user's home folder.
public struct LibraryPaths: Sendable, Hashable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }
    public var caches: URL { library.appending(path: "Caches", directoryHint: .isDirectory) }
    public var logs: URL { library.appending(path: "Logs", directoryHint: .isDirectory) }
    public var preferences: URL { library.appending(path: "Preferences", directoryHint: .isDirectory) }
    public var applicationSupport: URL { library.appending(path: "Application Support", directoryHint: .isDirectory) }
    public var containers: URL { library.appending(path: "Containers", directoryHint: .isDirectory) }
    public var groupContainers: URL { library.appending(path: "Group Containers", directoryHint: .isDirectory) }
    public var launchAgents: URL { library.appending(path: "LaunchAgents", directoryHint: .isDirectory) }
    public var mobileSyncBackups: URL {
        applicationSupport.appending(path: "MobileSync/Backup", directoryHint: .isDirectory)
    }
    public var trash: URL { home.appending(path: ".Trash", directoryHint: .isDirectory) }
    public var applications: URL { home.appending(path: "Applications", directoryHint: .isDirectory) }
    public var bareMacSupport: URL { applicationSupport.appending(path: "BareMac", directoryHint: .isDirectory) }
}

/// Everything a scanner needs to know about the machine it runs on.
///
/// Tests point every location at a fixture tree, so no scanner ever needs to read
/// the real home folder during `swift test`.
public struct ScanEnvironment: Sendable {
    public var home: URL
    public var applicationsDirectories: [URL]
    public var systemApplicationsDirectories: [URL]
    public var systemLogDirectories: [URL]
    public var systemLaunchAgentsDirectory: URL
    public var systemLaunchDaemonsDirectory: URL
    public var preferredLanguages: [String]
    public var useLaunchServices: Bool
    public var readCodeSignatures: Bool
    public var userID: uid_t
    public var ownBundleIdentifier: String

    public init(
        home: URL,
        applicationsDirectories: [URL],
        systemApplicationsDirectories: [URL] = [],
        systemLogDirectories: [URL] = [],
        systemLaunchAgentsDirectory: URL = URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory),
        systemLaunchDaemonsDirectory: URL = URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory),
        preferredLanguages: [String] = Locale.preferredLanguages,
        useLaunchServices: Bool = false,
        readCodeSignatures: Bool = false,
        userID: uid_t = getuid(),
        ownBundleIdentifier: String = BareMacIdentity.bundleIdentifier
    ) {
        self.home = home
        self.applicationsDirectories = applicationsDirectories
        self.systemApplicationsDirectories = systemApplicationsDirectories
        self.systemLogDirectories = systemLogDirectories
        self.systemLaunchAgentsDirectory = systemLaunchAgentsDirectory
        self.systemLaunchDaemonsDirectory = systemLaunchDaemonsDirectory
        self.preferredLanguages = preferredLanguages
        self.useLaunchServices = useLaunchServices
        self.readCodeSignatures = readCodeSignatures
        self.userID = userID
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    public var paths: LibraryPaths { LibraryPaths(home: home) }

    /// The real Mac: the signed-in user's home folder and the standard app folders.
    public static func live() -> ScanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ScanEnvironment(
            home: home,
            applicationsDirectories: [
                URL(filePath: "/Applications", directoryHint: .isDirectory),
                home.appending(path: "Applications", directoryHint: .isDirectory),
            ],
            systemApplicationsDirectories: [URL(filePath: "/System/Applications", directoryHint: .isDirectory)],
            systemLogDirectories: [
                URL(filePath: "/Library/Logs", directoryHint: .isDirectory),
                URL(filePath: "/private/var/log", directoryHint: .isDirectory),
            ],
            useLaunchServices: true,
            readCodeSignatures: true
        )
    }
}

/// BareMac's own identity, used so it never offers to clean itself.
public enum BareMacIdentity {
    public static let bundleIdentifier = "com.baremac.BareMac"
    public static let version = "1.0.0"
}
