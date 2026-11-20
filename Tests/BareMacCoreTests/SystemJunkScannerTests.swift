import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("System Junk")
struct SystemJunkScannerTests {
    private func scan(_ fx: Fixture, running: Set<String> = [], fullDiskAccess: Bool = false, languages: [String] = ["en"], systemLogs: [URL] = []) async throws -> SystemJunkResult {
        var environment = fx.environment(languages: languages)
        environment.systemLogDirectories = systemLogs
        let inventory = AppInventory.scan(environment: environment)
        return try await SystemJunkScanner(
            environment: environment, policy: fx.policy(), inventory: inventory,
            runningBundleIdentifiers: running, hasFullDiskAccess: fullDiskAccess
        ).scan()
    }

    private func section(_ result: SystemJunkResult, _ kind: SystemJunkResult.SectionKind) -> SystemJunkResult.Section {
        result.sections.first { $0.kind == kind }!
    }

    @Test("Finds caches with exact sizes, suggests them, and skips empty ones")
    func caches() async throws {
        let fx = try Fixture()
        let cache = try fx.directory("Library/Caches/com.example.reader")
        try fx.file("a.bin", size: 120_000, under: cache)
        try fx.file("sub/b.bin", size: 9_999, under: cache)
        try fx.directory("Library/Caches/com.example.empty")
        try fx.plantDecoys()

        let result = try await scan(fx)
        let caches = section(result, .userCaches).items
        let item = try #require(caches.first { $0.url.path == cache.path })
        #expect(item.isCleanable && item.isSuggested)
        #expect(item.bytes == foundationAllocatedSize(cache))
        #expect(item.measurement.logicalBytes == 129_999)
        #expect(!caches.contains { $0.url.lastPathComponent == "com.example.empty" })
        #expect(result.sections.map(\.kind) == SystemJunkResult.SectionKind.allCases)
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("Caches macOS manages are information only; Apple caches are never pre-selected")
    func protectedCaches() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.apple.bird/state.db", size: 20_000)
        try fx.file("Library/Caches/com.apple.Music/artwork.bin", size: 20_000)
        let result = try await scan(fx)
        let caches = section(result, .userCaches).items
        let bird = try #require(caches.first { $0.url.lastPathComponent == "com.apple.bird" })
        #expect(!bird.isCleanable)
        let music = try #require(caches.first { $0.url.lastPathComponent == "com.apple.Music" })
        #expect(music.isCleanable && !music.isSuggested)
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("A running app's cache is not pre-selected and says why")
    func runningApp() async throws {
        let fx = try Fixture()
        try fx.app("Reader", bundleID: "com.example.reader")
        try fx.file("Library/Caches/com.example.reader/a.bin", size: 50_000)
        let result = try await scan(fx, running: ["com.example.reader"])
        let item = try #require(section(result, .userCaches).items.first)
        #expect(item.name == "Reader")
        #expect(item.owner?.bundleIdentifier == "com.example.reader")
        #expect(item.isCleanable && !item.isSuggested)
        #expect(item.note?.contains("Reader is open") == true)
    }

    @Test("Logs are found and suggested; crash reports get a plain name")
    func logs() async throws {
        let fx = try Fixture()
        try fx.file("Library/Logs/com.example.reader/run.log", size: 30_000)
        try fx.file("Library/Logs/DiagnosticReports/Reader-2026.ips", size: 12_000)
        let result = try await scan(fx)
        let logs = section(result, .logs).items
        #expect(logs.count == 2)
        #expect(logs.allSatisfy { $0.isSuggested && $0.category == .log })
        #expect(logs.contains { $0.name == "Crash reports" })
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("Only settings files macOS can't read count as damaged")
    func brokenPreferences() async throws {
        let fx = try Fixture()
        try fx.file("Library/Preferences/com.example.empty.plist", contents: Data())
        try fx.file("Library/Preferences/com.example.garbage.plist", contents: Data("not a property list".utf8))
        try fx.plist("Library/Preferences/com.example.fine.plist", ["Key": "Value"])
        let result = try await scan(fx)
        let names = Set(section(result, .brokenPreferences).items.map(\.url.lastPathComponent))
        #expect(names == ["com.example.empty.plist", "com.example.garbage.plist"])
        #expect(section(result, .brokenPreferences).items.allSatisfy { $0.isSuggested })
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("App Store app caches need Full Disk Access; Apple's containers are skipped")
    func containerCaches() async throws {
        let fx = try Fixture()
        try fx.file("Library/Containers/com.example.store/Data/Library/Caches/images/a.bin", size: 40_000)
        try fx.file("Library/Containers/com.apple.Notes/Data/Library/Caches/x.bin", size: 40_000)

        let withoutAccess = try await scan(fx)
        #expect(section(withoutAccess, .appCaches).items.isEmpty)
        #expect(section(withoutAccess, .appCaches).notice != nil)

        let withAccess = try await scan(fx, fullDiskAccess: true)
        let items = section(withAccess, .appCaches).items
        #expect(items.count == 1)
        #expect(items.first?.category == .containerCache)
        #expect(items.first?.isSuggested == true)
        fx.expectOnlyAllowedOffered(withAccess.allItems)
    }

    @Test("Device backups are listed with their device name and never pre-selected")
    func deviceBackups() async throws {
        let fx = try Fixture()
        let backup = try fx.directory("Library/Application Support/MobileSync/Backup/00008110-001A")
        try fx.plist("Info.plist", ["Device Name": "Test iPhone", "Product Version": "19.1"], under: backup)
        try fx.file("Manifest.db", size: 200_000, under: backup)
        let result = try await scan(fx)
        let item = try #require(section(result, .deviceBackups).items.first)
        #expect(item.name == "Backup of Test iPhone")
        #expect(item.isCleanable && !item.isSuggested)
        #expect(item.bytes == foundationAllocatedSize(backup))
    }

    @Test("Unused app languages are measured exactly but are information only")
    func languages() async throws {
        let fx = try Fixture()
        let app = try fx.app("Atlas", bundleID: "com.example.atlas")
        for language in ["en", "Base", "de", "fr", "ja"] {
            try fx.file("Contents/Resources/\(language).lproj/Localizable.strings", size: 25_000, under: app, seed: UInt64(language.count))
        }
        let result = try await scan(fx, languages: ["en-US", "de-DE"])
        let item = try #require(section(result, .languageFiles).items.first)
        #expect(!item.isCleanable)
        #expect(item.category == .informationOnly)
        #expect(item.explanation.hasPrefix("2 languages"))
        let unused = ["fr", "ja"].map { app.appending(path: "Contents/Resources/\($0).lproj") }
        #expect(item.bytes == unused.reduce(0) { $0 + foundationAllocatedSize($1) })
        #expect(!fx.policy().evaluate(item.url, as: item.category).isAllowed)
    }

    @Test("System logs are shown for information only")
    func systemLogs() async throws {
        let fx = try Fixture()
        let logs = try fx.directory("SystemLogs", under: fx.outside)
        try fx.file("system.log", size: 10_000, under: logs)
        let result = try await scan(fx, systemLogs: [logs])
        let item = try #require(section(result, .systemLogs).items.first)
        #expect(!item.isCleanable)
        #expect(item.bytes == foundationAllocatedSize(logs))
    }

    @Test("Decoys are never offered, and every offered item passes the allowlist")
    func decoys() async throws {
        let fx = try Fixture()
        let decoys = try fx.plantDecoys()
        try fx.file("Library/Caches/com.example.real/a.bin", size: 10_000)
        let result = try await scan(fx, fullDiskAccess: true)
        let offered = Fixture.paths(result.allItems.filter(\.isCleanable))
        for decoy in decoys {
            #expect(!offered.contains { PathTools.isInsideOrEqual(decoy.path, $0) }, "\(decoy.path) would be moved")
        }
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("Language codes are normalized")
    func languageCodes() {
        #expect(SystemJunkScanner.languageCode("en-GB") == "en")
        #expect(SystemJunkScanner.languageCode("zh_Hans") == "zh")
        #expect(SystemJunkScanner.languageCode("English") == "en")
        #expect(SystemJunkScanner.languageCode("nb") == "no")
        #expect(SystemJunkScanner.languageCode("pt-BR") == "pt")
    }
}
