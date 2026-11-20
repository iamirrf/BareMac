import BareMacCore
import Foundation
import Observation

/// Shared "which items will move" logic. Only cleanable items can ever be checked.
@MainActor
protocol Checklist: AnyObject {
    var checked: Set<String> { get set }
}

extension Checklist {
    func isChecked(_ item: FoundItem) -> Bool { item.isCleanable && checked.contains(item.id) }

    func toggle(_ item: FoundItem) {
        guard item.isCleanable else { return }
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    func set(_ items: [FoundItem], to isOn: Bool) {
        for item in items where item.isCleanable {
            if isOn { checked.insert(item.id) } else { checked.remove(item.id) }
        }
    }

    /// `true` all checked, `false` none, `nil` some.
    func state(of items: [FoundItem]) -> Bool? {
        let cleanable = items.filter(\.isCleanable)
        guard !cleanable.isEmpty else { return false }
        let count = cleanable.filter { checked.contains($0.id) }.count
        if count == 0 { return false }
        return count == cleanable.count ? true : nil
    }

    func checkSuggested(in items: [FoundItem]) {
        checked = Set(items.filter(\.isSuggested).map(\.id))
    }
}

// MARK: - System Junk

@MainActor @Observable
final class SystemJunkStore: Checklist {
    let task = ScanTask<SystemJunkResult>()
    var checked: Set<String> = []

    var result: SystemJunkResult? { task.value }
    var items: [FoundItem] { result?.allItems ?? [] }
    var checkedItems: [FoundItem] { items.filter { isChecked($0) } }
    var checkedBytes: Int64 { checkedItems.totalBytes }

    func scan(_ context: ScanContext) {
        let scanner = SystemJunkScanner(
            environment: context.environment, policy: context.policy, inventory: context.inventory,
            runningBundleIdentifiers: context.runningApps, hasFullDiskAccess: context.hasFullDiskAccess
        )
        task.run({ progress in try await scanner.scan(progress: progress) }) { [weak self] result in
            self?.checkSuggested(in: result.allItems)
        }
    }

    func request() -> CleanRequest {
        CleanRequest(origin: Module.systemJunk.title, entries: checkedItems.map(CleanRequest.Entry.init))
    }
}

// MARK: - App Leftovers

@MainActor @Observable
final class LeftoversStore: Checklist {
    let task = ScanTask<LeftoversResult>()
    var checked: Set<String> = []
    var expanded: Set<String> = []

    var result: LeftoversResult? { task.value }
    var items: [FoundItem] { result?.groups.flatMap(\.items) ?? [] }
    var checkedItems: [FoundItem] { items.filter { isChecked($0) } }
    var checkedBytes: Int64 { checkedItems.totalBytes }

    func scan(_ context: ScanContext) {
        guard let inventory = context.inventory else { return }
        let scanner = LeftoversScanner(
            environment: context.environment, policy: context.policy, inventory: inventory,
            hasFullDiskAccess: context.hasFullDiskAccess
        )
        task.run({ progress in try await scanner.scan(progress: progress) }) { [weak self] result in
            self?.checkSuggested(in: result.groups.flatMap(\.items))
        }
    }

    func request() -> CleanRequest {
        CleanRequest(origin: Module.leftovers.title, entries: checkedItems.map(CleanRequest.Entry.init))
    }
}

// MARK: - Uninstaller

@MainActor @Observable
final class UninstallerStore: Checklist {
    let footprint = ScanTask<AppFootprint>()
    var checked: Set<String> = []
    var search = ""
    private(set) var selectedAppID: String?

    var result: AppFootprint? { footprint.value }
    var items: [FoundItem] { result?.allItems ?? [] }
    var checkedItems: [FoundItem] { items.filter { isChecked($0) } }
    var checkedBytes: Int64 { checkedItems.totalBytes }

    func apps(_ context: ScanContext) -> [InstalledApp] {
        guard let inventory = context.inventory else { return [] }
        let all = AppFootprintScanner(environment: context.environment, policy: context.policy, inventory: inventory).uninstallableApps()
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query) }
    }

    func select(_ app: InstalledApp, context: ScanContext) {
        guard let inventory = context.inventory else { return }
        selectedAppID = app.id
        checked = []
        footprint.reset()
        let scanner = AppFootprintScanner(
            environment: context.environment, policy: context.policy, inventory: inventory,
            runningBundleIdentifiers: context.runningApps, hasFullDiskAccess: context.hasFullDiskAccess
        )
        footprint.run({ progress in try await scanner.footprint(of: app, progress: progress) }) { [weak self] result in
            self?.checkSuggested(in: result.allItems)
        }
    }

    func rescan(_ context: ScanContext) {
        guard let id = selectedAppID, let app = context.inventory?.apps.first(where: { $0.id == id }) else {
            clearSelection()
            return
        }
        select(app, context: context)
    }

    func clearSelection() {
        selectedAppID = nil
        checked = []
        footprint.reset()
    }

    func request() -> CleanRequest {
        CleanRequest(origin: Module.uninstaller.title, entries: checkedItems.map(CleanRequest.Entry.init))
    }
}

// MARK: - Large & Old Files

@MainActor @Observable
final class LargeFilesStore: Checklist {
    let task = ScanTask<LargeFilesResult>()
    var checked: Set<String> = []
    var minimumMB: Int = LargeFilesStore.savedMinimum {
        didSet { UserDefaults.standard.set(minimumMB, forKey: Self.minimumKey) }
    }
    /// 0 = any time.
    var notUsedMonths = 0
    var kind: FileKind?

    static let minimumKey = "largeFiles.minimumMB"
    static var savedMinimum: Int {
        let value = UserDefaults.standard.integer(forKey: minimumKey)
        return value > 0 ? value : 100
    }
    static let thresholds = [50, 100, 250, 500, 1_000, 5_000]

    var result: LargeFilesResult? { task.value }
    /// The minimum the last scan used, so the header can say what was searched.
    private(set) var scannedMinimumMB: Int?

    var visibleFiles: [LargeFile] {
        var files = result?.files ?? []
        if let kind { files = files.filter { $0.kind == kind } }
        if notUsedMonths > 0, let cutoff = Calendar.current.date(byAdding: .month, value: -notUsedMonths, to: Date()) {
            files = LargeFilesScanner.notUsed(since: cutoff, in: files)
        }
        return files
    }

    var checkedItems: [FoundItem] { visibleFiles.map(\.item).filter { isChecked($0) } }
    var checkedBytes: Int64 { checkedItems.totalBytes }

    func scan(_ context: ScanContext) {
        let minimum = minimumMB
        let scanner = LargeFilesScanner(
            environment: context.environment, policy: context.policy,
            minimumBytes: Int64(minimum) * 1_000_000, readLastOpened: true
        )
        task.run({ progress in try await scanner.scan(progress: progress) }) { [weak self] _ in
            self?.checked = []
            self?.scannedMinimumMB = minimum
        }
    }

    func request() -> CleanRequest {
        CleanRequest(origin: Module.largeFiles.title, entries: checkedItems.map(CleanRequest.Entry.init))
    }
}

// MARK: - Duplicates

@MainActor @Observable
final class DuplicatesStore: Checklist {
    let task = ScanTask<DuplicatesResult>()
    var checked: Set<String> = []
    var minimumKB: Int = DuplicatesStore.savedMinimum {
        didSet { UserDefaults.standard.set(minimumKB, forKey: Self.minimumKey) }
    }

    static let minimumKey = "duplicates.minimumKB"
    static var savedMinimum: Int {
        let value = UserDefaults.standard.integer(forKey: minimumKey)
        return value > 0 ? value : 1_000
    }
    static let thresholds = [100, 1_000, 10_000, 100_000]

    var result: DuplicatesResult? { task.value }
    var groups: [DuplicateGroup] { result?.groups ?? [] }
    var checkedItems: [FoundItem] { groups.flatMap(\.files).map(\.item).filter { isChecked($0) } }
    var checkedBytes: Int64 { checkedItems.totalBytes }
    var suggestedIDs: Set<String> { Set(groups.flatMap(\.suggestedRemovals).map(\.id)) }

    func scan(_ context: ScanContext) {
        let scanner = DuplicatesScanner(
            environment: context.environment, policy: context.policy,
            minimumBytes: Int64(minimumKB) * 1_000
        )
        task.run({ progress in try await scanner.scan(progress: progress) }) { [weak self] _ in
            guard let self else { return }
            self.checked = self.suggestedIDs
        }
    }

    /// A copy can be checked only while at least one other copy in its group stays unchecked.
    func canCheck(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        guard file.item.isCleanable else { return false }
        if checked.contains(file.id) { return true }
        return group.files.filter { !checked.contains($0.id) }.count > 1
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if checked.contains(file.id) {
            checked.remove(file.id)
        } else if canCheck(file, in: group) {
            checked.insert(file.id)
        }
    }

    func selectSuggested() { checked = suggestedIDs }
    func deselectAll() { checked = [] }

    func request() -> CleanRequest {
        let touched = groups.filter { group in group.files.contains { checked.contains($0.id) } }
        return CleanRequest(
            origin: Module.duplicates.title,
            entries: checkedItems.map(CleanRequest.Entry.init),
            duplicateGroups: touched.map { $0.files.map(\.item.url) }
        )
    }
}

// MARK: - Trash

@MainActor @Observable
final class TrashStore {
    let task = ScanTask<TrashResult>()
    var result: TrashResult? { task.value }

    func scan(_ context: ScanContext) {
        let scanner = TrashScanner(environment: context.environment, log: context.log)
        task.run { progress in try await scanner.scan(progress: progress) }
    }
}

// MARK: - Startup Items

@MainActor @Observable
final class StartupStore {
    let task = ScanTask<StartupItemsResult>()
    var errorMessage: String?
    private(set) var busy: Set<String> = []
    /// Waiting for the user to confirm turning this off.
    var pendingTurnOff: StartupItem?

    var result: StartupItemsResult? { task.value }

    func scan(_ context: ScanContext) {
        let scanner = StartupItemsScanner(environment: context.environment, inventory: context.inventory, launchControl: SystemLaunchControl())
        task.run { _ in try await scanner.scan() }
    }

    func setEnabled(_ item: StartupItem, _ isOn: Bool, context: ScanContext, then: @escaping @MainActor () -> Void) {
        guard item.canToggle, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        let controller = StartupController(launchControl: SystemLaunchControl(), log: context.log)
        Task {
            do {
                _ = try await Task.detached {
                    try isOn ? controller.turnOn(item) : controller.turnOff(item)
                }.value
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.busy.remove(item.id)
            self.scan(context)
            then()
        }
    }
}

// MARK: - Space Map

@MainActor @Observable
final class SpaceMapStore {
    let task = ScanTask<SpaceNode>()
    /// The folder to map; `nil` means the home folder.
    var root: URL?
    /// Drill-down path; the first element is the scanned root.
    private(set) var path: [SpaceNode] = []
    var hoveredID: String?

    var current: SpaceNode? { path.last ?? task.value }

    func scan(_ context: ScanContext) {
        let folder = root ?? context.environment.home
        let scanner = SpaceMapScanner(root: folder)
        task.run({ progress in try await scanner.scan(progress: progress) }) { [weak self] node in
            self?.path = [node]
        }
    }

    func open(_ node: SpaceNode) {
        guard node.isDirectory, !node.isPackage, !node.children.isEmpty else { return }
        path.append(node)
    }

    func go(to index: Int) {
        guard path.indices.contains(index) else { return }
        path = Array(path.prefix(index + 1))
    }

    func goUp() {
        if path.count > 1 { path.removeLast() }
    }
}

// MARK: - History

@MainActor @Observable
final class HistoryStore {
    struct Batch: Identifiable, Hashable {
        let id: UUID
        let date: Date
        let origin: String
        let kind: ActionRecord.Kind
        let records: [ActionRecord]
        var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    }

    enum RecordStatus {
        case inTrash, restored, gone, startupChange
    }

    private(set) var records: [ActionRecord] = []
    private(set) var restoredIDs: Set<UUID> = []
    var errorMessage: String?

    func reload(log: ActionLog) {
        do {
            records = try log.records()
            restoredIDs = Set(records.filter { $0.kind == .restored }.compactMap(\.relatedRecordID))
        } catch {
            errorMessage = "BareMac couldn't read its action log: \(error.localizedDescription)"
        }
    }

    /// Batches of moves and startup changes, newest first. Restores show up as a status.
    var batches: [Batch] {
        let grouped = Dictionary(grouping: records.filter { $0.kind != .restored }, by: \.batchID)
        return grouped.map { id, records in
            let sorted = records.sorted { $0.date < $1.date }
            return Batch(id: id, date: sorted.first?.date ?? .distantPast, origin: sorted.first?.origin ?? "", kind: sorted.first?.kind ?? .trashed, records: sorted)
        }
        .sorted { $0.date > $1.date }
    }

    func status(of record: ActionRecord) -> RecordStatus {
        guard record.kind == .trashed else { return .startupChange }
        if restoredIDs.contains(record.id) { return .restored }
        guard let trashed = record.trashedPath else { return .gone }
        return (try? FileManager.default.attributesOfItem(atPath: trashed)) != nil ? .inTrash : .gone
    }

    func restorable(in batch: Batch) -> [ActionRecord] {
        batch.records.filter { status(of: $0) == .inTrash }
    }
}
