import SwiftUI

/// A small illustrated scene: a glass disc holding a symbol, with a few glass
/// "satellites". It floats gently unless Reduce Motion is on.
struct Illustration: View {
    var symbol: String
    var tint: Color
    var accents: [String] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    private static let orbit: [CGSize] = [
        CGSize(width: -92, height: -38), CGSize(width: 96, height: -24), CGSize(width: -70, height: 58), CGSize(width: 82, height: 60),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.30), tint.opacity(0)], center: .center, startRadius: 4, endRadius: 130))
                .frame(width: 260, height: 260)

            Image(systemName: symbol)
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.gradient)
                .frame(width: 120, height: 120)
                .glass(.circle, tint: tint)

            ForEach(Array(accents.prefix(4).enumerated()), id: \.offset) { index, accent in
                Image(systemName: accent)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .glass(.circle)
                    .offset(Self.orbit[index])
                    .offset(y: floating ? (index.isMultiple(of: 2) ? -4 : 4) : 0)
            }
        }
        .frame(width: 260, height: 190)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { floating = true }
        }
    }
}

/// A full-screen message with an illustration: ready to scan, all clean, needs
/// permission, or something went wrong.
struct StateMessage<Actions: View>: View {
    var illustration: Illustration
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            illustration
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions }
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension StateMessage where Actions == EmptyView {
    init(illustration: Illustration, title: String, message: String) {
        self.init(illustration: illustration, title: title, message: message) { EmptyView() }
    }
}
