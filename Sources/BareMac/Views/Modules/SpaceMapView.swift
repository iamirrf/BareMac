import AppKit
import BareMacCore
import SwiftUI

struct SpaceMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.spaceMap
        let state = store.task.moduleState { $0.bytes == 0 }
        let root = store.root ?? model.environment.home
        ModuleScaffold(
            module: .spaceMap,
            state: state,
            headline: store.current.map { Headline(bytes: $0.bytes, caption: "in \(Format.path($0.url, home: model.environment.home)) · \(Format.count($0.fileCount, "file"))") },
            copy: ModuleCopy(
                readyTitle: "See where your space goes",
                readyMessage: "BareMac measures every file in \(Format.path(root, home: model.environment.home)) and draws the biggest folders as tiles. Nothing is moved from here.",
                emptyTitle: "This folder is empty",
                emptyMessage: "There's nothing to map in \(Format.path(root, home: model.environment.home)).",
                emptySymbol: "rectangle.split.3x3",
                accents: ["folder", "film", "photo"]
            ),
            rescanProgress: store.task.isRunning && store.task.value != nil ? store.task.progress : nil
        ) {
            Button("Choose Folder…") { chooseFolder() }
                .secondaryButton()
        } content: {
            if let current = store.current {
                VStack(spacing: 12) {
                    Breadcrumbs()
                    HStack(spacing: 14) {
                        TreemapView(node: current)
                        TopItemsList(node: current)
                            .frame(width: 290)
                    }
                    if current.unreadableCount > 0 {
                        Label("\(Format.count(current.unreadableCount, "item")) couldn't be read, so the real total may be higher. Full Disk Access lets BareMac see more.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.spaceMap.root ?? model.environment.home
        panel.prompt = "Map This Folder"
        panel.message = "BareMac will measure everything inside the folder you choose. It doesn't change anything."
        if panel.runModal() == .OK, let url = panel.url {
            model.spaceMap.root = url
            model.scan(.spaceMap)
        }
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let path = model.spaceMap.path
        HStack(spacing: 4) {
            Button {
                model.spaceMap.goUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(path.count < 2)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Up one folder (⌘↑)")
            .accessibilityLabel("Up one folder")

            ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Button(index == 0 ? Format.path(node.url, home: model.environment.home) : node.name) {
                    model.spaceMap.go(to: index)
                }
                .buttonStyle(.borderless)
                .fontWeight(index == path.count - 1 ? .semibold : .regular)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(.capsule)
    }
}

/// A squarified treemap of the current folder's children. Folders open on click.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let node: SpaceNode

    private static let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .mint, .cyan, .yellow]

    struct Tile: Identifiable {
        let id: String
        let node: SpaceNode?
        let title: String
        let bytes: Int64
        let rect: CGRect
        let color: Color
    }

    var body: some View {
        GeometryReader { geometry in
            let tiles = layout(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    TileView(tile: tile, isHovered: model.spaceMap.hoveredID == tile.id)
                        .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                        .offset(x: tile.rect.minX + 1.5, y: tile.rect.minY + 1.5)
                        .onHover { inside in
                            if inside { model.spaceMap.hoveredID = tile.id } else if model.spaceMap.hoveredID == tile.id { model.spaceMap.hoveredID = nil }
                        }
                        .onTapGesture { if let child = tile.node { model.spaceMap.open(child) } }
                        .contextMenu { if let child = tile.node { ItemMenu(url: child.url) } }
                        .help("\(tile.title) — \(Format.bytes(tile.bytes))")
                        .accessibilityElement()
                        .accessibilityLabel("\(tile.title), \(Format.spokenBytes(tile.bytes))")
                        .accessibilityAddTraits(tile.node?.children.isEmpty == false ? .isButton : [])
                        .accessibilityAction { if let child = tile.node { model.spaceMap.open(child) } }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: node.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of \(node.name)")
    }

    private func layout(in size: CGSize) -> [Tile] {
        var entries: [(id: String, node: SpaceNode?, title: String, bytes: Int64)] = node.children.map { ($0.id, $0, $0.name, $0.bytes) }
        if node.otherBytes > 0 {
            entries.append(("other:\(node.id)", nil, "\(Format.count(node.otherCount, "smaller item"))", node.otherBytes))
        }
        let rects = Treemap.squarify(entries.map { Double($0.bytes) }, in: TreemapRect(x: 0, y: 0, width: size.width, height: size.height))
        return zip(entries, rects).enumerated().map { index, pair in
            let (entry, rect) = pair
            let color = entry.node == nil ? Color.gray : Self.palette[index % Self.palette.count]
            return Tile(id: entry.id, node: entry.node, title: entry.title, bytes: entry.bytes, rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), color: color)
        }
    }
}

private struct TileView: View {
    let tile: TreemapView.Tile
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tile.color.opacity(isHovered ? 0.75 : (colorScheme == .dark ? 0.45 : 0.55)).gradient)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(colorScheme == .dark ? 0.18 : 0.45), lineWidth: 1)
            if let node = tile.node, node.isDirectory, !node.children.isEmpty, tile.rect.width > 140, tile.rect.height > 100 {
                MiniMap(node: node)
                    .padding(.top, 38)
                    .padding([.horizontal, .bottom], 8)
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }
            if tile.rect.width > 64, tile.rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(Format.bytes(tile.bytes)).font(.caption).monospacedDigit()
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(8)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The next level, drawn small inside a folder tile.
private struct MiniMap: View {
    let node: SpaceNode

    var body: some View {
        Canvas { context, size in
            let values = node.children.map { Double($0.bytes) } + (node.otherBytes > 0 ? [Double(node.otherBytes)] : [])
            let rects = Treemap.squarify(values, in: TreemapRect(x: 0, y: 0, width: size.width, height: size.height))
            for rect in rects where rect.width > 2 && rect.height > 2 {
                let path = Path(roundedRect: CGRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2), cornerRadius: 4)
                context.fill(path, with: .color(.white.opacity(0.18)))
                context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
        }
    }
}

/// The same data as a list, for precision and VoiceOver.
private struct TopItemsList: View {
    @Environment(AppModel.self) private var model
    let node: SpaceNode

    var body: some View {
        List {
            ForEach(node.children) { child in
                HStack(spacing: 8) {
                    ItemIcon(url: child.url, size: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(child.name).lineLimit(1).truncationMode(.middle)
                        GeometryReader { geometry in
                            Capsule().fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(2, geometry.size.width * share(child)))
                        }
                        .frame(height: 4)
                    }
                    SizeLabel(bytes: child.bytes)
                        .font(.callout)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.spaceMap.open(child) }
                .contextMenu { ItemMenu(url: child.url) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(child.children.isEmpty ? [] : .isButton)
            }
            if node.otherBytes > 0 {
                HStack {
                    Text(Format.count(node.otherCount, "smaller item")).foregroundStyle(.secondary)
                    Spacer()
                    SizeLabel(bytes: node.otherBytes)
                }
            }
        }
        .listStyle(.inset)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func share(_ child: SpaceNode) -> Double {
        node.bytes > 0 ? Double(child.bytes) / Double(node.bytes) : 0
    }
}
