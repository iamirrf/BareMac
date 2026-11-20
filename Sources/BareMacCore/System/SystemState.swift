import Darwin
import Foundation

/// Which apps are running right now, read from the process table with `libproc`.
public enum RunningApps {
    /// Bundle IDs (lowercased) of every app bundle that has a running process.
    public static func bundleIdentifiers() -> Set<String> {
        var identifiers = Set<String>()
        var bundlesSeen = Set<String>()
        for path in executablePaths() {
            guard let range = path.range(of: ".app/Contents/", options: .backwards) else { continue }
            // Use the outermost app, so helpers count for their parent app too.
            for bundlePath in appBundlePaths(in: path, through: range.lowerBound) where bundlesSeen.insert(bundlePath).inserted {
                if let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist"),
                   let identifier = info["CFBundleIdentifier"] as? String
                {
                    identifiers.insert(identifier.lowercased())
                }
            }
        }
        return identifiers
    }

    /// Every ".app" bundle along an executable path.
    private static func appBundlePaths(in path: String, through end: String.Index) -> [String] {
        var bundles: [String] = []
        var searchStart = path.startIndex
        while let range = path.range(of: ".app/", range: searchStart..<path.endIndex), range.lowerBound <= end {
            bundles.append(String(path[path.startIndex..<range.lowerBound]) + ".app")
            searchStart = range.upperBound
        }
        return bundles
    }

    static func executablePaths() -> [String] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            if length > 0 {
                paths.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        return paths
    }
}

/// What macOS lets BareMac read.
public enum Permissions {
    /// `true` when BareMac has Full Disk Access. Without it macOS hides the Trash,
    /// device backups and other apps' containers, and BareMac says so instead of guessing.
    public static func hasFullDiskAccess(home: URL) -> Bool {
        let probes = [
            home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path,
            home.appending(path: "Library/Safari/Bookmarks.plist").path,
        ]
        for path in probes where fileStatus(path) != nil {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: ".Trash").path)) != nil
    }

    /// The System Settings page where the user can grant Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// The System Settings page for App Management (needed to move apps).
    public static let appManagementSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    /// The System Settings page that lists login items and background items.
    public static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

/// Space on the startup disk, straight from the volume.
public struct DiskSnapshot: Sendable, Hashable {
    public let volumeName: String
    public let totalBytes: Int64
    /// Free right now.
    public let availableBytes: Int64
    /// Free plus what macOS can purge on its own (for example local snapshots and
    /// iCloud files it can re-download). This is the number Finder shows.
    public let availableForImportantUsageBytes: Int64

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var purgeableBytes: Int64 { max(0, availableForImportantUsageBytes - availableBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    public init(volumeName: String, totalBytes: Int64, availableBytes: Int64, availableForImportantUsageBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
    }

    /// Reads the volume that holds `url` (the home folder by default).
    public static func current(for url: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> DiskSnapshot {
        let values = try url.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskSnapshot(
            volumeName: values.volumeLocalizedName ?? "Macintosh HD",
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            availableBytes: available,
            availableForImportantUsageBytes: max(available, values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}

/// Byte counts formatted the way Finder does (base 10: 1 GB = 1,000,000,000 bytes).
public enum ByteText {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Exact byte count with grouping, for tooltips and the action log.
    public static func exact(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)") + " bytes"
    }
}
