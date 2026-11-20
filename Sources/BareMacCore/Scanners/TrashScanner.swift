import Foundation

public struct TrashResult: Sendable {
    /// `false` when macOS hides the Trash (BareMac has no Full Disk Access).
    public let isReadable: Bool
    /// Information only: BareMac never empties the Trash.
    public let items: [FoundItem]
    public let total: Measurement
    /// Items BareMac moved to the Trash that are still there and not restored.
    public let movedByBareMac: [ActionRecord]
    public var movedByBareMacBytes: Int64 { movedByBareMac.reduce(0) { $0 + $1.bytes } }
}

/// What the Trash holds. View only.
public struct TrashScanner: Sendable {
    public let environment: ScanEnvironment
    public let log: ActionLog?

    public static let infoReason = "BareMac never empties the Trash. Empty it in Finder when you're ready."

    public init(environment: ScanEnvironment, log: ActionLog?) {
        self.environment = environment
        self.log = log
    }

    @concurrent public func scan(progress: ProgressHandler? = nil) async throws -> TrashResult {
        let trash = environment.paths.trash
        let home = environment.home.path
        var throttle = ProgressThrottle()
        var items: [FoundItem] = []
        var total = Measurement()

        let isReadable = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil
        if isReadable {
            let urls = DirectoryListing.of(trash, includeHidden: true).urls.filter { $0.lastPathComponent != ".DS_Store" }
            for (index, url) in urls.enumerated() {
                try checkCancellation()
                if let progress, throttle.shouldEmit() {
                    progress(ScanProgress(phase: "Measuring the Trash", currentPath: PathTools.abbreviated(url.path, home: home),
                                          itemsVisited: index, bytesSeen: total.allocatedBytes, fraction: Double(index) / Double(max(urls.count, 1))))
                }
                let measurement = try DiskMeasurer.measureForScan(url)
                total += measurement
                items.append(FoundItem(
                    url: url, category: .informationOnly, name: url.lastPathComponent, explanation: "In the Trash",
                    measurement: measurement, modified: fileStatus(url.path)?.modificationDate,
                    isCleanable: false, infoReason: Self.infoReason
                ))
            }
        }
        items.sort { $0.bytes > $1.bytes }

        var moved: [ActionRecord] = []
        if let log, let records = try? log.records() {
            let restored = Set(records.filter { $0.kind == .restored }.compactMap(\.relatedRecordID))
            moved = records.filter { record in
                guard record.kind == .trashed, !restored.contains(record.id), let path = record.trashedPath else { return false }
                return FileEngine.isInsideATrash(path) && fileStatus(path) != nil
            }
            .sorted { $0.date > $1.date }
        }
        return TrashResult(isReadable: isReadable, items: items, total: total, movedByBareMac: moved)
    }
}
