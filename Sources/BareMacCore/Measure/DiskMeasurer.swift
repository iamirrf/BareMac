import Darwin
import Foundation

/// The result of actually measuring an item on disk. BareMac never estimates.
public struct Measurement: Sendable, Hashable, Codable {
    /// Bytes the item occupies on disk (allocated blocks). This is the space you get back.
    public var allocatedBytes: Int64
    /// Sum of file lengths, as Finder shows in "size".
    public var logicalBytes: Int64
    public var fileCount: Int
    public var directoryCount: Int
    /// Entries that could not be read (usually because macOS protects them).
    public var unreadableCount: Int

    public init(allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, fileCount: Int = 0, directoryCount: Int = 0, unreadableCount: Int = 0) {
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.unreadableCount = unreadableCount
    }

    public static let zero = Measurement()

    /// `true` when every entry inside the item was read and counted.
    public var isComplete: Bool { unreadableCount == 0 }

    public static func + (lhs: Measurement, rhs: Measurement) -> Measurement {
        Measurement(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            logicalBytes: lhs.logicalBytes + rhs.logicalBytes,
            fileCount: lhs.fileCount + rhs.fileCount,
            directoryCount: lhs.directoryCount + rhs.directoryCount,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount
        )
    }

    public static func += (lhs: inout Measurement, rhs: Measurement) {
        lhs = lhs + rhs
    }
}

/// Measures files and folders by walking them with `fts(3)` and reading `lstat(2)`.
///
/// - Sizes are allocated bytes (`st_blocks × 512`): the space that would actually
///   be freed. Compressed and sparse files therefore count what they really use.
/// - Hard links are counted once.
/// - Symbolic links are measured themselves and never followed.
/// - Anything unreadable is counted in `unreadableCount`, never guessed.
public enum DiskMeasurer {
    public struct Cancelled: Error {}

    /// Measures one item. Throws `Cancelled` if `isCancelled` returns `true`.
    public static func measure(_ url: URL, isCancelled: () -> Bool = { false }) throws -> Measurement {
        try measure(path: url.path, isCancelled: isCancelled)
    }

    public static func measure(path: String, isCancelled: () -> Bool = { false }) throws -> Measurement {
        var result = Measurement()
        var seenHardLinks = Set<InodeKey>()
        var visited = 0

        do {
            try FileWalker.walk(path) { entry in
                visited += 1
                if visited & 0x3FF == 0, isCancelled() { throw Cancelled() }

                switch entry.kind {
                case .directory:
                    result.directoryCount += 1
                case .file, .symlink, .other:
                    guard let status = entry.stat else {
                        result.unreadableCount += 1
                        return
                    }
                    if status.isDirectory { return } // FTS_DC cycle entries
                    result.fileCount += 1
                    if status.st_nlink > 1, !status.isDirectory {
                        guard seenHardLinks.insert(InodeKey(status)).inserted else { return }
                    }
                    result.allocatedBytes += status.allocatedBytes
                    result.logicalBytes += status.logicalBytes
                case .unreadable:
                    result.unreadableCount += 1
                case .directoryAfterChildren:
                    break
                }
            }
        } catch is FileWalker.WalkError {
            result.unreadableCount += 1
        }
        return result
    }
}

/// Clone-aware sizes on APFS.
///
/// Two APFS clones share the same blocks, so moving one of them to the Trash frees
/// almost nothing. `getattrlist(2)` can report a file's *private* size — the bytes
/// no other file shares — and BareMac uses it wherever a single file is offered.
public enum PrivateSize {
    /// Bytes that only this file uses, or `nil` when the volume can't tell.
    public static func privateBytes(path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE)

        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(truncatingIfNeeded: FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> Int64? in
            // Layout: u_int32_t length, attribute_set_t returned (5 × u_int32_t), off_t private size.
            let returnedForkAttributes = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedForkAttributes & UInt32(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }

    /// The space freed by removing this single file: its private size when known,
    /// otherwise its allocated size.
    public static func reclaimableBytes(path: String) -> Int64 {
        if let value = privateBytes(path: path) { return max(0, value) }
        return fileStatus(path)?.allocatedBytes ?? 0
    }
}
