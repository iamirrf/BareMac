import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("Measuring: every byte counted, exactly")
struct DiskMeasurerTests {
    @Test("Logical bytes equal exactly what was written")
    func logicalBytesExact() throws {
        let fx = try Fixture()
        let sizes = [0, 1, 4095, 4096, 4097, 65_537, 1_000_000]
        let folder = try fx.directory("Library/Caches/com.example.sizes")
        for (index, size) in sizes.enumerated() {
            try fx.file("f\(index).bin", size: size, under: folder, seed: UInt64(index))
        }
        let m = try DiskMeasurer.measure(folder)
        #expect(m.logicalBytes == Int64(sizes.reduce(0, +)))
        #expect(m.fileCount == sizes.count)
        #expect(m.isComplete)
    }

    @Test("On-disk bytes match Foundation's independent count")
    func allocatedBytesMatchFoundation() throws {
        let fx = try Fixture()
        let folder = try fx.directory("Library/Caches/com.example.tree")
        for i in 0..<40 {
            try fx.file("level\(i % 4)/sub\(i % 7)/file\(i).dat", size: 1_000 * (i + 1) + i, under: folder, seed: UInt64(i))
        }
        let m = try DiskMeasurer.measure(folder)
        #expect(m.allocatedBytes == foundationAllocatedSize(folder))
        #expect(m.allocatedBytes >= m.logicalBytes)
        #expect(m.fileCount == 40)
    }

    @Test("Hard links are counted once")
    func hardLinksOnce() throws {
        let fx = try Fixture()
        let folder = try fx.directory("Library/Caches/com.example.links")
        let original = try fx.file("a.bin", size: 50_000, under: folder)
        try FileManager.default.linkItem(at: original, to: folder.appending(path: "b.bin"))
        let single = try DiskMeasurer.measure(original)
        let both = try DiskMeasurer.measure(folder)
        #expect(both.allocatedBytes == single.allocatedBytes)
        #expect(both.logicalBytes == 50_000)
    }

    @Test("Symbolic links are measured themselves, never followed")
    func symlinksNotFollowed() throws {
        let fx = try Fixture()
        let big = try fx.file("huge.bin", size: 2_000_000, under: fx.outside)
        let folder = try fx.directory("Library/Caches/com.example.symlinks")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: big)
        let m = try DiskMeasurer.measure(folder)
        #expect(m.logicalBytes < 1_000, "the 2 MB target must not be counted")
        #expect(m.fileCount == 1)
    }

    @Test("Unreadable folders are reported, not guessed")
    func unreadableReported() throws {
        let fx = try Fixture()
        let folder = try fx.directory("Library/Caches/com.example.locked")
        let locked = try fx.directory("locked", under: folder)
        try fx.file("secret.bin", size: 10_000, under: locked)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        let m = try DiskMeasurer.measure(folder)
        #expect(!m.isComplete)
        #expect(m.unreadableCount >= 1)
    }

    @Test("A missing item measures as unreadable, not as zero")
    func missingItem() throws {
        let fx = try Fixture()
        let m = try DiskMeasurer.measure(fx.home.appending(path: "nope"))
        #expect(!m.isComplete)
    }

    @Test("APFS clones report the space they would really free")
    func clonesAreHonest() throws {
        let fx = try Fixture()
        let original = try fx.file("Movies/original.mov", size: 3_000_000)
        let clone = fx.home.appending(path: "Movies/clone.mov")
        let cloned = clonefile(original.path, clone.path, 0) == 0
        try #require(cloned, "the fixture volume must support clones (APFS)")

        let normalPrivate = try #require(PrivateSize.privateBytes(path: original.path))
        let clonePrivate = try #require(PrivateSize.privateBytes(path: clone.path))
        let allocated = try DiskMeasurer.measure(clone).allocatedBytes
        #expect(clonePrivate < allocated / 10, "a fresh clone shares (almost) all its blocks")
        #expect(normalPrivate < allocated / 10, "the original now shares its blocks with the clone too")

        let standalone = try fx.file("Movies/standalone.mov", size: 3_000_000, seed: 9)
        let standalonePrivate = try #require(PrivateSize.privateBytes(path: standalone.path))
        #expect(standalonePrivate == (try DiskMeasurer.measure(standalone)).allocatedBytes)
    }

    @Test("Cancelling a measurement stops it")
    func cancellation() throws {
        let fx = try Fixture()
        let folder = try fx.directory("Library/Caches/com.example.many")
        for i in 0..<3_000 { try fx.file("f\(i)", size: 1, under: folder) }
        #expect(throws: DiskMeasurer.Cancelled.self) {
            try DiskMeasurer.measure(folder, isCancelled: { true })
        }
    }
}
