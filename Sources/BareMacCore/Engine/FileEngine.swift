import Darwin
import Foundation

// The file engine is the only code in BareMac that moves files. It has exactly two
// operations: move to the Trash, and move back out of the Trash. There is no delete,
// and nothing here (or anywhere else in BareMac) empties the Trash.

/// Something that can move an item to a trash and report where it went.
public protocol Trasher: Sendable {
    /// Moves the item to a trash and returns its new location. Must never delete.
    func moveToTrash(_ url: URL) throws -> URL
}

/// The real macOS Trash, through `FileManager.trashItem(at:resultingItemURL:)`.
public struct SystemTrash: Trasher {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let destination = resulting as URL? else {
            throw FileEngine.EngineError.trashUnavailable(url.path)
        }
        return destination
    }
}

/// What the user wants to move, before BareMac has checked or measured it.
public struct CleanRequest: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let category: CleanCategory
        public let label: String

        public init(url: URL, category: CleanCategory, label: String) {
            self.url = url
            self.category = category
            self.label = label
        }

        public init(_ item: FoundItem) {
            self.init(url: item.url, category: item.category, label: item.name)
        }
    }

    public var origin: String
    public var entries: [Entry]
    /// Groups of identical files. At least one member of every group must stay.
    public var duplicateGroups: [[URL]]

    public init(origin: String, entries: [Entry], duplicateGroups: [[URL]] = []) {
        self.origin = origin
        self.entries = entries
        self.duplicateGroups = duplicateGroups
    }
}

/// The exact list the user confirms. Every size in it was measured just now.
public struct CleanPreview: Sendable, Identifiable {
    public struct Line: Sendable, Identifiable, Hashable {
        public var id: String { entry.id }
        public let entry: CleanRequest.Entry
        public let measurement: Measurement
    }

    public struct Rejection: Sendable, Identifiable, Hashable {
        public var id: String { entry.id }
        public let entry: CleanRequest.Entry
        public let reason: String
    }

    public let id: UUID
    public let origin: String
    public let createdAt: Date
    public let lines: [Line]
    public let rejections: [Rejection]
    let duplicateGroups: [[String]]

    public var totalBytes: Int64 { lines.reduce(0) { $0 + $1.measurement.allocatedBytes } }
    public var fileCount: Int { lines.reduce(0) { $0 + $1.measurement.fileCount } }
    public var isEmpty: Bool { lines.isEmpty }
}

/// What happened after the user confirmed.
public struct CleanReport: Sendable {
    public struct Moved: Sendable, Identifiable, Hashable {
        public var id: UUID { record.id }
        public let record: ActionRecord
    }

    public struct Failure: Sendable, Identifiable, Hashable {
        public var id: String { entry.id }
        public let entry: CleanRequest.Entry
        public let reason: String
    }

    public let batchID: UUID
    public let moved: [Moved]
    public let failures: [Failure]

    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.record.bytes } }
}

/// What happened when restoring from the Trash.
public struct RestoreReport: Sendable {
    public let restored: [ActionRecord]
    public let failures: [(record: ActionRecord, reason: String)]
}

/// Moves items to the Trash — only after an allowlist check, a fresh measurement and
/// the user's confirmation of the exact list — and logs every move.
public actor FileEngine {
    public enum EngineError: Error, LocalizedError, Equatable {
        case previewNotFound
        case trashUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .previewNotFound:
                "Nothing was moved: BareMac only acts on a list you've just reviewed. Please review it again."
            case let .trashUnavailable(path):
                "macOS couldn't put “\((path as NSString).lastPathComponent)” in the Trash."
            }
        }
    }

    public nonisolated let policy: SafetyPolicy
    public nonisolated let log: ActionLog
    private let trasher: any Trasher
    private var pendingPreviews: [UUID: CleanPreview] = [:]

    public init(policy: SafetyPolicy, trasher: any Trasher = SystemTrash(), log: ActionLog) {
        self.policy = policy
        self.trasher = trasher
        self.log = log
    }

    // MARK: Preview

    /// Checks every entry against the allowlist, measures what passes, and returns
    /// the exact list to show the user. Nothing moves here.
    public func preview(_ request: CleanRequest) -> CleanPreview {
        var rejections: [CleanPreview.Rejection] = []
        var accepted: [CleanRequest.Entry] = []

        // 1. Drop exact repeats and anything already inside another selected folder.
        var seen = Set<String>()
        let unique = request.entries.filter { seen.insert($0.url.path).inserted }
        let selectedPaths = unique.map(\.url.path)
        for entry in unique {
            if let parent = selectedPaths.first(where: { PathTools.isStrictlyInside(entry.url.path, $0) }) {
                let name = (parent as NSString).lastPathComponent
                rejections.append(.init(entry: entry, reason: "Already included with “\(name)”."))
                continue
            }
            accepted.append(entry)
        }

        // 2. Never let every copy of a duplicate go.
        let groups = request.duplicateGroups.map { $0.map(\.path) }
        let selected = Set(accepted.map(\.url.path))
        var blocked = Set<String>()
        for group in groups {
            let staying = group.filter { !selected.contains($0) && fileStatus($0) != nil }
            if staying.isEmpty { blocked.formUnion(group) }
        }
        accepted = accepted.filter { entry in
            guard blocked.contains(entry.url.path) else { return true }
            rejections.append(.init(entry: entry, reason: "At least one copy must stay, so BareMac kept this group untouched."))
            return false
        }

        // 3. Allowlist, then a fresh measurement.
        var lines: [CleanPreview.Line] = []
        for entry in accepted {
            let verdict = policy.evaluate(entry.url, as: entry.category)
            guard verdict.isAllowed else {
                rejections.append(.init(entry: entry, reason: verdict.reason ?? "Not allowed."))
                continue
            }
            let measurement = (try? DiskMeasurer.measure(entry.url)) ?? Measurement(unreadableCount: 1)
            guard measurement.isComplete else {
                rejections.append(.init(entry: entry, reason: "Some files inside can't be read, so BareMac can't measure it exactly and won't move it."))
                continue
            }
            lines.append(.init(entry: entry, measurement: measurement))
        }

        let preview = CleanPreview(
            id: UUID(), origin: request.origin, createdAt: Date(), lines: lines,
            rejections: rejections, duplicateGroups: groups
        )
        pendingPreviews[preview.id] = preview
        return preview
    }

    /// Forgets a preview the user cancelled.
    public func discard(_ previewID: UUID) {
        pendingPreviews[previewID] = nil
    }

    // MARK: Execute

    /// Moves the confirmed items to the Trash. Only a preview this engine issued, and
    /// that hasn't been used yet, is accepted. Every item is checked against the
    /// allowlist again right before it moves.
    public func execute(_ previewID: UUID, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> CleanReport {
        guard let preview = pendingPreviews.removeValue(forKey: previewID) else {
            throw EngineError.previewNotFound
        }
        let batchID = UUID()
        var moved: [CleanReport.Moved] = []
        var failures: [CleanReport.Failure] = []
        let movingPaths = Set(preview.lines.map(\.entry.url.path))

        for (index, line) in preview.lines.enumerated() {
            progress?(index, preview.lines.count)
            let entry = line.entry

            let verdict = policy.evaluate(entry.url, as: entry.category)
            guard verdict.isAllowed else {
                failures.append(.init(entry: entry, reason: verdict.reason ?? "Not allowed."))
                continue
            }
            if let group = preview.duplicateGroups.first(where: { $0.contains(entry.url.path) }) {
                let staying = group.filter { !movingPaths.contains($0) && fileStatus($0) != nil }
                guard !staying.isEmpty else {
                    failures.append(.init(entry: entry, reason: "No other copy is left, so BareMac kept this one."))
                    continue
                }
            }

            do {
                let destination = try trasher.moveToTrash(entry.url)
                let record = ActionRecord(
                    batchID: batchID, kind: .trashed, origin: preview.origin, category: entry.category.rawValue,
                    label: entry.label, originalPath: entry.url.path, trashedPath: destination.path,
                    bytes: line.measurement.allocatedBytes, fileCount: line.measurement.fileCount
                )
                try log.append(record)
                moved.append(.init(record: record))
            } catch {
                failures.append(.init(entry: entry, reason: Self.plainReason(for: error)))
            }
        }
        progress?(preview.lines.count, preview.lines.count)
        return CleanReport(batchID: batchID, moved: moved, failures: failures)
    }

    // MARK: Restore

    /// Moves items back from the Trash to where they were. Never overwrites anything.
    public func restore(_ records: [ActionRecord]) -> RestoreReport {
        let alreadyRestored = (try? log.restoredRecordIDs()) ?? []
        let batchID = UUID()
        var restored: [ActionRecord] = []
        var failures: [(ActionRecord, String)] = []
        let manager = FileManager.default

        for record in records {
            guard record.kind == .trashed, let trashedPath = record.trashedPath else {
                failures.append((record, "Only items BareMac moved to the Trash can be restored."))
                continue
            }
            guard !alreadyRestored.contains(record.id) else {
                failures.append((record, "Already restored."))
                continue
            }
            guard Self.isInsideATrash(trashedPath) else {
                failures.append((record, "That item isn't in a Trash folder."))
                continue
            }
            guard fileStatus(trashedPath) != nil else {
                failures.append((record, "It's no longer in the Trash. If the Trash was emptied, it can't come back."))
                continue
            }
            guard fileStatus(record.originalPath) == nil else {
                failures.append((record, "Something new is already at the original location, so BareMac won't overwrite it."))
                continue
            }
            do {
                let original = URL(filePath: record.originalPath)
                try manager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: URL(filePath: trashedPath), to: original)
                let undo = ActionRecord(
                    batchID: batchID, kind: .restored, origin: record.origin, category: record.category,
                    label: record.label, originalPath: record.originalPath, trashedPath: trashedPath,
                    bytes: record.bytes, fileCount: record.fileCount, relatedRecordID: record.id
                )
                try log.append(undo)
                restored.append(undo)
            } catch {
                failures.append((record, Self.plainReason(for: error)))
            }
        }
        return RestoreReport(restored: restored, failures: failures)
    }

    // MARK: Helpers

    /// `true` for paths inside `~/.Trash` or a volume's `.Trashes` folder.
    public static func isInsideATrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    static func plainReason(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "macOS didn't allow BareMac to move it. If it's an app, allow BareMac under System Settings › Privacy & Security › App Management."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "It's no longer there."
            case NSFileWriteFileExistsError:
                return "Something with the same name is already there."
            default:
                break
            }
        }
        if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EPERM) || posix.code == Int(EACCES)
        {
            return "macOS didn't allow BareMac to move it. If it's an app, allow BareMac under System Settings › Privacy & Security › App Management."
        }
        return error.localizedDescription
    }
}
