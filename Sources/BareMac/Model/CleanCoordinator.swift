import BareMacCore
import Foundation
import Observation

/// The one path from "selected" to "in the Trash": measure the exact list, show it,
/// wait for the user to confirm, move, report. Shared by every module.
@MainActor @Observable
final class CleanCoordinator {
    enum Stage: Equatable {
        case idle
        case preparing(count: Int)
        case confirming
        case moving(done: Int, total: Int)
    }

    private(set) var stage: Stage = .idle
    private(set) var preview: CleanPreview?
    private(set) var origin: Module?
    /// The last finished clean, shown as a banner on its module until dismissed.
    private(set) var report: CleanReport?
    private(set) var reportModule: Module?
    var errorMessage: String?

    @ObservationIgnored private var onFinished: (@MainActor (CleanReport) -> Void)?

    var isPresentingSheet: Bool { stage != .idle }

    func begin(_ request: CleanRequest, from module: Module, engine: FileEngine, onFinished: @escaping @MainActor (CleanReport) -> Void) {
        guard stage == .idle, !request.entries.isEmpty else { return }
        origin = module
        self.onFinished = onFinished
        stage = .preparing(count: request.entries.count)
        Task {
            let preview = await engine.preview(request)
            guard case .preparing = self.stage else {
                await engine.discard(preview.id)
                return
            }
            self.preview = preview
            self.stage = .confirming
        }
    }

    func confirm(engine: FileEngine) {
        guard stage == .confirming, let preview, !preview.lines.isEmpty else { return }
        stage = .moving(done: 0, total: preview.lines.count)
        let module = origin
        Task {
            do {
                let report = try await engine.execute(preview.id) { done, total in
                    Task { @MainActor in
                        if case .moving = self.stage { self.stage = .moving(done: done, total: total) }
                    }
                }
                self.report = report
                self.reportModule = module
                self.finish()
                self.onFinished?(report)
                self.onFinished = nil
            } catch {
                self.errorMessage = error.localizedDescription
                self.finish()
            }
        }
    }

    func cancel(engine: FileEngine) {
        if let preview {
            Task { await engine.discard(preview.id) }
        }
        onFinished = nil
        finish()
    }

    func dismissReport() {
        report = nil
        reportModule = nil
    }

    private func finish() {
        preview = nil
        origin = nil
        stage = .idle
    }
}
