import BareMacCore
import SwiftUI

/// The exact list, freshly measured, shown before anything moves.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clean = model.clean
        VStack(spacing: 0) {
            switch clean.stage {
            case let .preparing(count):
                progress(title: "Measuring \(Format.count(count, "item"))…", value: nil,
                         detail: "BareMac measures everything again right now, so the total you confirm is exact.")
            case let .moving(done, total):
                progress(title: "Moving to the Trash…", value: total > 0 ? Double(done) / Double(total) : nil,
                         detail: "\(done) of \(total)")
            case .confirming:
                if let preview = clean.preview {
                    confirmation(preview)
                }
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 620)
        .frame(minHeight: 260, maxHeight: 640)
        .interactiveDismissDisabled(clean.stage != .confirming)
    }

    private func progress(title: String, value: Double?, detail: String) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Group {
                if let value { ProgressView(value: value) } else { ProgressView().progressViewStyle(.linear) }
            }
            .frame(width: 320)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    @ViewBuilder
    private func confirmation(_ preview: CleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.lines.isEmpty ? "Nothing can be moved" : "Move \(Format.bytes(preview.totalBytes)) to the Trash?")
                .font(.title2.weight(.semibold))
            Text(subtitle(preview))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)

        List {
            if !preview.lines.isEmpty {
                Section {
                    ForEach(preview.lines) { line in
                        HStack(spacing: 10) {
                            ItemIcon(url: line.entry.url, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.entry.label).lineLimit(1)
                                Text(Format.path(line.entry.url, home: model.environment.home))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(line.entry.url.path)
                            }
                            Spacer()
                            SizeLabel(bytes: line.measurement.allocatedBytes)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("\(Format.count(preview.lines.count, "item")) · \(Format.count(preview.fileCount, "file"))")
                }
            }
            if !preview.rejections.isEmpty {
                Section {
                    ForEach(preview.rejections) { rejection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rejection.entry.label).lineLimit(1)
                            Text(rejection.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Label("Not included (\(preview.rejections.count))", systemImage: "hand.raised")
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)

        HStack {
            Label("Nothing is deleted. You can put it all back.", systemImage: "arrow.uturn.backward")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.clean.cancel(engine: model.engine) }
                .keyboardShortcut(.cancelAction)
            if !preview.lines.isEmpty {
                Button("Move to Trash") { model.clean.confirm(engine: model.engine) }
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Move \(Format.spokenBytes(preview.totalBytes)) to Trash")
            }
        }
        .padding(18)
    }

    private func subtitle(_ preview: CleanPreview) -> String {
        if preview.lines.isEmpty {
            return "BareMac checked every item again and none of them can be moved safely. The reasons are below."
        }
        return "These \(Format.count(preview.lines.count, "item")) from \(preview.origin) go to the Trash. They stay there until you empty the Trash in Finder, and you can put them back from History at any time."
    }
}
