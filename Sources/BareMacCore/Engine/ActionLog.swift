import Foundation

/// One line in BareMac's action log: what happened, to what, where, when, and how
/// many bytes.
public struct ActionRecord: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// An item was moved to the Trash.
        case trashed
        /// An item was moved back from the Trash to where it was.
        case restored
        /// A background item was turned off with `launchctl`.
        case startupItemTurnedOff
        /// A background item was turned back on with `launchctl`.
        case startupItemTurnedOn
    }

    public let id: UUID
    public let batchID: UUID
    public let date: Date
    public let kind: Kind
    /// The module that did it, for example "System Junk".
    public let origin: String
    /// `CleanCategory.rawValue`, or "startupItem".
    public let category: String
    public let label: String
    public let originalPath: String
    public let trashedPath: String?
    public let bytes: Int64
    public let fileCount: Int
    /// For `.restored`, the `.trashed` record it undid.
    public let relatedRecordID: UUID?

    public init(
        id: UUID = UUID(), batchID: UUID, date: Date = Date(), kind: Kind, origin: String, category: String,
        label: String, originalPath: String, trashedPath: String?, bytes: Int64, fileCount: Int, relatedRecordID: UUID? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.date = date
        self.kind = kind
        self.origin = origin
        self.category = category
        self.label = label
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.bytes = bytes
        self.fileCount = fileCount
        self.relatedRecordID = relatedRecordID
    }
}

/// An append-only JSON Lines file: one `ActionRecord` per line, flushed to disk
/// after every write. It lives at
/// `~/Library/Application Support/BareMac/action-log.jsonl` and is plain text, so
/// anyone can read exactly what BareMac did. Lines are never rewritten or removed.
public struct ActionLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL(home: URL) -> URL {
        LibraryPaths(home: home).bareMacSupport.appending(path: "action-log.jsonl")
    }

    private static let lock = NSLock()

    /// Appends records and forces them to disk before returning.
    public func append(_ records: [ActionRecord]) throws {
        guard !records.isEmpty else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func append(_ record: ActionRecord) throws {
        try append([record])
    }

    /// Every record, oldest first. Lines that can't be read are skipped, never rewritten.
    public func records() throws -> [ActionRecord] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(ActionRecord.self, from: line)
        }
    }

    /// IDs of `.trashed` records that have already been restored.
    public func restoredRecordIDs() throws -> Set<UUID> {
        Set(try records().filter { $0.kind == .restored }.compactMap(\.relatedRecordID))
    }
}
