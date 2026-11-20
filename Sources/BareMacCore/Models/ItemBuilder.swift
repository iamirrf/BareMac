import Foundation

/// The one way scanners turn a path into a `FoundItem`.
///
/// It measures the item (unless the scanner already measured it), then decides
/// whether it may be offered for cleaning:
/// - the allowlist (`SafetyPolicy`) must accept the path for its category, and
/// - every file inside must have been readable, so the size is exact.
/// If either fails, the item is still shown — with its measured size and the
/// reason — but it is information only and can never be selected.
public struct ItemBuilder: Sendable {
    public let policy: SafetyPolicy

    public init(policy: SafetyPolicy) {
        self.policy = policy
    }

    public static let incompleteReason = "Some files inside can't be read, so BareMac can't measure it exactly and won't offer to move it."

    /// Measures `url` and builds the item. Throws `ScanError.cancelled` when the task is cancelled.
    public func make(
        url: URL,
        category: CleanCategory,
        name: String,
        explanation: String,
        owner: AppRef? = nil,
        measurement: Measurement? = nil,
        suggested: Bool = false,
        note: String? = nil,
        infoReason: String? = nil
    ) throws -> FoundItem {
        let measured: Measurement
        if let measurement {
            measured = measurement
        } else {
            do {
                measured = try DiskMeasurer.measure(url, isCancelled: { Task.isCancelled })
            } catch is DiskMeasurer.Cancelled {
                throw ScanError.cancelled
            }
        }
        var reason = infoReason
        if reason == nil {
            let verdict = policy.evaluate(url, as: category)
            if !verdict.isAllowed { reason = verdict.reason }
        }
        if reason == nil, !measured.isComplete {
            reason = Self.incompleteReason
        }
        return FoundItem(
            url: url,
            category: category,
            name: name,
            explanation: explanation,
            owner: owner,
            measurement: measured,
            modified: fileStatus(url.path)?.modificationDate,
            isCleanable: reason == nil,
            infoReason: reason,
            isSuggested: suggested && reason == nil,
            note: note
        )
    }
}

extension DiskMeasurer {
    /// `measure`, translating cancellation into `ScanError.cancelled`.
    public static func measureForScan(_ url: URL) throws -> Measurement {
        do {
            return try measure(url, isCancelled: { Task.isCancelled })
        } catch is Cancelled {
            throw ScanError.cancelled
        }
    }
}
