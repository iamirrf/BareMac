import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("App Leftovers")
struct LeftoversScannerTests {
    /// Notely is installed (with a helper); com.gone.app was removed; com.example.other
    /// shares a developer with Notely.
    private func populated() throws -> Fixture {
        let fx = try Fixture()
        try fx.app("Notely", bundleID: "com.example.notely", embedded: [("Notely Helper.app", "com.example.notely.helper", "Library/LoginItems")])
        try fx.file("Library/Caches/com.example.notely/a.bin", size: 30_000)
        try fx.file("Library/Caches/com.example.notely.helper/a.bin", size: 30_000)
        try fx.file("Library/Application Support/com.gone.app/data.db", size: 200_000)
        try fx.file("Library/Caches/com.gone.app/blob", size: 90_000)
        try fx.file("Library/Caches/com.gone.app.helper/blob", size: 10_000)
        try fx.plist("Library/Preferences/com.gone.app.plist", ["a": 1])
        try fx.plist("Library/Preferences/ByHost/com.gone.app.0A1B2C3D-1111-2222-3333-444455556666.plist", ["a": 1])
        try fx.file("Library/Saved Application State/com.gone.app.savedState/windows.plist", size: 4_000)
        try fx.plist("Library/LaunchAgents/com.gone.app.agent.plist", ["Label": "com.gone.app.agent", "Program": "/nonexistent/gone-agent"])
        try fx.plist("Library/LaunchAgents/org.active.tool.plist", ["Label": "org.active.tool", "Program": "/bin/ls"])
        try fx.file("Library/Application Support/com.example.other/data", size: 40_000)
        try fx.file("Library/Caches/com.apple.Safari/x", size: 40_000)
        try fx.file("Library/Application Support/Slack/big.db", size: 40_000)
        try fx.file("Library/Caches/com.baremac.BareMac/x", size: 40_000)
        try fx.file("Library/Group Containers/group.com.gone.app/shared.db", size: 20_000)
        try fx.file("Library/Group Containers/ABCDE12345.com.gone.app/shared.db", size: 20_000)
        try fx.plantDecoys()
        return fx
    }

    private func scan(_ fx: Fixture, fullDiskAccess: Bool = false) async throws -> LeftoversResult {
        let environment = fx.environment()
        return try await LeftoversScanner(environment: environment, policy: fx.policy(), inventory: AppInventory.scan(environment: environment), hasFullDiskAccess: fullDiskAccess).scan()
    }

    @Test("Files of a removed app are grouped under its app ID with exact sizes")
    func grouping() async throws {
        let fx = try populated()
        let result = try await scan(fx)
        let gone = try #require(result.groups.first { $0.identifier == "com.gone.app" })
        let names = Set(gone.items.map(\.url.lastPathComponent))
        #expect(names == ["com.gone.app", "com.gone.app.helper", "com.gone.app.plist", "com.gone.app.0A1B2C3D-1111-2222-3333-444455556666.plist",
                          "com.gone.app.savedState", "com.gone.app.agent.plist"])
        #expect(gone.items.filter { $0.url.lastPathComponent == "com.gone.app" }.count == 2) // Application Support + Caches
        #expect(!gone.isAmbiguous)
        #expect(gone.nameSource == .appID)
        for item in gone.items {
            #expect(item.bytes == foundationAllocatedSize(item.url))
            #expect(item.category == .appLeftover && item.isCleanable)
        }
        fx.expectOnlyAllowedOffered(result.groups.flatMap(\.items))
    }

    @Test("Caches, logs and window state are suggested; settings and app data start unchecked")
    func suggestions() async throws {
        let fx = try populated()
        let gone = try #require(try await scan(fx).groups.first { $0.identifier == "com.gone.app" })
        for item in gone.items {
            let path = item.url.path
            if path.contains("/Caches/") || path.contains("/Saved Application State/") {
                #expect(item.isSuggested, "\(path)")
            } else {
                #expect(!item.isSuggested, "\(path)")
                #expect(item.note != nil)
            }
        }
    }

    @Test("Installed apps, their helpers, Apple, BareMac and plain-named folders are never leftovers")
    func neverListed() async throws {
        let fx = try populated()
        let all = try await scan(fx).groups.flatMap(\.items).map(\.url.lastPathComponent)
        for name in ["com.example.notely", "com.example.notely.helper", "com.apple.Safari", "Slack", "com.baremac.BareMac", "org.active.tool.plist"] {
            #expect(!all.contains(name), "\(name) must not be listed")
        }
    }

    @Test("Something another installed app from the same developer may use is information only")
    func sameDeveloper() async throws {
        let fx = try populated()
        let group = try #require(try await scan(fx).groups.first { $0.identifier == "com.example.other" })
        #expect(group.isAmbiguous)
        #expect(group.items.allSatisfy { !$0.isCleanable && $0.infoReason?.contains("Notely") == true })
    }

    @Test("Group containers are checked only with Full Disk Access")
    func groupContainers() async throws {
        let fx = try populated()
        let without = try await scan(fx)
        #expect(!without.groups.flatMap(\.items).contains { $0.url.path.contains("Group Containers") })
        #expect(!without.notices.isEmpty)

        let with = try await scan(fx, fullDiskAccess: true)
        let gone = try #require(with.groups.first { $0.identifier == "com.gone.app" })
        let containers = gone.items.filter { $0.url.path.contains("Group Containers") }.map(\.url.lastPathComponent)
        #expect(Set(containers) == ["group.com.gone.app", "ABCDE12345.com.gone.app"])
        fx.expectOnlyAllowedOffered(with.groups.flatMap(\.items))
    }

    @Test("Names come from the known-apps table, then from the app ID")
    func names() {
        #expect(BundleID.displayName(for: "com.spotify.client") == "Spotify")
        #expect(BundleID.displayName(for: "com.gone.app") == "Gone")
    }
}

@Suite("Uninstaller")
struct AppFootprintScannerTests {
    private func populated() throws -> (Fixture, InstalledApp, AppInventory) {
        let fx = try Fixture()
        try fx.app("Notely", bundleID: "com.example.notely", embedded: [("Notely Helper.app", "com.example.notely.helper", "Library/LoginItems")])
        try fx.app("Other", bundleID: "com.other.app")
        try fx.file("Library/Caches/com.example.notely/a.bin", size: 30_000)
        try fx.file("Library/Caches/com.example.notely.helper/a.bin", size: 8_000)
        try fx.plist("Library/Preferences/com.example.notely.plist", ["a": 1])
        try fx.file("Library/Application Support/Notely/notes.db", size: 120_000)
        try fx.file("Library/Group Containers/group.com.example.notely/shared.db", size: 10_000)
        try fx.file("Library/Caches/com.other.app/a.bin", size: 30_000)
        try fx.file("Library/Application Support/Google/x", size: 30_000)
        try fx.plantDecoys()
        let inventory = AppInventory.scan(environment: fx.environment())
        let app = try #require(inventory.app(withIdentifier: "com.example.notely"))
        return (fx, app, inventory)
    }

    @Test("The app and every file it made, matched by ID or by name, with exact sizes")
    func footprint() async throws {
        let (fx, app, inventory) = try populated()
        let result = try await AppFootprintScanner(environment: fx.environment(), policy: fx.policy(), inventory: inventory, hasFullDiskAccess: true).footprint(of: app)

        #expect(result.bundleItem.category == .appBundle)
        #expect(result.bundleItem.isCleanable && result.bundleItem.isSuggested)
        #expect(result.bundleItem.bytes == foundationAllocatedSize(app.url))

        let byName = Dictionary(grouping: result.relatedItems, by: { $0.url.lastPathComponent })
        #expect(Set(byName.keys) == ["com.example.notely", "com.example.notely.helper", "com.example.notely.plist", "Notely", "group.com.example.notely"])
        #expect(byName["Notely"]?.first?.isSuggested == false, "name matches start unchecked")
        #expect(byName["Notely"]?.first?.note?.contains("Matched by name") == true)
        #expect(byName["com.example.notely"]?.first?.isSuggested == true)
        for item in result.relatedItems {
            #expect(item.category == .appFile)
            #expect(item.bytes == foundationAllocatedSize(item.url))
        }
        #expect(!result.relatedItems.contains { $0.url.path.contains("com.other.app") || $0.url.lastPathComponent == "Google" })
        fx.expectOnlyAllowedOffered(result.allItems)
    }

    @Test("A running app can't be moved until it quits")
    func running() async throws {
        let (fx, app, inventory) = try populated()
        let result = try await AppFootprintScanner(environment: fx.environment(), policy: fx.policy(), inventory: inventory, runningBundleIdentifiers: ["com.example.notely.helper"]).footprint(of: app)
        #expect(result.isRunning)
        #expect(!result.bundleItem.isCleanable)
        #expect(result.bundleItem.infoReason?.contains("Quit it first") == true)
    }

    @Test("An app installed by another user is refused with a plain reason")
    func otherOwner() async throws {
        let (fx, app, inventory) = try populated()
        let policy = SafetyPolicy(home: fx.home, applicationsDirectories: [fx.applications], userID: getuid() + 1)
        let result = try await AppFootprintScanner(environment: fx.environment(), policy: policy, inventory: inventory).footprint(of: app)
        #expect(!result.bundleItem.isCleanable)
        #expect(result.bundleItem.infoReason?.contains("all users") == true)
    }

    @Test("Apple's apps and BareMac itself are never offered for uninstall")
    func uninstallable() throws {
        let fx = try Fixture()
        try fx.app("Notely", bundleID: "com.example.notely")
        try fx.app("Safari", bundleID: "com.apple.Safari")
        try fx.app("BareMac", bundleID: BareMacIdentity.bundleIdentifier)
        let inventory = AppInventory.scan(environment: fx.environment())
        let apps = AppFootprintScanner(environment: fx.environment(), policy: fx.policy(), inventory: inventory).uninstallableApps()
        #expect(apps.map(\.bundleIdentifier) == ["com.example.notely"])
    }
}
