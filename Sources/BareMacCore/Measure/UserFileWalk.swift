import Darwin
import Foundation

/// Walks the user's own documents the way Large & Old Files and Duplicates need:
///
/// - regular files only, never following symbolic links or leaving the volume;
/// - skips `~/Library` (other modules handle it), the Trash, hidden items, and
///   packages such as apps and photo libraries (macOS treats them as one document);
/// - reports cloud-only ("dataless") files separately and never opens them, because
///   reading one would download it.
public struct UserFileWalk: Sendable {
    public struct File: Sendable {
        public let path: String
        public let logicalBytes: Int64
        public let allocatedBytes: Int64
        public let device: Int32
        public let inode: UInt64
        public let linkCount: Int
        public let modified: Date
    }

    public struct Summary: Sendable {
        public var filesVisited = 0
        public var directoriesVisited = 0
        public var datalessSkipped = 0
        /// Folders macOS didn't let BareMac read (for example Desktop without permission).
        public var unreadableFolders: [String] = []
    }

    /// Extensions that are always packages, so no lookup is needed.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "fcpbundle", "logicx", "musiclibrary",
        "tvlibrary", "imovielibrary", "aplibrary", "photolibrary", "xcarchive", "xcodeproj", "xcworkspace",
        "playground", "dsym", "rtfd", "pages", "numbers", "key", "band", "saver", "prefpane", "qlgenerator",
        "mdimporter", "appex", "xpc", "systemextension", "lpdf", "sparsebundle", "photosprojects", "scriptd",
    ]

    public let homePath: String
    public let roots: [String]

    /// - Parameters:
    ///   - home: the user's home folder (its `Library` and `.Trash` are skipped).
    ///   - roots: folders to walk; defaults to the home folder.
    public init(home: URL, roots: [URL]? = nil) {
        homePath = PathTools.canonicalRoot(home)
        self.roots = (roots ?? [home]).map(PathTools.canonicalRoot)
    }

    /// Calls `visit` for every eligible regular file. Throws `ScanError.cancelled`.
    @discardableResult
    public func run(
        onDirectory: ((String) -> Void)? = nil,
        visit: (File) throws -> Void
    ) throws -> Summary {
        var summary = Summary()
        let skipped = [homePath + "/Library", homePath + "/.Trash"]
        var seenRoots = Set<String>()

        for root in roots where seenRoots.insert(root).inserted {
            do {
                try FileWalker.walk(root) { entry in
                    switch entry.kind {
                    case .directory:
                        let path = entry.path
                        if entry.level > 0 {
                            if entry.isHidden || skipped.contains(path) || Self.isPackageDirectory(path, name: entry.name) {
                                entry.skipChildren()
                                return
                            }
                        } else if skipped.contains(where: { PathTools.isInsideOrEqual(path, $0) }) {
                            entry.skipChildren()
                            return
                        }
                        summary.directoriesVisited += 1
                        if summary.directoriesVisited & 0x3F == 0 { try checkCancellation() }
                        onDirectory?(path)
                    case .file:
                        if entry.isHidden { return }
                        guard let status = entry.stat, status.isRegularFile else { return }
                        summary.filesVisited += 1
                        if summary.filesVisited & 0x3FF == 0 { try checkCancellation() }
                        if status.isDataless {
                            summary.datalessSkipped += 1
                            return
                        }
                        try visit(File(
                            path: entry.path,
                            logicalBytes: status.logicalBytes,
                            allocatedBytes: status.allocatedBytes,
                            device: status.st_dev,
                            inode: status.st_ino,
                            linkCount: Int(status.st_nlink),
                            modified: status.modificationDate
                        ))
                    case .unreadable:
                        if entry.level <= 2 { summary.unreadableFolders.append(entry.path) }
                    case .symlink, .other, .directoryAfterChildren:
                        break
                    }
                }
            } catch is FileWalker.WalkError {
                summary.unreadableFolders.append(root)
            }
        }
        return summary
    }

    static func isPackageDirectory(_ path: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if packageExtensions.contains(ext) { return true }
        return SafetyPolicy.isPackage(path)
    }
}
