import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Sendable, Identifiable, Hashable {
    public var id: String { item.id }
    public let item: FoundItem
    public let modified: Date
    /// Space freed by moving only this copy (APFS clone-aware).
    public let reclaimableBytes: Int64
    /// `true` when this copy shares nearly all its blocks with another (an APFS clone).
    public var sharesStorage: Bool { item.bytes > 0 && reclaimableBytes < item.bytes / 10 }
}

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    /// SHA-256 of the content.
    public let id: String
    /// Length of one copy.
    public let fileSize: Int64
    /// Newest first. `files[0]` is the copy BareMac suggests keeping.
    public let files: [DuplicateFile]

    public var keeper: DuplicateFile { files[0] }
    public var suggestedRemovals: [DuplicateFile] { files.dropFirst().filter(\.item.isSuggested) }
    public var reclaimableBytes: Int64 { suggestedRemovals.reduce(0) { $0 + $1.reclaimableBytes } }
}

public struct DuplicatesResult: Sendable {
    public let groups: [DuplicateGroup]
    public let filesCompared: Int
    public let bytesHashed: Int64
    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
}

/// Byte-identical files: same size, then the same first and last 64 KiB, then the same
/// SHA-256 of the whole content.
public struct DuplicatesScanner: Sendable {
    public let environment: ScanEnvironment
    public let policy: SafetyPolicy
    public let roots: [URL]?
    public let minimumBytes: Int64

    static let partialChunk = 64 * 1024
    static let readChunk = 1024 * 1024

    public init(environment: ScanEnvironment, policy: SafetyPolicy, roots: [URL]? = nil, minimumBytes: Int64 = 1_000_000) {
        self.environment = environment
        self.policy = policy
        self.roots = roots
        self.minimumBytes = minimumBytes
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> DuplicatesResult {
        let home = environment.home.path
        var throttle = ProgressThrottle()
        var bySize: [Int64: [UserFileWalk.File]] = [:]
        var visited = 0

        // 1. Every eligible file, grouped by length.
        try UserFileWalk(home: environment.home, roots: roots).run(onDirectory: { path in
            if let progress, throttle.shouldEmit() {
                progress(ScanProgress(phase: "Finding files", currentPath: PathTools.abbreviated(path, home: home), itemsVisited: visited))
            }
        }) { file in
            visited += 1
            guard file.logicalBytes >= minimumBytes else { return }
            bySize[file.logicalBytes, default: []].append(file)
        }

        // 2. Hard links are one file, not copies.
        var sizeGroups: [[UserFileWalk.File]] = []
        for (_, files) in bySize where files.count > 1 {
            var seen = Set<String>()
            let unique = files.filter { seen.insert("\($0.device):\($0.inode)").inserted }
            if unique.count > 1 { sizeGroups.append(unique) }
        }
        let candidates = sizeGroups.flatMap { $0 }
        let bytesToHash = max(1, candidates.reduce(Int64(0)) { $0 + $1.logicalBytes })
        var bytesHashed: Int64 = 0
        var compared = 0

        func report(_ path: String) {
            if let progress, throttle.shouldEmit() {
                progress(ScanProgress(phase: "Comparing contents", currentPath: PathTools.abbreviated(path, home: home),
                                      itemsVisited: compared, bytesSeen: bytesHashed,
                                      fraction: min(1, Double(bytesHashed) / Double(bytesToHash))))
            }
        }

        // 3. Partial hash, then 4. full hash.
        var identical: [(digest: String, files: [UserFileWalk.File])] = []
        for group in sizeGroups {
            var byPartial: [String: [UserFileWalk.File]] = [:]
            for file in group {
                try checkCancellation()
                compared += 1
                report(file.path)
                guard let digest = try Self.partialHash(file.path, size: file.logicalBytes) else { continue }
                byPartial[digest, default: []].append(file)
            }
            for (_, partialGroup) in byPartial where partialGroup.count > 1 {
                var byFull: [String: [UserFileWalk.File]] = [:]
                for file in partialGroup {
                    guard let digest = try Self.fullHash(file.path, onChunk: { count in
                        bytesHashed += Int64(count)
                        report(file.path)
                    }) else { continue }
                    byFull[digest, default: []].append(file)
                }
                for (digest, files) in byFull where files.count > 1 {
                    identical.append((digest, files))
                }
            }
        }

        // 5. Build groups: newest first; the newest is never suggested.
        let builder = ItemBuilder(policy: policy)
        var groups: [DuplicateGroup] = []
        for (digest, files) in identical {
            try checkCancellation()
            let sorted = files.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
            let others = sorted.count - 1
            var copies: [DuplicateFile] = []
            for (index, file) in sorted.enumerated() {
                let url = URL(filePath: file.path)
                let reclaimable = min(PrivateSize.reclaimableBytes(path: file.path), file.allocatedBytes)
                let clone = file.allocatedBytes > 0 && reclaimable < file.allocatedBytes / 10
                let isKeeper = index == 0
                let item = try builder.make(
                    url: url, category: .userFile, name: url.lastPathComponent,
                    explanation: "Same content as \(others) other \(others == 1 ? "file" : "files")",
                    measurement: Measurement(allocatedBytes: file.allocatedBytes, logicalBytes: file.logicalBytes, fileCount: 1),
                    suggested: !isKeeper && !clone,
                    note: clone && !isKeeper ? "Shares storage with another copy (an APFS clone), so removing it frees almost nothing." : nil
                )
                copies.append(DuplicateFile(item: item, modified: file.modified, reclaimableBytes: reclaimable))
            }
            groups.append(DuplicateGroup(id: digest, fileSize: sorted[0].logicalBytes, files: copies))
        }
        groups.sort { $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes : $0.id < $1.id }
        return DuplicatesResult(groups: groups, filesCompared: compared, bytesHashed: bytesHashed)
    }

    // MARK: Hashing (never follows symlinks; never opens cloud-only files — the walk skips them)

    static func partialHash(_ path: String, size: Int64) throws -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: partialChunk)
        let headCount = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, partialChunk, 0) }
        guard headCount >= 0 else { return nil }
        hasher.update(data: buffer.prefix(headCount))
        if size > Int64(partialChunk * 2) {
            let tailCount = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, partialChunk, off_t(size) - off_t(partialChunk)) }
            guard tailCount >= 0 else { return nil }
            hasher.update(data: buffer.prefix(tailCount))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String, onChunk: (Int) -> Void) throws -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: readChunk)
        while true {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, readChunk) }
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(data: buffer.prefix(count))
            onChunk(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
