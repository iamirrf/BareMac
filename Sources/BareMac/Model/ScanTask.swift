import BareMacCore
import Foundation
import Observation

/// Runs one scan off the main thread and publishes its real progress.
///
/// Starting a new scan cancels the previous one. The last finished result stays
/// available while a rescan runs, so screens never flash empty.
@MainActor @Observable
final class ScanTask<Value: Sendable> {
    enum Status: Equatable {
        case idle, running, finished, failed
    }

    private(set) var status: Status = .idle
    private(set) var progress: ScanProgress?
    private(set) var value: Value?
    private(set) var errorMessage: String?
    private(set) var finishedAt: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isRunning: Bool { status == .running }
    var hasValue: Bool { value != nil }

    func run(
        _ work: @escaping @Sendable (@escaping ProgressHandler) async throws -> Value,
        onFinish: (@MainActor (Value) -> Void)? = nil
    ) {
        task?.cancel()
        generation += 1
        let current = generation
        status = .running
        progress = ScanProgress(phase: "Starting")
        errorMessage = nil

        let handler: ProgressHandler = { [weak self] update in
            let owner = self
            Task { @MainActor in owner?.receive(update, generation: current) }
        }

        task = Task { [weak self] in
            do {
                let result = try await work(handler)
                guard let self, self.generation == current else { return }
                self.value = result
                self.finishedAt = Date()
                self.progress = nil
                self.status = .finished
                onFinish?(result)
            } catch {
                guard let self, self.generation == current else { return }
                self.progress = nil
                if error is CancellationError || (error as? ScanError) == .cancelled {
                    self.status = self.value == nil ? .idle : .finished
                } else {
                    self.errorMessage = error.localizedDescription
                    self.status = .failed
                }
            }
        }
    }

    private func receive(_ update: ScanProgress, generation expected: Int) {
        guard generation == expected, status == .running else { return }
        progress = update
    }

    func cancel() {
        task?.cancel()
    }

    /// Forgets the result (for example after the scanned folder changes).
    func reset() {
        task?.cancel()
        generation += 1
        value = nil
        progress = nil
        finishedAt = nil
        errorMessage = nil
        status = .idle
    }
}

/// Everything a scan needs, captured on the main actor and handed to a background task.
struct ScanContext: Sendable {
    let environment: ScanEnvironment
    let policy: SafetyPolicy
    let inventory: AppInventory?
    let runningApps: Set<String>
    let hasFullDiskAccess: Bool
    let log: ActionLog
}
