import Foundation
import Testing
@testable import BareMacCore

/// Records every launchctl call; never touches the real launchd.
final class FakeLaunchControl: LaunchControlling, @unchecked Sendable {
    var disabled: [String: Bool]
    var loaded: Set<String>
    private(set) var calls: [String] = []
    private let lock = NSLock()

    init(disabled: [String: Bool] = [:], loaded: Set<String> = []) {
        self.disabled = disabled
        self.loaded = loaded
    }

    private func note(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func disabledLabels() throws -> [String: Bool] { disabled }
    func loadedLabels() throws -> Set<String> { loaded }
    func disable(label: String) throws { note("disable \(label)") }
    func enable(label: String) throws { note("enable \(label)") }
    func bootout(label: String) throws { note("bootout \(label)") }
    func bootstrap(plist: URL) throws { note("bootstrap \(plist.lastPathComponent)") }
}

@Suite("Startup Items")
struct StartupItemsTests {
    private func populated() throws -> (Fixture, FakeLaunchControl) {
        let fx = try Fixture()
        let app = try fx.app("Notely", bundleID: "com.example.notely",
                             embedded: [("Notely Launcher.app", "com.example.notely.launcher", "Library/LoginItems")])
        try fx.plist("Library/LaunchAgents/com.example.notely.sync.plist", [
            "Label": "com.example.notely.sync",
            "Program": app.appending(path: "Contents/MacOS/Notely").path,
            "RunAtLoad": true, "KeepAlive": true,
        ])
        try fx.plist("Library/LaunchAgents/com.example.backup-agent.plist", [
            "Label": "com.example.backup-agent", "ProgramArguments": ["/bin/ls", "-l"], "StartInterval": 3600,
        ])
        try fx.plist("Library/LaunchAgents/com.example.missing.plist", [
            "Label": "com.example.missing", "Program": "/nonexistent/tool", "RunAtLoad": true,
        ])
        try fx.plist("Library/LaunchAgents/com.example.off.plist", [
            "Label": "com.example.off", "Program": "/bin/ls", "RunAtLoad": true,
        ])
        try fx.plist("System/LaunchAgents/com.vendor.global.plist", ["Label": "com.vendor.global", "Program": "/bin/ls", "RunAtLoad": true], under: fx.root)
        try fx.plist("System/LaunchDaemons/com.vendor.daemon.plist", ["Label": "com.vendor.daemon", "Program": "/bin/ls", "KeepAlive": true], under: fx.root)
        let control = FakeLaunchControl(disabled: ["com.example.off": true], loaded: ["com.example.notely.sync"])
        return (fx, control)
    }

    private func scan(_ fx: Fixture, _ control: FakeLaunchControl) async throws -> StartupItemsResult {
        var environment = fx.environment()
        environment.systemLaunchAgentsDirectory = fx.root.appending(path: "System/LaunchAgents")
        environment.systemLaunchDaemonsDirectory = fx.root.appending(path: "System/LaunchDaemons")
        return try await StartupItemsScanner(environment: environment, inventory: AppInventory.scan(environment: environment), launchControl: control).scan()
    }

    @Test("Your own agents are explained in plain words with real on/off and running state")
    func userAgents() async throws {
        let (fx, control) = try populated()
        let result = try await scan(fx, control)
        let byLabel = Dictionary(uniqueKeysWithValues: result.userAgents.map { ($0.label, $0) })

        let sync = try #require(byLabel["com.example.notely.sync"])
        #expect(sync.owner?.name == "Notely")
        #expect(sync.displayName == "Notely")
        #expect(sync.summary == "Starts when you log in and keeps running.")
        #expect(sync.isEnabled == true && sync.isLoaded == true && sync.canToggle)

        let backup = try #require(byLabel["com.example.backup-agent"])
        #expect(backup.summary == "Runs every hour.")
        #expect(backup.displayName == "Backup Agent")
        #expect(backup.isLoaded == false)

        let missing = try #require(byLabel["com.example.missing"])
        #expect(!missing.programExists)
        #expect(missing.summary.contains("program is missing"))

        #expect(byLabel["com.example.off"]?.isEnabled == false)
        #expect(control.calls.isEmpty, "scanning must not change anything")
    }

    @Test("Items for all users are information only; login helpers are listed")
    func systemItems() async throws {
        let (fx, control) = try populated()
        let result = try await scan(fx, control)
        #expect(result.systemAgents.map(\.label) == ["com.vendor.global"])
        #expect(result.systemDaemons.map(\.label) == ["com.vendor.daemon"])
        for item in result.systemAgents + result.systemDaemons {
            #expect(!item.canToggle)
            #expect(item.isEnabled == nil)
            #expect(item.managementNote == StartupItemsScanner.systemNote)
        }
        #expect(result.systemDaemons.first?.summary == "Keeps running in the background.")
        let helper = try #require(result.loginHelpers.first)
        #expect(helper.displayName == "Notely" && !helper.canToggle)
    }

    @Test("Turning off uses launchctl disable then bootout, and it is logged; turning on reverses it")
    func toggling() async throws {
        let (fx, control) = try populated()
        let log = ActionLog(fileURL: fx.root.appending(path: "log/startup.jsonl"))
        let item = try #require(try await scan(fx, control).userAgents.first { $0.label == "com.example.notely.sync" })
        let controller = StartupController(launchControl: control, log: log)

        let off = try controller.turnOff(item)
        #expect(control.calls == ["disable com.example.notely.sync", "bootout com.example.notely.sync"])
        #expect(off.kind == .startupItemTurnedOff)

        let on = try controller.turnOn(item)
        #expect(control.calls.suffix(2) == ["enable com.example.notely.sync", "bootstrap com.example.notely.sync.plist"])
        #expect(on.kind == .startupItemTurnedOn)
        #expect(try log.records().map(\.kind) == [.startupItemTurnedOff, .startupItemTurnedOn])
    }

    @Test("Items for all users can't be switched from BareMac")
    func systemNotToggled() async throws {
        let (fx, control) = try populated()
        let global = try #require(try await scan(fx, control).systemAgents.first)
        let controller = StartupController(launchControl: control, log: ActionLog(fileURL: fx.root.appending(path: "log/x.jsonl")))
        #expect(throws: StartupController.ControlError.self) { try controller.turnOff(global) }
        #expect(control.calls.isEmpty)
    }

    @Test("launchctl output is parsed, and unsafe labels are refused")
    func parsing() {
        let disabled = """
        disabled services = {
        \t"com.example.off" => disabled
        \t"com.example.on" => enabled
        \t"com.legacy.off" => true
        }
        login item associations = {
        \t"com.example.app" => ("x")
        }
        """
        #expect(SystemLaunchControl.parseDisabled(disabled) == ["com.example.off": true, "com.example.on": false, "com.legacy.off": true])
        let list = "PID\tStatus\tLabel\n123\t0\tcom.example.running\n-\t0\tcom.example.idle\n"
        #expect(SystemLaunchControl.parseList(list) == ["com.example.running", "com.example.idle"])
        #expect(throws: LaunchControlError.self) { try SystemLaunchControl.validate("bad label; rm -rf") }
        #expect(throws: LaunchControlError.self) { try SystemLaunchControl.validate("../escape") }
        #expect((try? SystemLaunchControl.validate("com.example.ok-agent_1")) != nil)
    }
}
