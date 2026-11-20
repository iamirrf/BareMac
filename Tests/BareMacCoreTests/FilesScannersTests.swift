import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("Large & Old Files")
struct LargeFilesScannerTests {
    private func scan(_ fx: Fixture, minimum: Int64 = 1_000_000) async throws -> LargeFilesResult {
        try await LargeFilesScanner(environment: fx.environment(), policy: fx.policy(), minimumBytes: minimum, readLastOpened: false).scan()
    }

    @Test("Finds files over the threshold with exact sizes and kinds")
    func threshold() async throws {
        let fx = try Fixture()
        let movie = try fx.file("Movies/trip.mov", size: 5_000_000)
        let image = try fx.file("Downloads/tool.dmg", size: 2_000_000)
        try fx.file("Documents/small.pdf", size: 500_000)
        let result = try await scan(fx)
        #expect(result.files.map(\.item.url.path) == [movie.path, image.path])
        #expect(result.files[0].kind == .video)
        #expect(result.files[1].kind == .diskImage)
        for file in result.files {
            #expect(file.item.bytes == foundationAllocatedSize(file.item.url))
            #expect(file.item.category == .userFile && file.item.isCleanable && !file.item.isSuggested)
            #expect(!file.sharesStorage)
        }
        fx.expectOnlyAllowedOffered(result.files.map(\.item))
    }

    @Test("Skips ~/Library, hidden folders, packages, the Trash, and never follows symlinks")
    func exclusions() async throws {
        let fx = try Fixture()
        try fx.file("Library/Big/cache.bin", size: 3_000_000)
        try fx.file(".hidden/big.bin", size: 3_000_000)
        try fx.file("Applications/Tool.app/Contents/Resources/big.bin", size: 3_000_000)
        try fx.file(".Trash/old.mov", size: 3_000_000)
        let outsideBig = try fx.file("huge.bin", size: 3_000_000, under: fx.outside)
        try FileManager.default.createSymbolicLink(at: fx.home.appending(path: "link.bin"), withDestinationURL: outsideBig)
        let result = try await scan(fx)
        #expect(result.files.isEmpty, "found \(result.files.map(\.item.url.path))")
    }

    @Test("A cloned file is flagged: moving it frees almost nothing")
    func clones() async throws {
        let fx = try Fixture()
        let original = try fx.file("Movies/original.mov", size: 3_000_000)
        #expect(clonefile(original.path, fx.home.appending(path: "Movies/clone.mov").path, 0) == 0)
        let result = try await scan(fx)
        #expect(result.files.count == 2)
        #expect(result.files.allSatisfy { $0.sharesStorage })
    }

    @Test("“Not used since” falls back to the change date when no open was recorded")
    func notUsed() async throws {
        let fx = try Fixture()
        let old = try fx.file("Documents/old.zip", size: 2_000_000)
        try fx.file("Documents/new.zip", size: 2_000_000, seed: 3)
        let past = Date(timeIntervalSinceNow: -400 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        let result = try await scan(fx)
        let stale = LargeFilesScanner.notUsed(since: Date(timeIntervalSinceNow: -365 * 86_400), in: result.files)
        #expect(stale.map(\.item.url.lastPathComponent) == ["old.zip"])
    }

    @Test("File kinds by extension")
    func kinds() {
        #expect(FileKind.of(fileName: "a.MP4") == .video)
        #expect(FileKind.of(fileName: "a.zip") == .archive)
        #expect(FileKind.of(fileName: "a.pkg") == .installer)
        #expect(FileKind.of(fileName: "a.heic") == .image)
        #expect(FileKind.of(fileName: "README") == .other)
    }
}

@Suite("Duplicates")
struct DuplicatesScannerTests {
    private func scan(_ fx: Fixture, minimum: Int64 = 100_000) async throws -> DuplicatesResult {
        try await DuplicatesScanner(environment: fx.environment(), policy: fx.policy(), minimumBytes: minimum).scan()
    }

    private func setDate(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -daysAgo * 86_400)], ofItemAtPath: url.path)
    }

    @Test("Identical files are grouped; the newest copy is kept and never suggested")
    func grouping() async throws {
        let fx = try Fixture()
        let data = Fixture.bytes(300_000, seed: 7)
        let a = try fx.file("Documents/report.pdf", contents: data)
        let b = try fx.file("Downloads/report (1).pdf", contents: data)
        let c = try fx.file("Desktop/copy.pdf", contents: data)
        try setDate(a, daysAgo: 30)
        try setDate(b, daysAgo: 1)
        try setDate(c, daysAgo: 10)
        let result = try await scan(fx)
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        #expect(group.files.map(\.item.url.path) == [b.path, c.path, a.path], "newest first")
        #expect(group.keeper.item.url == b)
        #expect(!group.keeper.item.isSuggested)
        #expect(group.suggestedRemovals.map(\.item.url) == [c, a])
        #expect(group.fileSize == 300_000)
        #expect(group.reclaimableBytes == foundationAllocatedSize(a) + foundationAllocatedSize(c))
        fx.expectOnlyAllowedOffered(group.files.map(\.item))
    }

    @Test("Same size but different content is not a duplicate, even with matching start and end")
    func differentContent() async throws {
        let fx = try Fixture()
        var first = Fixture.bytes(400_000, seed: 1)
        var second = first
        second[200_000] ^= 0xFF // only the middle differs
        first[0] = first[0]
        try fx.file("Documents/one.bin", contents: first)
        try fx.file("Documents/two.bin", contents: second)
        try fx.file("Documents/three.bin", size: 400_000, seed: 99)
        #expect(try await scan(fx).groups.isEmpty)
    }

    @Test("Hard links are one file, not copies")
    func hardLinks() async throws {
        let fx = try Fixture()
        let a = try fx.file("Documents/a.bin", size: 200_000)
        try FileManager.default.linkItem(at: a, to: fx.home.appending(path: "Documents/a-link.bin"))
        #expect(try await scan(fx).groups.isEmpty)
        try fx.file("Desktop/a-copy.bin", contents: Data(contentsOf: a))
        let groups = try await scan(fx).groups
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
    }

    @Test("A clone shares storage, so it isn't suggested")
    func clones() async throws {
        let fx = try Fixture()
        let a = try fx.file("Documents/a.mov", size: 2_000_000)
        try setDate(a, daysAgo: 5)
        let clone = fx.home.appending(path: "Documents/a clone.mov")
        #expect(clonefile(a.path, clone.path, 0) == 0)
        try setDate(clone, daysAgo: 1)
        let group = try #require(try await scan(fx).groups.first)
        let older = try #require(group.files.first { $0.item.url == a })
        #expect(older.sharesStorage)
        #expect(!older.item.isSuggested)
        #expect(older.item.note?.contains("clone") == true)
        #expect(group.reclaimableBytes == 0)
    }

    @Test("Files under the minimum size and outside the walk are ignored")
    func exclusions() async throws {
        let fx = try Fixture()
        let small = Fixture.bytes(50_000, seed: 3)
        try fx.file("Documents/s1.bin", contents: small)
        try fx.file("Documents/s2.bin", contents: small)
        let big = Fixture.bytes(200_000, seed: 4)
        try fx.file("Library/Caches/x/b1.bin", contents: big)
        try fx.file("Documents/b2.bin", contents: big)
        try fx.file(".config/b3.bin", contents: big)
        #expect(try await scan(fx).groups.isEmpty)
    }

    @Test("No group ever has every copy suggested")
    func neverAllCopies() async throws {
        let fx = try Fixture()
        for index in 0..<4 {
            let data = Fixture.bytes(150_000, seed: UInt64(index))
            for copy in 0..<(index + 2) { try fx.file("Documents/g\(index)/c\(copy).bin", contents: data) }
        }
        let groups = try await scan(fx).groups
        #expect(groups.count == 4)
        for group in groups {
            #expect(group.files.contains { !$0.item.isSuggested })
            #expect(!group.keeper.item.isSuggested)
        }
    }
}
