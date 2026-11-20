import Darwin
import Foundation

/// One folder or file in the Space Map, measured.
public struct SpaceNode: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    /// Allocated bytes of every file below (folders' own blocks aren't counted).
    public let bytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    /// Packages (apps, photo libraries…) are measured fully but shown as one tile.
    public let isPackage: Bool
    /// Largest first, at most `maxChildren`, each at least `minimumChildBytes`.
    public let children: [SpaceNode]
    /// Bytes below this node that aren't inside a listed child.
    public let otherBytes: Int64
    public let otherCount: Int
    public let unreadableCount: Int
}

/// Measures everything under a folder in one pass and keeps the biggest parts.
public struct SpaceMapScanner: Sendable {
    public let root: URL
    public let maxChildren: Int
    public let minimumChildBytes: Int64

    public init(root: URL, maxChildren: Int = 40, minimumChildBytes: Int64 = 1_000_000) {
        self.root = root
        self.maxChildren = maxChildren
        self.minimumChildBytes = minimumChildBytes
    }

    private struct Frame {
        let path: String
        let name: String
        let isPackage: Bool
        var bytes: Int64 = 0
        var fileCount = 0
        var unreadable = 0
        var children: [SpaceNode] = []
        var otherBytes: Int64 = 0
        var otherCount = 0
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> SpaceNode {
        let rootPath = PathTools.canonicalRoot(root)
        var stack: [Frame] = []
        var seenLinks = Set<InodeKey>()
        var result: SpaceNode?
        var visited = 0
        var totalSeen: Int64 = 0
        var throttle = ProgressThrottle()

        func add(_ node: SpaceNode, to frame: inout Frame) {
            frame.bytes += node.bytes
            frame.fileCount += node.fileCount
            frame.unreadable += node.unreadableCount
            if !frame.isPackage, node.bytes >= minimumChildBytes {
                frame.children.append(node)
            } else {
                frame.otherBytes += node.bytes
                frame.otherCount += 1
            }
        }

        func finish(_ frame: Frame) -> SpaceNode {
            var children = frame.children.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            var otherBytes = frame.otherBytes
            var otherCount = frame.otherCount
            if frame.isPackage {
                otherBytes = frame.bytes
                otherCount = frame.fileCount
                children = []
            } else if children.count > maxChildren {
                for extra in children[maxChildren...] {
                    otherBytes += extra.bytes
                    otherCount += 1
                }
                children = Array(children.prefix(maxChildren))
            }
            return SpaceNode(
                url: URL(filePath: frame.path, directoryHint: .isDirectory), name: frame.name, bytes: frame.bytes,
                fileCount: frame.fileCount, isDirectory: true, isPackage: frame.isPackage, children: children,
                otherBytes: otherBytes, otherCount: otherCount, unreadableCount: frame.unreadable
            )
        }

        do {
            try FileWalker.walk(rootPath) { entry in
                visited += 1
                if visited & 0x3FF == 0 { try checkCancellation() }
                switch entry.kind {
                case .directory:
                    let path = entry.path
                    let name = entry.level == 0 ? (path as NSString).lastPathComponent : entry.name
                    let package = entry.level > 0 && UserFileWalk.isPackageDirectory(path, name: name)
                    stack.append(Frame(path: path, name: name, isPackage: package))
                    if let progress, throttle.shouldEmit() {
                        progress(ScanProgress(phase: "Measuring folders", currentPath: path, itemsVisited: visited, bytesSeen: totalSeen))
                    }
                case .directoryAfterChildren:
                    guard let frame = stack.popLast() else { return }
                    let node = finish(frame)
                    if stack.isEmpty { result = node } else { add(node, to: &stack[stack.count - 1]) }
                case .file, .symlink, .other:
                    guard let status = entry.stat, !status.isDirectory else { return }
                    if status.st_nlink > 1, !seenLinks.insert(InodeKey(status)).inserted { return }
                    let bytes = status.allocatedBytes
                    totalSeen += bytes
                    let path = entry.path
                    let node = SpaceNode(
                        url: URL(filePath: path), name: entry.level == 0 ? (path as NSString).lastPathComponent : entry.name,
                        bytes: bytes, fileCount: 1, isDirectory: false, isPackage: false, children: [],
                        otherBytes: 0, otherCount: 0, unreadableCount: 0
                    )
                    if stack.isEmpty { result = node } else { add(node, to: &stack[stack.count - 1]) }
                case .unreadable:
                    if stack.isEmpty {
                        result = SpaceNode(url: root, name: root.lastPathComponent, bytes: 0, fileCount: 0, isDirectory: true, isPackage: false,
                                           children: [], otherBytes: 0, otherCount: 0, unreadableCount: 1)
                    } else {
                        stack[stack.count - 1].unreadable += 1
                    }
                }
            }
        } catch is FileWalker.WalkError {
            throw ScanError.unreadable("BareMac couldn't open “\(root.lastPathComponent)”.")
        }
        guard let result else { throw ScanError.unreadable("BareMac couldn't read “\(root.lastPathComponent)”.") }
        return result
    }
}
