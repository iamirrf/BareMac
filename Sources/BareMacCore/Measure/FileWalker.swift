import Darwin
import Foundation

/// A thin, fast wrapper around `fts(3)` — the same walker `du` uses.
///
/// It never follows symbolic links (`FTS_PHYSICAL`) and never crosses onto another
/// volume (`FTS_XDEV`), so a walk that starts in the home folder stays there.
struct FileWalker {
    enum Kind {
        case directory
        case directoryAfterChildren
        case file
        case symlink
        case unreadable
        case other
    }

    struct Entry {
        fileprivate let fts: UnsafeMutablePointer<FTS>
        fileprivate let raw: UnsafeMutablePointer<FTSENT>
        let kind: Kind

        var path: String { String(cString: raw.pointee.fts_path) }
        var level: Int { Int(raw.pointee.fts_level) }

        /// Name of the entry without allocating a Swift string for the full path.
        var name: String {
            let pathLength = Int(raw.pointee.fts_pathlen)
            let nameLength = Int(raw.pointee.fts_namelen)
            return String(cString: raw.pointee.fts_path + (pathLength - nameLength))
        }

        /// `true` when the entry name begins with a dot.
        var isHidden: Bool {
            let pathLength = Int(raw.pointee.fts_pathlen)
            let nameLength = Int(raw.pointee.fts_namelen)
            guard nameLength > 0 else { return false }
            return raw.pointee.fts_path[pathLength - nameLength] == 0x2E // "."
        }

        var stat: Darwin.stat? { raw.pointee.fts_statp?.pointee }

        /// Stops the walk from descending into this directory.
        func skipChildren() {
            _ = fts_set(fts, raw, FTS_SKIP)
        }
    }

    enum WalkError: Error {
        case cannotOpen(path: String, errno: Int32)
    }

    /// Walks `path` depth-first and calls `visit` for every entry, including the
    /// post-order visit of each directory.
    static func walk(_ path: String, _ visit: (Entry) throws -> Void) throws {
        guard let duplicate = strdup(path) else { throw WalkError.cannotOpen(path: path, errno: ENOMEM) }
        defer { free(duplicate) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [duplicate, nil]
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw WalkError.cannotOpen(path: path, errno: errno)
        }
        defer { fts_close(fts) }

        while let raw = fts_read(fts) {
            let info = Int32(raw.pointee.fts_info)
            let kind: Kind
            switch info {
            case FTS_D: kind = .directory
            case FTS_DP: kind = .directoryAfterChildren
            case FTS_F: kind = .file
            case FTS_SL, FTS_SLNONE: kind = .symlink
            case FTS_DNR, FTS_ERR, FTS_NS: kind = .unreadable
            case FTS_DC: kind = .other
            default: kind = .other
            }
            try visit(Entry(fts: fts, raw: raw, kind: kind))
        }
    }
}

/// Identity of a file on disk, used to count hard links only once.
struct InodeKey: Hashable {
    let device: Int32
    let inode: UInt64

    init(_ status: Darwin.stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

/// `SF_DATALESS`: the file's contents live in the cloud (for example an evicted
/// iCloud Drive file). Reading such a file would download it, so BareMac never does.
let datalessFileFlag: UInt32 = 0x4000_0000

extension Darwin.stat {
    var allocatedBytes: Int64 { Int64(st_blocks) * 512 }
    var logicalBytes: Int64 { Int64(st_size) }
    var isDataless: Bool { st_flags & datalessFileFlag != 0 }
    var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(st_mtimespec.tv_sec) + TimeInterval(st_mtimespec.tv_nsec) / 1e9)
    }
    var isRegularFile: Bool { (st_mode & S_IFMT) == S_IFREG }
    var isDirectory: Bool { (st_mode & S_IFMT) == S_IFDIR }
    var isSymlink: Bool { (st_mode & S_IFMT) == S_IFLNK }
}

/// `lstat(2)` as an optional.
func fileStatus(_ path: String) -> Darwin.stat? {
    var status = Darwin.stat()
    return lstat(path, &status) == 0 ? status : nil
}
