import CoreServices
import Darwin
import Foundation
import Security

/// An app found on this Mac.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public let version: String?
    public let executableName: String?
    /// IDs of helpers, extensions and services inside the app bundle.
    public let embeddedIdentifiers: [String]
    /// The developer's team ID from the code signature, when it was read.
    public let teamIdentifier: String?
    /// App groups the app is entitled to (the names of its Group Containers).
    public let appGroups: [String]
    public let ownerUID: uid_t
    public let isInSystemFolder: Bool

    public var isApple: Bool { BundleID.isApple(bundleIdentifier) }
    public var allIdentifiers: [String] { [bundleIdentifier] + embeddedIdentifiers }
    public var ref: AppRef { AppRef(name: name, bundleIdentifier: bundleIdentifier, url: url) }
}

/// Every app and app component BareMac could find. Used to decide whether a
/// Library file belongs to something that is still installed.
public struct AppInventory: Sendable {
    public let apps: [InstalledApp]
    /// Bundle IDs of other installed components (System Settings panes, audio
    /// plug-ins, screen savers, Quick Look and Spotlight plug-ins, input methods).
    public let componentIdentifiers: [String: String]
    let useLaunchServices: Bool

    public init(apps: [InstalledApp], componentIdentifiers: [String: String] = [:], useLaunchServices: Bool = false) {
        self.apps = apps
        self.componentIdentifiers = componentIdentifiers
        self.useLaunchServices = useLaunchServices
    }

    /// Who, if anyone, still owns files named after `identifier`.
    public enum Ownership: Sendable, Equatable {
        /// An installed app or component uses this ID (or a related one).
        case installed(AppRef)
        /// Nothing uses this exact ID, but another installed app from the same
        /// developer might share it. BareMac treats this as information only.
        case sameDeveloper(String)
        /// Nothing installed uses this ID or anything from its developer.
        case notInstalled
    }

    // MARK: Lookup

    public func app(withIdentifier identifier: String) -> InstalledApp? {
        let lowered = identifier.lowercased()
        return apps.first { $0.bundleIdentifier.lowercased() == lowered }
    }

    public func ownership(of identifier: String) -> Ownership {
        if let app = apps.first(where: { $0.allIdentifiers.contains { BundleID.isRelated($0, identifier) } }) {
            return .installed(app.ref)
        }
        if let match = componentIdentifiers.first(where: { BundleID.isRelated($0.key, identifier) }) {
            return .installed(AppRef(name: match.value, bundleIdentifier: match.key))
        }
        if useLaunchServices, let url = Self.launchServicesApp(for: identifier) {
            return .installed(AppRef(name: Self.displayName(of: url), bundleIdentifier: identifier, url: url))
        }
        if let organization = BundleID.organization(of: identifier) {
            if let app = apps.first(where: { $0.allIdentifiers.contains { BundleID.organization(of: $0) == organization } }) {
                return .sameDeveloper(app.name)
            }
            if let component = componentIdentifiers.first(where: { BundleID.organization(of: $0.key) == organization }) {
                return .sameDeveloper(component.value)
            }
        }
        return .notInstalled
    }

    /// Ownership of a Group Containers folder such as `group.com.example.app`,
    /// `ABCDE12345.com.example.app` or `UBF8T346G9.Office`.
    public func ownershipOfGroupContainer(_ name: String) -> (ownership: Ownership, identifier: String?) {
        let lowered = name.lowercased()
        if let app = apps.first(where: { $0.appGroups.contains { $0.lowercased() == lowered } }) {
            return (.installed(app.ref), nil)
        }
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        var remainder = name
        if lowered.hasPrefix("group.") {
            remainder = String(name.dropFirst("group.".count))
        } else if parts.count == 2, BundleID.isTeamIdentifier(parts[0]) {
            if let app = apps.first(where: { $0.teamIdentifier == parts[0] }) {
                return (.installed(app.ref), nil)
            }
            remainder = parts[1]
        }
        guard BundleID.isPlausible(remainder) else {
            // A developer-wide container ("TEAMID.Office"): BareMac can't tell which app it served.
            return (.sameDeveloper(BundleID.humanize(remainder)), nil)
        }
        return (ownership(of: remainder), remainder)
    }

    // MARK: Scanning

    /// Finds apps in the given folders (and one level of subfolders), plus the IDs
    /// of helpers inside each app and of installed plug-in style components.
    public static func scan(environment: ScanEnvironment) -> AppInventory {
        var found: [(url: URL, system: Bool)] = []
        for folder in environment.applicationsDirectories { found += findApps(in: folder).map { ($0, false) } }
        for folder in environment.systemApplicationsDirectories { found += findApps(in: folder).map { ($0, true) } }

        let candidates = found
        let results = ConcurrentResults<InstalledApp>(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let candidate = candidates[index]
            results.set(index, readApp(at: candidate.url, isSystem: candidate.system, readSignature: environment.readCodeSignatures && !candidate.system))
        }

        var seen = Set<String>()
        let apps = results.values.compactMap { $0 }.filter { seen.insert($0.url.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppInventory(apps: apps, componentIdentifiers: scanComponents(environment: environment), useLaunchServices: environment.useLaunchServices)
    }

    static func findApps(in folder: URL) -> [URL] {
        var found: [URL] = []
        for child in DirectoryListing.of(folder).urls {
            if child.pathExtension.lowercased() == "app" {
                found.append(child)
            } else if fileStatus(child.path)?.isDirectory == true {
                found += DirectoryListing.of(child).urls.filter { $0.pathExtension.lowercased() == "app" }
            }
        }
        return found
    }

    static func readApp(at url: URL, isSystem: Bool, readSignature: Bool) -> InstalledApp? {
        guard let info = bundleInfo(at: url), let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            return nil
        }
        let signing: (team: String?, groups: [String]) = readSignature ? signingInfo(at: url) : (nil, [])
        return InstalledApp(
            url: url,
            name: displayName(of: url),
            bundleIdentifier: identifier,
            version: info["CFBundleShortVersionString"] as? String,
            executableName: info["CFBundleExecutable"] as? String,
            embeddedIdentifiers: embeddedIdentifiers(in: url),
            teamIdentifier: signing.team,
            appGroups: signing.groups,
            ownerUID: fileStatus(url.path)?.st_uid ?? 0,
            isInSystemFolder: isSystem
        )
    }

    static func bundleInfo(at url: URL) -> [String: Any]? {
        for relative in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
            if let dictionary = NSDictionary(contentsOf: url.appending(path: relative)) as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    /// The name Finder shows for a third-party app: its file name without ".app".
    /// Read locally — no LaunchServices round trip, which can block when many run at once.
    static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// IDs of bundles nested in the usual places inside an app.
    static func embeddedIdentifiers(in app: URL) -> [String] {
        let folders = ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/XPCServices", "Contents/PlugIns",
                       "Contents/Frameworks", "Contents/Library/SystemExtensions", "Contents/Library/QuickLook",
                       "Contents/Library/Spotlight", "Contents/MacOS", "Contents/Extensions"]
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension", "qlgenerator", "mdimporter"]
        var identifiers: [String] = []
        for folder in folders {
            for child in DirectoryListing.of(app.appending(path: folder)).urls where bundleExtensions.contains(child.pathExtension.lowercased()) {
                if let identifier = bundleInfo(at: child)?["CFBundleIdentifier"] as? String {
                    identifiers.append(identifier)
                }
            }
        }
        return identifiers
    }

    static func signingInfo(at url: URL) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return (nil, []) }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (team, groups)
    }

    /// Plug-in style components that have bundle IDs but aren't apps.
    static func scanComponents(environment: ScanEnvironment) -> [String: String] {
        let relative = ["Library/PreferencePanes", "Library/Screen Savers", "Library/QuickLook", "Library/Spotlight",
                        "Library/Input Methods", "Library/Internet Plug-Ins", "Library/Audio/Plug-Ins/Components",
                        "Library/Audio/Plug-Ins/VST", "Library/Audio/Plug-Ins/VST3", "Library/Audio/Plug-Ins/HAL",
                        "Library/Services", "Library/Application Support/Script Editor"]
        let roots = [environment.home] + (environment.useLaunchServices ? [URL(filePath: "/")] : [])
        var found: [String: String] = [:]
        for root in roots {
            for folder in relative {
                for child in DirectoryListing.of(root.appending(path: folder)).urls {
                    if let identifier = bundleInfo(at: child)?["CFBundleIdentifier"] as? String {
                        found[identifier] = displayName(of: child)
                    }
                }
            }
        }
        return found
    }

    /// An app with this ID anywhere LaunchServices knows about, ignoring the Trash.
    static func launchServicesApp(for identifier: String) -> URL? {
        guard let unmanaged = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil) else { return nil }
        let urls = unmanaged.takeRetainedValue() as? [URL] ?? []
        return urls.first { !FileEngine.isInsideATrash($0.path) && fileStatus($0.path) != nil }
    }

    /// Apps with this ID that are sitting in a Trash (recently dragged there).
    static func trashedApp(for identifier: String) -> URL? {
        guard let unmanaged = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil) else { return nil }
        let urls = unmanaged.takeRetainedValue() as? [URL] ?? []
        return urls.first { FileEngine.isInsideATrash($0.path) && fileStatus($0.path) != nil }
    }
}

/// Thread-safe fixed-size result buffer for `concurrentPerform`.
final class ConcurrentResults<Value: Sendable>: @unchecked Sendable {
    private var storage: [Value?]
    private let lock = NSLock()

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: Value?) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [Value?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
