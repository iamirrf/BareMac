import BareMacCore
import SwiftUI

/// What a module screen is showing.
enum ModuleState: Equatable {
    case notScanned
    case scanning(ScanProgress?)
    case failed(String)
    case empty
    case content
}

extension ScanTask {
    /// The screen state for a task: results win over a running rescan, so the list
    /// never disappears while BareMac re-measures.
    func moduleState(isEmpty: (Value) -> Bool) -> ModuleState {
        if let value { return isEmpty(value) ? .empty : .content }
        switch status {
        case .running: return .scanning(progress)
        case .failed: return .failed(errorMessage ?? "Something went wrong.")
        case .idle, .finished: return .notScanned
        }
    }
}

/// The big number at the top of a screen.
struct Headline {
    var bytes: Int64?
    var text: String?
    var caption: String
}

/// Copy for a module's empty and not-yet-scanned states.
struct ModuleCopy {
    var readyTitle: String
    var readyMessage: String
    var emptyTitle: String
    var emptyMessage: String
    var emptySymbol: String = "checkmark.seal"
    var accents: [String] = []
}

/// The shared layout of every module: header with the headline number, a banner
/// slot, the content (or an illustrated state), and the floating Move to Trash bar.
struct ModuleScaffold<Accessory: View, Content: View>: View {
    @Environment(AppModel.self) private var model

    let module: Module
    let state: ModuleState
    var headline: Headline?
    var copy: ModuleCopy
    var rescanProgress: ScanProgress?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: module, headline: state == .content ? headline : nil, rescanProgress: rescanProgress) {
                accessory
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if let report = model.clean.report, model.clean.reportModule == module {
                ResultBanner(report: report)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }

            Divider()

            Group {
                switch state {
                case .notScanned:
                    StateMessage(
                        illustration: Illustration(symbol: module.symbol, tint: module.tint, accents: copy.accents),
                        title: copy.readyTitle, message: copy.readyMessage
                    ) {
                        Button("Scan") { model.scan(module) }
                            .prominentButton()
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                case let .scanning(progress):
                    ScanningView(module: module, progress: progress, home: model.environment.home) {
                        model.stop(module)
                    }
                case let .failed(message):
                    StateMessage(
                        illustration: Illustration(symbol: "exclamationmark.triangle", tint: .orange),
                        title: "BareMac couldn't finish", message: message
                    ) {
                        Button("Try Again") { model.scan(module) }.prominentButton()
                    }
                case .empty:
                    StateMessage(
                        illustration: Illustration(symbol: copy.emptySymbol, tint: .green, accents: copy.accents),
                        title: copy.emptyTitle, message: copy.emptyMessage
                    ) {
                        Button("Scan Again") { model.scan(module) }.secondaryButton()
                    }
                case .content:
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if module.canClean, state == .content {
                let selection = model.checked(for: module)
                CleanBar(count: selection.count, bytes: selection.bytes, isEnabled: model.canClean(module)) {
                    model.requestClean(module)
                }
                .padding(.bottom, 18)
                .padding(.top, 8)
            }
        }
        .animation(.snappy, value: model.clean.report?.batchID)
        .navigationTitle(module.title)
        .toolbar {
            if module.canScan {
                ToolbarItem(placement: .primaryAction) {
                    if model.isScanning(module) {
                        Button { model.stop(module) } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Stop scanning")
                    } else {
                        Button { model.scan(module) } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                            .help("Scan again (⌘R)")
                    }
                }
            }
        }
    }
}

extension ModuleScaffold where Accessory == EmptyView {
    init(module: Module, state: ModuleState, headline: Headline? = nil, copy: ModuleCopy, rescanProgress: ScanProgress? = nil, @ViewBuilder content: () -> Content) {
        self.init(module: module, state: state, headline: headline, copy: copy, rescanProgress: rescanProgress, accessory: { EmptyView() }, content: content)
    }
}

/// Icon, plain explanation and the headline number.
struct ModuleHeader<Accessory: View>: View {
    let module: Module
    let headline: Headline?
    let rescanProgress: ScanProgress?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: module.symbol)
                .font(.system(size: 24, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(module.tint.gradient)
                .frame(width: 56, height: 56)
                .glass(.rounded(16), tint: module.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if let headline {
                    HeadlineNumber(headline: headline)
                } else {
                    Text(module.title)
                        .font(.system(size: 28, weight: .semibold))
                }
                Text(headline?.caption ?? module.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let rescanProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(rescanProgress.phase)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Scanning: \(rescanProgress.phase)")
                }
            }
            Spacer(minLength: 16)
            accessory
        }
    }
}

/// "2.31 GB" with the unit set a little smaller, animating between values.
struct HeadlineNumber: View {
    let headline: Headline

    var body: some View {
        Group {
            if let bytes = headline.bytes {
                let parts = Format.splitBytes(bytes)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(bytes == 0 ? "0" : parts.number)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(bytes == 0 ? "bytes" : parts.unit)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Format.spokenBytes(bytes)), \(headline.caption)")
                .help(ByteText.exact(bytes))
            } else if let text = headline.text {
                Text(text)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .animation(.snappy, value: headline.bytes)
    }
}

/// Real progress: what BareMac is looking at, and how much it has counted so far.
struct ScanningView: View {
    let module: Module
    let progress: ScanProgress?
    let home: URL
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Illustration(symbol: "magnifyingglass", tint: module.tint, accents: ["doc", "folder", "internaldrive"])
            Text(progress.map { "\($0.phase)…" } ?? "Starting…")
                .font(.title3.weight(.semibold))
            Group {
                if let fraction = progress?.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 340)
            if let progress {
                Text(counts(progress))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let path = progress.currentPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460)
                }
            }
            Button("Stop", action: onStop)
                .secondaryButton()
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func counts(_ progress: ScanProgress) -> String {
        var parts = [Format.count(progress.itemsVisited, "item") + " checked"]
        if progress.bytesSeen > 0 { parts.append(Format.bytes(progress.bytesSeen) + " found") }
        return parts.joined(separator: " · ")
    }
}

/// The floating glass bar with the one confident button. It always names the exact,
/// measured total before anything moves.
struct CleanBar: View {
    let count: Int
    let bytes: Int64
    let isEnabled: Bool
    let action: () -> Void

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Text(count == 0 ? "Nothing selected" : Format.count(count, "item") + " selected")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glass(.capsule)
                    .glassID("summary", in: namespace)

                if count > 0 {
                    Button(action: action) {
                        Label("Move \(Format.bytes(bytes)) to Trash", systemImage: "trash")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .prominentButton()
                    .controlSize(.large)
                    .disabled(!isEnabled)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .glassID("clean", in: namespace)
                    .help("Review the exact list first. Nothing moves until you confirm.")
                    .accessibilityLabel("Move \(Format.spokenBytes(bytes)) to Trash")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: count > 0)
    }
}

/// "Moved 1.2 GB to the Trash" with Undo.
struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    let report: CleanReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(report.failures.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text("Space comes back when you empty the Trash in Finder. You can put everything back from History.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(report.failures.prefix(3)) { failure in
                    Text("“\(failure.entry.label)” stayed: \(failure.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.failures.count > 3 {
                    Text("…and \(report.failures.count - 3) more. See History for details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !report.moved.isEmpty {
                Button("Undo") {
                    model.restore(report.moved.map(\.record))
                    model.clean.dismissReport()
                }
                .secondaryButton()
            }
            Button {
                model.clean.dismissReport()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .glass(.rounded(16), tint: report.failures.isEmpty ? .green : .orange)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if report.moved.isEmpty { return "Nothing was moved" }
        return "Moved \(Format.bytes(report.movedBytes)) to the Trash (\(Format.count(report.moved.count, "item")))"
    }
}

/// A one-line message with a close button.
struct NoticeBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.tint)
            Text(text).font(.callout)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glass(.rounded(14))
    }
}

/// Explains why macOS hides something and opens the right Settings page.
struct PermissionBanner: View {
    var title = "Give BareMac Full Disk Access to see everything"
    var message = "macOS hides your Trash, device backups and App Store app caches until you allow it. BareMac only reads names and sizes, and never sends anything anywhere."

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("After you turn it on, come back here — BareMac checks again on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { Workspace.openFullDiskAccessSettings() }
                .secondaryButton()
        }
        .padding(16)
        .glass(.rounded(18), tint: .accentColor)
        .accessibilityElement(children: .contain)
    }
}

/// Small rounded label, for example "Suggested" or "Info only".
struct Tag: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
