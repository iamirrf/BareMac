import CryptoKit
import Darwin
import Foundation
@testable import BareMacCore

/// A throwaway folder that looks like a Mac: a home folder with a Library, an
/// Applications folder, a fake Trash, and an "outside" area full of decoys.
final class Fixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let applications: URL
    let trash: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "BareMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(filePath: PathTools.realPath(base.path)!, directoryHint: .isDirectory)
        home = root.appending(path: "Users/tester", directoryHint: .isDirectory)
        applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        trash = root.appending(path: "Volume/.Trash", directoryHint: .isDirectory)
        outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        for url in [home, applications, trash, outside, home.appending(path: "Library")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    deinit {
        // Make anything a test locked readable again, then remove the fixture.
        _ = try? FileManager.default.subpathsOfDirectory(atPath: root.path)
        chmodTree(root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func chmodTree(_ path: String) {
        chmod(path, 0o755)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for child in children {
            let full = path + "/" + child
            var status = stat()
            if lstat(full, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR { chmodTree(full) }
        }
    }

    // MARK: Building

    /// Writes a file of exactly `size` bytes of non-repeating data.
    @discardableResult
    func file(_ relativePath: String, size: Int, under base: URL? = nil, seed: UInt64 = 1) throws -> URL {
        let url = (base ?? home).appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.bytes(size, seed: seed).write(to: url)
        return url
    }

    /// Writes a file with the given contents.
    @discardableResult
    func file(_ relativePath: String, contents: Data, under base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    @discardableResult
    func directory(_ relativePath: String, under base: URL? = nil) throws -> URL {
        let url = (base ?? home).appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a minimal app bundle with an Info.plist.
    @discardableResult
    func app(
        _ name: String, bundleID: String, in folder: URL? = nil, version: String = "1.0",
        embedded: [(name: String, bundleID: String, path: String)] = [], executableSize: Int = 10_000
    ) throws -> URL {
        let appURL = (folder ?? applications).appending(path: "\(name).app", directoryHint: .isDirectory)
        try writeBundle(at: appURL, name: name, bundleID: bundleID, version: version, executableSize: executableSize)
        for item in embedded {
            let url = appURL.appending(path: "Contents/\(item.path)/\(item.name)", directoryHint: .isDirectory)
            try writeBundle(at: url, name: (item.name as NSString).deletingPathExtension, bundleID: item.bundleID, version: version, executableSize: 1_000)
        }
        return appURL
    }

    private func writeBundle(at url: URL, name: String, bundleID: String, version: String, executableSize: Int) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        try Self.bytes(executableSize, seed: UInt64(bitPattern: Int64(bundleID.hashValue))).write(to: contents.appending(path: "MacOS/\(name)"))
    }

    /// A property list file with real content.
    @discardableResult
    func plist(_ relativePath: String, _ dictionary: [String: Any], under base: URL? = nil) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try file(relativePath, contents: data, under: base)
    }

    // MARK: Environment

    func environment(languages: [String] = ["en"]) -> ScanEnvironment {
        ScanEnvironment(
            home: home,
            applicationsDirectories: [applications, home.appending(path: "Applications")],
            systemApplicationsDirectories: [],
            systemLogDirectories: [],
            systemLaunchAgentsDirectory: root.appending(path: "Library/LaunchAgents"),
            systemLaunchDaemonsDirectory: root.appending(path: "Library/LaunchDaemons"),
            preferredLanguages: languages,
            useLaunchServices: false,
            readCodeSignatures: false
        )
    }

    func policy() -> SafetyPolicy { SafetyPolicy(environment: environment()) }

    var folderTrash: FolderTrash { FolderTrash(directory: trash) }

    func engine(trasher: (any Trasher)? = nil) -> FileEngine {
        FileEngine(policy: policy(), trasher: trasher ?? folderTrash, log: ActionLog(fileURL: root.appending(path: "log/actions.jsonl")))
    }

    // MARK: Snapshots

    struct Fingerprint: Hashable {
        let isDirectory: Bool
        let size: Int64
        let digest: String
        let inode: UInt64
        let modified: Int
    }

    /// Every file and folder under `base`, with a content hash for every file.
    func snapshot(_ base: URL? = nil) throws -> [String: Fingerprint] {
        let basePath = (base ?? root).path
        var result: [String: Fingerprint] = [:]
        let enumerator = FileManager.default.enumerator(atPath: basePath)
        while let relative = enumerator?.nextObject() as? String {
            let full = basePath + "/" + relative
            var status = stat()
            guard lstat(full, &status) == 0 else { continue }
            let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
            var digest = ""
            if (status.st_mode & S_IFMT) == S_IFREG, let data = FileManager.default.contents(atPath: full) {
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else if (status.st_mode & S_IFMT) == S_IFLNK {
                digest = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "")
            }
            result[full] = Fingerprint(
                isDirectory: isDirectory, size: Int64(status.st_size), digest: digest,
                inode: status.st_ino, modified: Int(status.st_mtimespec.tv_sec)
            )
        }
        return result
    }

    // MARK: Data

    /// Deterministic, incompressible bytes (SplitMix64).
    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < count {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                withUnsafeBytes(of: z) { word in
                    let n = min(8, count - offset)
                    (base + offset).copyMemory(from: word.baseAddress!, byteCount: n)
                }
                offset += 8
            }
        }
        return data
    }
}

/// A stand-in for the macOS Trash that moves items into a folder named `.Trash`
/// inside the fixture, the way Finder names repeats ("name 2", "name 3").
struct FolderTrash: Trasher {
    let directory: URL

    func moveToTrash(_ url: URL) throws -> URL {
        let name = url.lastPathComponent
        var destination = directory.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) || fileStatus(destination.path) != nil {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = directory.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Exact allocated size of everything under a path, computed with Foundation's
/// enumerator — a different code path from BareMac's `fts` walker.
func foundationAllocatedSize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
    var total: Int64 = 0
    func add(_ item: URL) {
        let values = try? item.resourceValues(forKeys: Set(keys))
        if values?.isDirectory != true || values?.isSymbolicLink == true {
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
    }
    add(url)
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
        for case let item as URL in enumerator { add(item) }
    }
    return total
}
