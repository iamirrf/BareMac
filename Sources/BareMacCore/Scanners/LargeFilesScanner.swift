import CoreServices
import Foundation

public enum FileKind: String, Sendable, CaseIterable, Hashable {
    case video, audio, image, archive, diskImage, installer, document, code, other

    static let extensions: [FileKind: Set<String>] = [
        .video: ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "webm", "mpg", "mpeg", "flv", "3gp", "mts", "braw", "r3d"],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "alac", "caf", "m4b"],
        .image: ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "webp", "bmp"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "xip", "cpio"],
        .diskImage: ["dmg", "iso", "img", "sparseimage", "vdi", "vmdk", "qcow2", "vhd", "vhdx", "toast"],
        .installer: ["pkg", "mpkg", "ipa", "apk", "exe", "msi"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "epub", "csv", "md"],
        .code: ["json", "sqlite", "db", "log", "bin", "o", "a", "dylib", "jar", "class", "pyc", "wasm"],
    ]

    public static func of(fileName: String) -> FileKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }

    public var title: String {
        switch self {
        case .video: "Videos"
        case .audio: "Audio"
        case .image: "Images"
        case .archive: "Archives"
        case .diskImage: "Disk images"
        case .installer: "Installers"
        case .document: "Documents"
        case .code: "Data files"
        case .other: "Other"
        }
    }

    var singular: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio file"
        case .image: "Image"
        case .archive: "Archive"
        case .diskImage: "Disk image"
        case .installer: "Installer"
        case .document: "Document"
        case .code: "Data file"
        case .other: "File"
        }
    }
}

public struct LargeFile: Sendable, Identifiable, Hashable {
    public var id: String { item.id }
    public let item: FoundItem
    public let kind: FileKind
    /// When macOS last recorded the file being opened (Spotlight). `nil` means not recorded.
    public let lastOpened: Date?
    /// Space freed by moving only this file (clone-aware).
    public let reclaimableBytes: Int64
    /// `true` when the file shares blocks with another (an APFS clone).
    public var sharesStorage: Bool { reclaimableBytes < item.bytes * 9 / 10 }
}

public struct LargeFilesResult: Sendable {
    public let files: [LargeFile]
    public let filesVisited: Int
    public let unreadableFolders: [String]
    public let datalessSkipped: Int
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.item.bytes } }
}

/// Files in your home folder above a size you choose.
public struct LargeFilesScanner: Sendable {
    public let environment: ScanEnvironment
    public let policy: SafetyPolicy
    public let roots: [URL]?
    public let minimumBytes: Int64
    public let readLastOpened: Bool

    public init(environment: ScanEnvironment, policy: SafetyPolicy, roots: [URL]? = nil,
                minimumBytes: Int64 = 100_000_000, readLastOpened: Bool = true) {
        self.environment = environment
        self.policy = policy
        self.roots = roots
        self.minimumBytes = minimumBytes
        self.readLastOpened = readLastOpened
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> LargeFilesResult {
        let home = environment.home.path
        var throttle = ProgressThrottle()
        var found: [UserFileWalk.File] = []
        var foundBytes: Int64 = 0
        var visited = 0

        let walk = UserFileWalk(home: environment.home, roots: roots)
        let summary = try walk.run(onDirectory: { path in
            if let progress, throttle.shouldEmit() {
                progress(ScanProgress(phase: "Looking for large files", currentPath: PathTools.abbreviated(path, home: home),
                                      itemsVisited: visited, bytesSeen: foundBytes))
            }
        }) { file in
            visited += 1
            if file.allocatedBytes >= minimumBytes {
                found.append(file)
                foundBytes += file.allocatedBytes
            }
        }

        let builder = ItemBuilder(policy: policy)
        var files: [LargeFile] = []
        for (index, file) in found.enumerated() {
            try checkCancellation()
            progress?(ScanProgress(phase: "Reading dates", itemsVisited: index, bytesSeen: foundBytes, fraction: Double(index) / Double(max(found.count, 1))))
            let url = URL(filePath: file.path)
            let kind = FileKind.of(fileName: url.lastPathComponent)
            let lastOpened = readLastOpened ? Self.lastOpened(url) : nil
            let measurement = Measurement(allocatedBytes: file.allocatedBytes, logicalBytes: file.logicalBytes, fileCount: 1)
            let item = try builder.make(
                url: url, category: .userFile, name: url.lastPathComponent,
                explanation: Self.explanation(kind: kind, lastOpened: lastOpened, modified: file.modified),
                measurement: measurement, suggested: false
            )
            files.append(LargeFile(item: item, kind: kind, lastOpened: lastOpened, reclaimableBytes: min(PrivateSize.reclaimableBytes(path: file.path), file.allocatedBytes)))
        }
        files.sort { $0.item.bytes > $1.item.bytes }
        return LargeFilesResult(files: files, filesVisited: summary.filesVisited, unreadableFolders: summary.unreadableFolders, datalessSkipped: summary.datalessSkipped)
    }

    /// Files not opened since `date`. When macOS never recorded an open, the change date is used instead.
    public static func notUsed(since date: Date, in files: [LargeFile]) -> [LargeFile] {
        files.filter { file in
            let reference = file.lastOpened ?? file.item.modified ?? .distantPast
            return reference < date
        }
    }

    static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func explanation(kind: FileKind, lastOpened: Date?, modified: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if let lastOpened {
            return "\(kind.singular) · last opened \(formatter.localizedString(for: lastOpened, relativeTo: Date()))"
        }
        return "\(kind.singular) · last changed \(formatter.localizedString(for: modified, relativeTo: Date()))"
    }
}
