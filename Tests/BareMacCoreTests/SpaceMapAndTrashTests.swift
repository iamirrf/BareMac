import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("Space Map")
struct SpaceMapTests {
    private func expectInvariants(_ node: SpaceNode, maxChildren: Int) {
        guard node.isDirectory else {
            #expect(node.children.isEmpty && node.otherBytes == 0 && node.fileCount == 1)
            return
        }
        #expect(node.bytes == node.children.reduce(0) { $0 + $1.bytes } + node.otherBytes, "\(node.name): bytes must add up")
        #expect(node.children.count <= maxChildren)
        #expect(zip(node.children, node.children.dropFirst()).allSatisfy { $0.bytes >= $1.bytes }, "largest first")
        for child in node.children { expectInvariants(child, maxChildren: maxChildren) }
    }

    @Test("Every byte is accounted for and matches an independent measurement")
    func totals() async throws {
        let fx = try Fixture()
        let root = try fx.directory("Projects")
        try fx.file("a/one.bin", size: 3_000_000, under: root)
        try fx.file("a/deep/two.bin", size: 1_500_000, under: root)
        try fx.file("b/three.bin", size: 2_000_000, under: root)
        for index in 0..<10 { try fx.file("c/tiny\(index).txt", size: 1_000, under: root, seed: UInt64(index)) }
        try fx.file(".hidden/blob.bin", size: 400_000, under: root)
        try fx.file("loose.bin", size: 250_000, under: root)

        let node = try await SpaceMapScanner(root: root, maxChildren: 2, minimumChildBytes: 300_000).scan()
        #expect(node.bytes == (try DiskMeasurer.measure(root)).allocatedBytes)
        #expect(node.bytes == foundationAllocatedSize(root))
        #expect(node.fileCount == 15)
        #expect(node.children.map(\.name) == ["a", "b"])
        #expect(node.otherCount == 3, "c, .hidden and loose.bin fall into other")
        expectInvariants(node, maxChildren: 2)
    }

    @Test("Packages are one tile; hard links count once")
    func packagesAndLinks() async throws {
        let fx = try Fixture()
        let root = try fx.directory("Apps")
        try fx.file("Tool.app/Contents/MacOS/tool", size: 2_000_000, under: root)
        try fx.file("Tool.app/Contents/Resources/big.bin", size: 2_000_000, under: root)
        let file = try fx.file("data/a.bin", size: 1_000_000, under: root)
        try FileManager.default.linkItem(at: file, to: root.appending(path: "data/a-link.bin"))

        let node = try await SpaceMapScanner(root: root, minimumChildBytes: 100_000).scan()
        let tool = try #require(node.children.first { $0.name == "Tool.app" })
        #expect(tool.isPackage && tool.children.isEmpty)
        #expect(tool.otherBytes == tool.bytes)
        let data = try #require(node.children.first { $0.name == "data" })
        #expect(data.bytes == (try DiskMeasurer.measure(file)).allocatedBytes)
        expectInvariants(node, maxChildren: 40)
    }
}

@Suite("Treemap")
struct TreemapTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 800, height: 500)

    private func overlaps(_ a: TreemapRect, _ b: TreemapRect) -> Bool {
        let epsilon = 1e-6
        return a.x < b.x + b.width - epsilon && b.x < a.x + a.width - epsilon && a.y < b.y + b.height - epsilon && b.y < a.y + a.height - epsilon
    }

    @Test("Areas are proportional, fill the rectangle, stay inside it and never overlap")
    func layout() {
        let values: [Double] = [500, 1, 120, 60, 60, 300, 7, 42, 900, 15]
        let rects = Treemap.squarify(values, in: bounds)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            #expect(abs(rect.area - value / total * bounds.area) < bounds.area * 1e-9, "area for \(value)")
            #expect(rect.x >= -1e-9 && rect.y >= -1e-9)
            #expect(rect.x + rect.width <= bounds.width + 1e-6 && rect.y + rect.height <= bounds.height + 1e-6)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.area } - bounds.area) < 1e-6)
        for i in rects.indices { for j in rects.indices where i < j { #expect(!overlaps(rects[i], rects[j]), "\(i) overlaps \(j)") } }
    }

    @Test("Order is preserved, zeros get no space, and one value fills everything")
    func edges() {
        let rects = Treemap.squarify([0, 10, -3, 10], in: bounds)
        #expect(rects[0].area == 0 && rects[2].area == 0)
        #expect(abs(rects[1].area - rects[3].area) < 1e-6)
        #expect(Treemap.squarify([5], in: bounds) == [bounds])
        #expect(Treemap.squarify([], in: bounds).isEmpty)
        #expect(Treemap.squarify([1, 2], in: TreemapRect(x: 0, y: 0, width: 0, height: 10)).allSatisfy { $0.area == 0 })
    }

    @Test("Squarified tiles stay close to square for typical folders")
    func aspectRatios() {
        let values = (1...30).map { Double(31 - $0) * 10 }
        let rects = Treemap.squarify(values, in: bounds)
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 8)
    }
}

@Suite("Trash")
struct TrashScannerTests {
    @Test("Lists what the Trash holds with an exact total, for information only")
    func readable() async throws {
        let fx = try Fixture()
        let trash = fx.home.appending(path: ".Trash")
        try fx.file("old movie.mov", size: 2_000_000, under: trash)
        try fx.file("Folder/inside.bin", size: 300_000, under: trash)
        let result = try await TrashScanner(environment: fx.environment(), log: nil).scan()
        #expect(result.isReadable)
        #expect(result.items.count == 2)
        #expect(result.total.allocatedBytes == foundationAllocatedSize(trash))
        #expect(result.items.allSatisfy { !$0.isCleanable && $0.infoReason == TrashScanner.infoReason })
        #expect(result.items.allSatisfy { !fx.policy().evaluate($0.url, as: $0.category).isAllowed })
    }

    @Test("When macOS hides the Trash, BareMac says so instead of guessing")
    func unreadable() async throws {
        let fx = try Fixture()
        let trash = try fx.directory(".Trash")
        try fx.file("x.bin", size: 10_000, under: trash)
        chmod(trash.path, 0o000)
        defer { chmod(trash.path, 0o755) }
        let result = try await TrashScanner(environment: fx.environment(), log: nil).scan()
        #expect(!result.isReadable)
        #expect(result.items.isEmpty && result.total == .zero)
    }

    @Test("Knows what BareMac put there: still there, not restored")
    func movedByBareMac() async throws {
        let fx = try Fixture()
        let trash = fx.home.appending(path: ".Trash")
        let present = try fx.file("present.bin", size: 10_000, under: trash)
        let log = ActionLog(fileURL: fx.root.appending(path: "log/t.jsonl"))
        let batch = UUID()
        let still = ActionRecord(batchID: batch, kind: .trashed, origin: "System Junk", category: "userCache", label: "A", originalPath: "/x/a", trashedPath: present.path, bytes: 12_288, fileCount: 1)
        let vanished = ActionRecord(batchID: batch, kind: .trashed, origin: "System Junk", category: "userCache", label: "B", originalPath: "/x/b", trashedPath: trash.appending(path: "gone.bin").path, bytes: 4_096, fileCount: 1)
        let restoredOriginal = ActionRecord(batchID: batch, kind: .trashed, origin: "System Junk", category: "userCache", label: "C", originalPath: "/x/c", trashedPath: present.path, bytes: 4_096, fileCount: 1)
        let restore = ActionRecord(batchID: UUID(), kind: .restored, origin: "System Junk", category: "userCache", label: "C", originalPath: "/x/c", trashedPath: present.path, bytes: 4_096, fileCount: 1, relatedRecordID: restoredOriginal.id)
        try log.append([still, vanished, restoredOriginal, restore])
        let result = try await TrashScanner(environment: fx.environment(), log: log).scan()
        #expect(result.movedByBareMac.map(\.id) == [still.id])
        #expect(result.movedByBareMacBytes == 12_288)
    }
}

@Suite("App inventory and app IDs")
struct InventoryTests {
    @Test("Finds apps one folder deep with the IDs of their helpers")
    func findsApps() throws {
        let fx = try Fixture()
        try fx.app("Notely", bundleID: "com.example.notely", embedded: [
            ("Helper.app", "com.example.notely.helper", "Library/LoginItems"),
            ("Sync.xpc", "com.example.notely.sync", "XPCServices"),
            ("Share.appex", "com.example.notely.share", "PlugIns"),
        ])
        try fx.app("Suite", bundleID: "com.vendor.suite", in: fx.directory("Vendor Suite", under: fx.applications))
        let inventory = AppInventory.scan(environment: fx.environment())
        #expect(inventory.apps.map(\.bundleIdentifier) == ["com.example.notely", "com.vendor.suite"])
        #expect(Set(inventory.apps[0].embeddedIdentifiers) == ["com.example.notely.helper", "com.example.notely.sync", "com.example.notely.share"])
    }

    @Test("Ownership: exact, nested, same developer, and not installed")
    func ownership() throws {
        let fx = try Fixture()
        try fx.app("Notely", bundleID: "com.example.notely", embedded: [("Helper.app", "com.example.notely.helper", "Library/LoginItems")])
        try fx.plist("Library/PreferencePanes/Pane.prefPane/Contents/Info.plist", ["CFBundleIdentifier": "com.panes.control"])
        let inventory = AppInventory.scan(environment: fx.environment())
        #expect({ if case .installed = inventory.ownership(of: "com.example.notely") { true } else { false } }())
        #expect({ if case .installed = inventory.ownership(of: "COM.EXAMPLE.NOTELY.helper.extra") { true } else { false } }())
        #expect({ if case .installed = inventory.ownership(of: "com.panes.control.settings") { true } else { false } }())
        #expect(inventory.ownership(of: "com.example.other") == .sameDeveloper("Notely"))
        #expect(inventory.ownership(of: "com.gone.app") == .notInstalled)
    }

    @Test("Group containers resolve by app group, by group. prefix, or not at all")
    func groupContainers() throws {
        let fx = try Fixture()
        let inventory = AppInventory.scan(environment: fx.environment())
        let byPrefix = inventory.ownershipOfGroupContainer("group.com.gone.app")
        #expect(byPrefix.ownership == .notInstalled && byPrefix.identifier == "com.gone.app")
        let byTeam = inventory.ownershipOfGroupContainer("ABCDE12345.com.gone.app")
        #expect(byTeam.identifier == "com.gone.app")
        let developerWide = inventory.ownershipOfGroupContainer("UBF8T346G9.Office")
        #expect(developerWide.identifier == nil, "a developer-wide container can't be tied to one app")
    }

    @Test("App ID helpers")
    func bundleIDs() {
        #expect(BundleID.isPlausible("com.example.app"))
        #expect(!BundleID.isPlausible("Google"))
        #expect(!BundleID.isPlausible("1com.example"))
        #expect(!BundleID.isPlausible("com..example"))
        #expect(!BundleID.isPlausible("com.exa mple"))
        #expect(BundleID.organization(of: "com.Spotify.client") == "com.spotify")
        #expect(BundleID.isRelated("com.a.app", "COM.A.APP.helper"))
        #expect(!BundleID.isRelated("com.a.app", "com.a.application"))
        #expect(BundleID.isApple("com.apple.Safari") && BundleID.isApple("group.com.apple.notes"))
        #expect(BundleID.isTeamIdentifier("UBF8T346G9") && !BundleID.isTeamIdentifier("ubf8t346g9"))
        #expect(BundleID.displayName(for: "org.videolan.vlc") == "VLC")
        #expect(BundleID.displayName(for: "us.zoom.xos") == "Zoom")
        #expect(BundleID.displayName(for: "com.example.photopad") == "Photopad")
        #expect(BundleID.displayName(for: "com.example.app") == "Example")
    }
}
