import Foundation

/// What kind of thing an item is. The category decides which allowlist rule the
/// file engine applies before anything moves.
public enum CleanCategory: String, Sendable, Codable, CaseIterable, Hashable {
    /// `~/Library/Caches/<item>`
    case userCache
    /// `~/Library/Containers/<app>/Data/Library/Caches/<item>`
    case containerCache
    /// `~/Library/Logs/<item>`
    case log
    /// A damaged property list directly inside `~/Library/Preferences`.
    case brokenPreference
    /// A device backup inside `~/Library/Application Support/MobileSync/Backup`.
    case iosBackup
    /// Support files of an app that is no longer installed, in a known Library folder.
    case appLeftover
    /// Support files of an app the user is uninstalling, in a known Library folder.
    case appFile
    /// An app bundle the user owns, in /Applications or ~/Applications.
    case appBundle
    /// A regular file the user picked in their home folder (large files, duplicates).
    case userFile
    /// Shown so you know where space goes; the allowlist refuses to move it, always.
    case informationOnly

    public var displayName: String {
        switch self {
        case .userCache: "Cache"
        case .containerCache: "App cache"
        case .log: "Log"
        case .brokenPreference: "Broken preference"
        case .iosBackup: "Device backup"
        case .appLeftover: "Leftover"
        case .appFile: "App file"
        case .appBundle: "App"
        case .userFile: "File"
        case .informationOnly: "Information"
        }
    }
}

/// An app an item belongs to.
public struct AppRef: Sendable, Hashable, Codable {
    public var name: String
    public var bundleIdentifier: String
    /// Location of the app bundle, when it exists on this Mac.
    public var url: URL?

    public init(name: String, bundleIdentifier: String, url: URL? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
    }
}

/// Something a scanner found. Every number in it was measured.
public struct FoundItem: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let category: CleanCategory
    /// Short display name.
    public let name: String
    /// Plain-language explanation of what this is and what removing it means.
    public let explanation: String
    public let owner: AppRef?
    public let measurement: Measurement
    public let modified: Date?
    /// `false` means information only: BareMac shows it but will never offer to move it.
    public let isCleanable: Bool
    /// Why an item is information only.
    public let infoReason: String?
    /// BareMac's suggestion to include it. The user always decides.
    public let isSuggested: Bool
    /// An extra heads-up, for example that the owning app is open.
    public let note: String?

    public init(
        url: URL,
        category: CleanCategory,
        name: String,
        explanation: String,
        owner: AppRef? = nil,
        measurement: Measurement,
        modified: Date? = nil,
        isCleanable: Bool = true,
        infoReason: String? = nil,
        isSuggested: Bool = false,
        note: String? = nil
    ) {
        self.url = url
        self.category = category
        self.name = name
        self.explanation = explanation
        self.owner = owner
        self.measurement = measurement
        self.modified = modified
        self.isCleanable = isCleanable && infoReason == nil
        self.infoReason = infoReason
        self.isSuggested = isSuggested && isCleanable && infoReason == nil
        self.note = note
    }

    /// Space the item occupies on disk.
    public var bytes: Int64 { measurement.allocatedBytes }

    /// A copy marked information-only with a reason.
    public func informationOnly(_ reason: String) -> FoundItem {
        FoundItem(
            url: url, category: category, name: name, explanation: explanation, owner: owner,
            measurement: measurement, modified: modified, isCleanable: false, infoReason: reason,
            isSuggested: false, note: note
        )
    }
}

extension Array where Element == FoundItem {
    /// Total measured bytes of the cleanable items.
    public var cleanableBytes: Int64 { filter(\.isCleanable).reduce(0) { $0 + $1.bytes } }
    /// Total measured bytes of every item.
    public var totalBytes: Int64 { reduce(0) { $0 + $1.bytes } }
    /// Total measured bytes of the items BareMac suggests.
    public var suggestedBytes: Int64 { filter(\.isSuggested).reduce(0) { $0 + $1.bytes } }
}

/// Live progress of a scan. Every value is a real count, never a guess.
public struct ScanProgress: Sendable, Hashable {
    public var phase: String
    public var currentPath: String?
    public var itemsVisited: Int
    public var bytesSeen: Int64
    /// 0...1 when the total amount of work is known, otherwise `nil`.
    public var fraction: Double?

    public init(phase: String, currentPath: String? = nil, itemsVisited: Int = 0, bytesSeen: Int64 = 0, fraction: Double? = nil) {
        self.phase = phase
        self.currentPath = currentPath
        self.itemsVisited = itemsVisited
        self.bytesSeen = bytesSeen
        self.fraction = fraction
    }
}

public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

/// Limits progress callbacks to about ten per second.
struct ProgressThrottle {
    private var last: UInt64 = 0
    private let interval: UInt64

    init(perSecond: Double = 10) {
        interval = UInt64(1_000_000_000 / perSecond)
    }

    mutating func shouldEmit() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last >= interval else { return false }
        last = now
        return true
    }
}

/// Errors scanners report in plain language.
public enum ScanError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The scan was stopped."
        case let .unreadable(message): message
        }
    }
}

func checkCancellation() throws {
    if Task.isCancelled { throw ScanError.cancelled }
}

/// Directory listing that returns an empty list for missing folders and reports
/// whether the folder could be read at all.
struct DirectoryListing {
    let urls: [URL]
    let isReadable: Bool

    static func of(_ directory: URL, includeHidden: Bool = false) -> DirectoryListing {
        let path = directory.path
        guard fileStatus(path) != nil else { return DirectoryListing(urls: [], isReadable: true) }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            let urls = names
                .filter { includeHidden || !$0.hasPrefix(".") }
                .sorted()
                .map { directory.appending(path: $0) }
            return DirectoryListing(urls: urls, isReadable: true)
        } catch {
            return DirectoryListing(urls: [], isReadable: false)
        }
    }
}
