import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("File engine: Trash only, preview first, logged, restorable")
struct FileEngineTests {
    /// A home folder with things BareMac may move and decoys it must never touch.
    private func populatedFixture() throws -> (Fixture, [CleanRequest.Entry]) {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob-1", size: 120_000)
        try fx.file("Library/Caches/com.example.app/nested/blob-2", size: 33_333)
        try fx.file("Library/Logs/com.example.app/run.log", size: 5_000)
        try fx.file("Library/Preferences/com.example.broken.plist", contents: Data("not a plist".utf8))
        try fx.file("Documents/keep-me.pages", size: 9_999)
        try fx.file("Library/Keychains/login.keychain-db", size: 4_096)
        try fx.file("Library/Caches/com.apple.bird/state.db", size: 2_048)
        try fx.file("decoy.bin", size: 77_777, under: fx.outside)

        let entries = [
            CleanRequest.Entry(url: fx.home.appending(path: "Library/Caches/com.example.app"), category: .userCache, label: "Example cache"),
            CleanRequest.Entry(url: fx.home.appending(path: "Library/Logs/com.example.app"), category: .log, label: "Example logs"),
            CleanRequest.Entry(url: fx.home.appending(path: "Library/Preferences/com.example.broken.plist"), category: .brokenPreference, label: "Broken prefs"),
        ]
        return (fx, entries)
    }

    @Test("Preview measures exactly and moves nothing")
    func previewMovesNothing() async throws {
        let (fx, entries) = try populatedFixture()
        let before = try fx.snapshot()
        let preview = await fx.engine().preview(CleanRequest(origin: "Test", entries: entries))

        #expect(preview.lines.count == 3)
        #expect(preview.rejections.isEmpty)
        let expected = entries.reduce(Int64(0)) { $0 + foundationAllocatedSize($1.url) }
        #expect(preview.totalBytes == expected)
        #expect(try fx.snapshot() == before, "a preview must not change a single file")
    }

    @Test("Nothing moves without a preview, and a preview works only once")
    func previewRequired() async throws {
        let (fx, entries) = try populatedFixture()
        let engine = fx.engine()
        let before = try fx.snapshot()

        await #expect(throws: FileEngine.EngineError.previewNotFound) {
            try await engine.execute(UUID())
        }
        #expect(try fx.snapshot() == before)

        let preview = await engine.preview(CleanRequest(origin: "Test", entries: entries))
        _ = try await engine.execute(preview.id)
        await #expect(throws: FileEngine.EngineError.previewNotFound) {
            try await engine.execute(preview.id)
        }
    }

    @Test("A cancelled preview can't be executed")
    func discardedPreview() async throws {
        let (fx, entries) = try populatedFixture()
        let engine = fx.engine()
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: entries))
        await engine.discard(preview.id)
        await #expect(throws: FileEngine.EngineError.previewNotFound) {
            try await engine.execute(preview.id)
        }
    }

    @Test("Refused items are listed with a reason and never move")
    func refusalsNeverMove() async throws {
        let (fx, _) = try populatedFixture()
        let bad = [
            CleanRequest.Entry(url: fx.home.appending(path: "Documents/keep-me.pages"), category: .userCache, label: "wrong zone"),
            CleanRequest.Entry(url: fx.home.appending(path: "Library/Keychains/login.keychain-db"), category: .appLeftover, label: "keychain"),
            CleanRequest.Entry(url: fx.home.appending(path: "Library/Caches/com.apple.bird"), category: .userCache, label: "iCloud"),
            CleanRequest.Entry(url: fx.outside.appending(path: "decoy.bin"), category: .userFile, label: "outside"),
            CleanRequest.Entry(url: URL(filePath: "/System/Library/CoreServices/Finder.app"), category: .appBundle, label: "Finder"),
        ]
        let engine = fx.engine()
        let before = try fx.snapshot()
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: bad))
        #expect(preview.lines.isEmpty)
        #expect(preview.rejections.count == bad.count)
        #expect(preview.rejections.allSatisfy { !$0.reason.isEmpty })
        let report = try await engine.execute(preview.id)
        #expect(report.moved.isEmpty)
        #expect(try fx.snapshot() == before)
    }

    @Test("A clean run moves exactly the approved items, touches nothing else, and logs every byte")
    func cleanRunIsExact() async throws {
        let (fx, entries) = try populatedFixture()
        let engine = fx.engine()
        let before = try fx.snapshot()
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: entries))
        let report = try await engine.execute(preview.id)

        #expect(report.failures.isEmpty)
        #expect(report.moved.count == 3)
        #expect(report.movedBytes == preview.totalBytes)

        let after = try fx.snapshot()
        let movedRoots = entries.map(\.url.path)
        for (path, fingerprint) in before {
            let wasMoved = movedRoots.contains { path == $0 || PathTools.isStrictlyInside(path, $0) }
            if wasMoved {
                #expect(after[path] == nil, "\(path) should be in the Trash")
            } else if !PathTools.isInsideOrEqual(path, fx.trash.path), !path.hasPrefix(fx.root.path + "/log") {
                if fingerprint.isDirectory {
                    // A folder's own size changes when an entry leaves it; it must still be there.
                    #expect(after[path]?.isDirectory == true, "\(path) must still exist")
                    #expect(after[path]?.inode == fingerprint.inode)
                } else {
                    #expect(after[path] == fingerprint, "\(path) must be untouched")
                }
            }
        }

        let records = try engine.log.records()
        #expect(records.count == 3)
        for record in records {
            #expect(record.kind == .trashed)
            #expect(FileEngine.isInsideATrash(record.trashedPath ?? ""))
            #expect(FileManager.default.fileExists(atPath: record.trashedPath ?? ""))
            #expect(record.bytes > 0)
        }
        #expect(records.reduce(0) { $0 + $1.bytes } == preview.totalBytes)
    }

    @Test("Everything from a clean run comes back from the Trash exactly as it was")
    func cleanRunIsRestorable() async throws {
        let (fx, entries) = try populatedFixture()
        let engine = fx.engine()
        let home = try fx.snapshot(fx.home)
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: entries))
        let report = try await engine.execute(preview.id)
        #expect(try fx.snapshot(fx.home) != home)

        let restore = await engine.restore(report.moved.map(\.record))
        #expect(restore.failures.isEmpty)
        #expect(restore.restored.count == 3)
        #expect(try fx.snapshot(fx.home) == home, "content, size, inode and dates must all match")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.trash.path).isEmpty)

        // Restoring twice is refused, and logged restores point at their originals.
        let again = await engine.restore(report.moved.map(\.record))
        #expect(again.restored.isEmpty)
        let restoredIDs = try engine.log.restoredRecordIDs()
        #expect(restoredIDs == Set(report.moved.map(\.record.id)))
    }

    @Test("Restore never overwrites something new at the original location")
    func restoreNeverOverwrites() async throws {
        let (fx, entries) = try populatedFixture()
        let engine = fx.engine()
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: [entries[2]]))
        let report = try await engine.execute(preview.id)
        let replacement = try fx.file("Library/Preferences/com.example.broken.plist", contents: Data("new".utf8))

        let restore = await engine.restore(report.moved.map(\.record))
        #expect(restore.restored.isEmpty)
        #expect(restore.failures.count == 1)
        #expect(try Data(contentsOf: replacement) == Data("new".utf8))
    }

    @Test("Every copy of a duplicate can never be selected at once")
    func duplicatesKeepOne() async throws {
        let fx = try Fixture()
        let data = Fixture.bytes(200_000, seed: 42)
        let a = try fx.file("Documents/a.mov", contents: data)
        let b = try fx.file("Downloads/a copy.mov", contents: data)
        let c = try fx.file("Desktop/a.mov", contents: data)
        let group = [a, b, c]
        let engine = fx.engine()

        let all = await engine.preview(CleanRequest(
            origin: "Duplicates",
            entries: group.map { CleanRequest.Entry(url: $0, category: .userFile, label: $0.lastPathComponent) },
            duplicateGroups: [group]
        ))
        #expect(all.lines.isEmpty, "selecting every copy must be refused")
        #expect(all.rejections.count == 3)

        let twoOfThree = await engine.preview(CleanRequest(
            origin: "Duplicates",
            entries: [b, c].map { CleanRequest.Entry(url: $0, category: .userFile, label: $0.lastPathComponent) },
            duplicateGroups: [group]
        ))
        #expect(twoOfThree.lines.count == 2)

        // If the kept copy disappears before confirming, nothing in the group moves.
        try FileManager.default.removeItem(at: a)
        let report = try await engine.execute(twoOfThree.id)
        #expect(report.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: c.path))
    }

    @Test("Items inside another selected folder are folded into it")
    func nestedSelections() async throws {
        let fx = try Fixture()
        let folder = try fx.directory("Library/Caches/com.example.nested")
        let inner = try fx.file("inner.bin", size: 1_000, under: folder)
        let preview = await fx.engine().preview(CleanRequest(origin: "Test", entries: [
            .init(url: folder, category: .userCache, label: "folder"),
            .init(url: inner, category: .userCache, label: "inner"),
        ]))
        #expect(preview.lines.map(\.entry.url) == [folder])
        #expect(preview.rejections.count == 1)
    }

    @Test("An item that changed into something unsafe after the preview isn't moved")
    func recheckedBeforeMoving() async throws {
        let fx = try Fixture()
        let cache = try fx.directory("Library/Caches/com.example.swap")
        try fx.file("data", size: 1_000, under: cache)
        let engine = fx.engine()
        let preview = await engine.preview(CleanRequest(origin: "Test", entries: [.init(url: cache, category: .userCache, label: "swap")]))
        #expect(preview.lines.count == 1)

        // Swap the whole Caches folder for a symlink to somewhere else.
        let caches = fx.home.appending(path: "Library/Caches")
        let elsewhere = fx.outside.appending(path: "Caches")
        try FileManager.default.moveItem(at: caches, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: elsewhere)

        let report = try await engine.execute(preview.id)
        #expect(report.moved.isEmpty)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "com.example.swap/data").path))
    }

    @Test("The real macOS Trash: move, then restore by exact path")
    func realTrashRoundTrip() async throws {
        let fx = try Fixture()
        let file = try fx.file("Downloads/baremac-real-trash-test-\(UUID().uuidString).bin", size: 12_345)
        let original = try Data(contentsOf: file)
        let engine = FileEngine(policy: fx.policy(), trasher: SystemTrash(), log: ActionLog(fileURL: fx.root.appending(path: "log/real.jsonl")))

        let preview = await engine.preview(CleanRequest(origin: "Test", entries: [.init(url: file, category: .userFile, label: "probe")]))
        let report = try await engine.execute(preview.id)
        let record = try #require(report.moved.first?.record)
        let trashedPath = try #require(record.trashedPath)
        #expect(FileEngine.isInsideATrash(trashedPath))
        #expect(fileStatus(trashedPath) != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let restore = await engine.restore([record])
        #expect(restore.restored.count == 1)
        #expect(try Data(contentsOf: file) == original)
        #expect(fileStatus(trashedPath) == nil, "the Trash must not keep a copy")
    }
}

@Suite("Action log")
struct ActionLogTests {
    @Test("Records are appended as one JSON object per line and read back intact")
    func roundTrip() throws {
        let fx = try Fixture()
        let log = ActionLog(fileURL: fx.root.appending(path: "log/a.jsonl"))
        let batch = UUID()
        let first = ActionRecord(batchID: batch, kind: .trashed, origin: "System Junk", category: "userCache", label: "Cache", originalPath: "/a", trashedPath: "/x/.Trash/a", bytes: 4096, fileCount: 1)
        let second = ActionRecord(batchID: batch, kind: .restored, origin: "System Junk", category: "userCache", label: "Cache", originalPath: "/a", trashedPath: "/x/.Trash/a", bytes: 4096, fileCount: 1, relatedRecordID: first.id)
        try log.append(first)
        try log.append(second)

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        let records = try log.records()
        #expect(records.map(\.id) == [first.id, second.id])
        #expect(records[0].bytes == 4096)
        #expect(try log.restoredRecordIDs() == [first.id])
    }
}
