import BareMacCore
import Foundation
import Observation

/// The app's single source of truth. Every number it publishes was measured.
@MainActor @Observable
final class AppModel {
    let environment: ScanEnvironment
    let policy: SafetyPolicy
    let log: ActionLog
    let engine: FileEngine

    var selection: Module = .overview
    private(set) var hasFullDiskAccess = false
    private(set) var disk: DiskSnapshot?
    private(set) var runningApps: Set<String> = []
    /// A short message shown after restoring, for example "Put back 3 items."
    var notice: String?

    let inventory = ScanTask<AppInventory>()
    let junk = SystemJunkStore()
    let leftovers = LeftoversStore()
    let uninstaller = UninstallerStore()
    let largeFiles = LargeFilesStore()
    let duplicates = DuplicatesStore()
    let trash = TrashStore()
    let startup = StartupStore()
    let spaceMap = SpaceMapStore()
    let history = HistoryStore()
    let clean = CleanCoordinator()

    @ObservationIgnored private var started = false

    convenience init() {
        #if DEBUG
        self.init(environment: DebugModes.environment())
        #else
        self.init(environment: .live())
        #endif
    }

    init(environment: ScanEnvironment) {
        self.environment = environment
        policy = SafetyPolicy(environment: environment)
        log = ActionLog(fileURL: ActionLog.defaultURL(home: environment.home))
        engine = FileEngine(policy: policy, log: log)
    }

    var context: ScanContext {
        ScanContext(
            environment: environment, policy: policy, inventory: inventory.value,
            runningApps: runningApps, hasFullDiskAccess: hasFullDiskAccess, log: log
        )
    }

    // MARK: Lifecycle

    /// First launch: measure the disk, then run the quick, read-only scans.
    func start() async {
        guard !started else { return }
        started = true
        refreshDisk()
        refreshPermissions()
        history.reload(log: log)
        await refreshRunningApps()
        loadInventory { [weak self] in self?.scanQuickModules() }
    }

    /// Coming back to BareMac (for example from System Settings) re-checks permissions.
    func didBecomeActive() {
        guard started else { return }
        let hadAccess = hasFullDiskAccess
        refreshPermissions()
        refreshDisk()
        if hasFullDiskAccess != hadAccess {
            scanQuickModules()
        }
    }

    func refreshDisk() {
        disk = try? DiskSnapshot.current(for: environment.home)
    }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess(home: environment.home)
    }

    func refreshRunningApps() async {
        runningApps = await Task.detached { RunningApps.bundleIdentifiers() }.value
    }

    func loadInventory(then: (@MainActor () -> Void)? = nil) {
        let environment = environment
        inventory.run({ _ in AppInventory.scan(environment: environment) }) { _ in then?() }
    }

    private func scanQuickModules() {
        junk.scan(context)
        leftovers.scan(context)
        trash.scan(context)
        startup.scan(context)
    }

    // MARK: Scanning

    func scan(_ module: Module) {
        switch module {
        case .overview:
            refreshDisk()
            refreshPermissions()
            Task {
                await refreshRunningApps()
                loadInventory { [weak self] in self?.scanQuickModules() }
            }
        case .systemJunk:
            Task {
                await refreshRunningApps()
                junk.scan(context)
            }
        case .leftovers:
            loadInventory { [weak self] in
                guard let self else { return }
                self.leftovers.scan(self.context)
            }
        case .trash:
            trash.scan(context)
        case .uninstaller:
            Task {
                await refreshRunningApps()
                loadInventory { [weak self] in
                    guard let self, self.uninstaller.selectedAppID != nil else { return }
                    self.uninstaller.rescan(self.context)
                }
            }
        case .startupItems:
            startup.scan(context)
        case .largeFiles:
            largeFiles.scan(context)
        case .duplicates:
            duplicates.scan(context)
        case .spaceMap:
            spaceMap.scan(context)
        case .history:
            history.reload(log: log)
        }
    }

    func stop(_ module: Module) {
        switch module {
        case .overview: inventory.cancel(); junk.task.cancel(); leftovers.task.cancel(); trash.task.cancel()
        case .systemJunk: junk.task.cancel()
        case .leftovers: leftovers.task.cancel()
        case .trash: trash.task.cancel()
        case .uninstaller: uninstaller.footprint.cancel()
        case .startupItems: startup.task.cancel()
        case .largeFiles: largeFiles.task.cancel()
        case .duplicates: duplicates.task.cancel()
        case .spaceMap: spaceMap.task.cancel()
        case .history: break
        }
    }

    func isScanning(_ module: Module) -> Bool {
        switch module {
        case .overview: inventory.isRunning || junk.task.isRunning || leftovers.task.isRunning || trash.task.isRunning
        case .systemJunk: junk.task.isRunning
        case .leftovers: leftovers.task.isRunning || (inventory.isRunning && leftovers.task.value == nil)
        case .trash: trash.task.isRunning
        case .uninstaller: uninstaller.footprint.isRunning || inventory.isRunning
        case .startupItems: startup.task.isRunning
        case .largeFiles: largeFiles.task.isRunning
        case .duplicates: duplicates.task.isRunning
        case .spaceMap: spaceMap.task.isRunning
        case .history: false
        }
    }

    // MARK: Cleaning

    func checked(for module: Module) -> (count: Int, bytes: Int64) {
        switch module {
        case .systemJunk: (junk.checkedItems.count, junk.checkedBytes)
        case .leftovers: (leftovers.checkedItems.count, leftovers.checkedBytes)
        case .uninstaller: (uninstaller.checkedItems.count, uninstaller.checkedBytes)
        case .largeFiles: (largeFiles.checkedItems.count, largeFiles.checkedBytes)
        case .duplicates: (duplicates.checkedItems.count, duplicates.checkedBytes)
        default: (0, 0)
        }
    }

    func canClean(_ module: Module) -> Bool {
        module.canClean && checked(for: module).count > 0 && !clean.isPresentingSheet && !isScanning(module)
    }

    /// Opens the confirmation sheet with the exact, freshly measured list.
    func requestClean(_ module: Module) {
        guard canClean(module) else { return }
        let request: CleanRequest
        switch module {
        case .systemJunk: request = junk.request()
        case .leftovers: request = leftovers.request()
        case .uninstaller: request = uninstaller.request()
        case .largeFiles: request = largeFiles.request()
        case .duplicates: request = duplicates.request()
        default: return
        }
        clean.begin(request, from: module, engine: engine) { [weak self] report in
            self?.didClean(report, in: module)
        }
    }

    private func didClean(_ report: CleanReport, in module: Module) {
        history.reload(log: log)
        refreshDisk()
        trash.scan(context)
        switch module {
        case .uninstaller:
            uninstaller.clearSelection()
            loadInventory { [weak self] in
                guard let self else { return }
                self.leftovers.scan(self.context)
            }
        default:
            scan(module)
        }
    }

    /// Moves items BareMac put in the Trash back to where they were.
    func restore(_ records: [ActionRecord]) {
        guard !records.isEmpty else { return }
        Task {
            let report = await engine.restore(records)
            history.reload(log: log)
            refreshDisk()
            trash.scan(context)
            let restored = report.restored.count
            if report.failures.isEmpty {
                notice = "Put back \(Format.count(restored, "item")) where \(restored == 1 ? "it was" : "they were")."
            } else {
                let reason = report.failures.first?.reason ?? ""
                notice = "Put back \(Format.count(restored, "item")). \(Format.count(report.failures.count, "item")) couldn't go back: \(reason)"
            }
            let origins = Set(report.restored.map(\.origin))
            for module in Module.allCases where origins.contains(module.title) && module.canScan {
                scan(module)
            }
            if origins.contains(Module.uninstaller.title) { loadInventory() }
        }
    }

    // MARK: Numbers for the sidebar and overview

    /// What BareMac suggests moving from System Junk and App Leftovers, measured.
    var suggestedBytes: Int64 {
        (junk.result?.suggestedBytes ?? 0) + (leftovers.result?.suggestedBytes ?? 0)
    }

    func badge(for module: Module) -> String? {
        switch module {
        case .systemJunk: junk.result.map { Format.bytes($0.suggestedBytes) }
        case .leftovers: leftovers.result.flatMap { $0.cleanableBytes > 0 ? Format.bytes($0.cleanableBytes) : nil }
        case .trash: trash.result.flatMap { $0.isReadable && $0.total.allocatedBytes > 0 ? Format.bytes($0.total.allocatedBytes) : nil }
        case .largeFiles: largeFiles.result.flatMap { $0.files.isEmpty ? nil : Format.bytes($0.totalBytes) }
        case .duplicates: duplicates.result.flatMap { $0.reclaimableBytes > 0 ? Format.bytes($0.reclaimableBytes) : nil }
        default: nil
        }
    }
}
