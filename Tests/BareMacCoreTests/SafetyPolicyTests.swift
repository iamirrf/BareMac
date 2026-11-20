import Darwin
import Foundation
import Testing
@testable import BareMacCore

@Suite("Safety policy: the allowlist")
struct SafetyPolicyTests {
    @Test("Direct children of ~/Library/Caches are allowed; the folder itself and deeper items are not")
    func cachesZone() throws {
        let fx = try Fixture()
        let cache = try fx.file("Library/Caches/com.example.app/data.bin", size: 100)
        let policy = fx.policy()

        #expect(policy.evaluate(cache.deletingLastPathComponent(), as: .userCache) == .allowed)
        #expect(!policy.evaluate(fx.home.appending(path: "Library/Caches"), as: .userCache).isAllowed)
        #expect(!policy.evaluate(cache, as: .userCache).isAllowed)
    }

    @Test("Caches macOS manages (iCloud, background downloads) are refused")
    func protectedCaches() throws {
        let fx = try Fixture()
        let bird = try fx.directory("Library/Caches/com.apple.bird")
        let downloads = try fx.directory("Library/Caches/com.apple.nsurlsessiond")
        #expect(!fx.policy().evaluate(bird, as: .userCache).isAllowed)
        #expect(!fx.policy().evaluate(downloads, as: .userCache).isAllowed)
    }

    @Test("Anything outside the home folder and Applications is refused for every category")
    func outsideHome() throws {
        let fx = try Fixture()
        let decoy = try fx.file("Library/Caches/decoy.bin", size: 10, under: fx.outside)
        let policy = fx.policy()
        for category in CleanCategory.allCases {
            #expect(!policy.evaluate(decoy, as: category).isAllowed, "\(category) allowed an outside file")
            #expect(!policy.evaluate(URL(filePath: "/System/Library/CoreServices/Finder.app"), as: category).isAllowed)
            #expect(!policy.evaluate(URL(filePath: "/usr/bin/true"), as: category).isAllowed)
            #expect(!policy.evaluate(URL(filePath: "/"), as: category).isAllowed)
            #expect(!policy.evaluate(fx.home, as: category).isAllowed)
        }
    }

    @Test("A symlinked folder can't smuggle an outside path into an allowed zone")
    func symlinkEscape() throws {
        let fx = try Fixture()
        let target = try fx.directory("Secrets", under: fx.outside)
        try fx.file("passwords.txt", size: 64, under: target)
        // ~/Library/Caches/escape -> Outside/Secrets
        let caches = try fx.directory("Library/Caches")
        let link = caches.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let throughLink = link.appending(path: "passwords.txt")

        let policy = fx.policy()
        // The link itself may move (that only moves the link) ...
        #expect(policy.evaluate(link, as: .userCache) == .allowed)
        // ... but nothing reached *through* it ever does.
        for category in CleanCategory.allCases {
            #expect(!policy.evaluate(throughLink, as: category).isAllowed)
        }
    }

    @Test("Paths with . or .. are refused outright")
    func dotDot() throws {
        let fx = try Fixture()
        try fx.file("Documents/tax-return.pdf", size: 10)
        try fx.directory("Library/Caches")
        let sneaky = URL(filePath: fx.home.path + "/Library/Caches/../../Documents/tax-return.pdf")
        #expect(!fx.policy().evaluate(sneaky, as: .userCache).isAllowed)
        #expect(!fx.policy().evaluate(sneaky, as: .userFile).isAllowed)
    }

    @Test("Keychains, iCloud Drive, Mail, the Trash and BareMac's own log are always off limits")
    func protectedSubtrees() throws {
        let fx = try Fixture()
        let keychain = try fx.file("Library/Keychains/login.keychain-db", size: 10)
        let icloud = try fx.file("Library/Mobile Documents/com~apple~CloudDocs/a.txt", size: 10)
        let mail = try fx.file("Library/Mail/V10/x.emlx", size: 10)
        let trashed = try fx.file(".Trash/old.txt", size: 10)
        let ownLog = try fx.file("Library/Application Support/BareMac/action-log.jsonl", size: 10)
        let policy = fx.policy()
        for url in [keychain, icloud, mail, trashed, ownLog] {
            for category in CleanCategory.allCases {
                #expect(!policy.evaluate(url, as: category).isAllowed, "\(url.path) allowed as \(category)")
            }
            #expect(!policy.evaluate(url.deletingLastPathComponent(), as: .appLeftover).isAllowed)
        }
    }

    @Test("Preferences must be .plist files directly in ~/Library/Preferences")
    func preferences() throws {
        let fx = try Fixture()
        let good = try fx.file("Library/Preferences/com.example.app.plist", size: 10)
        let notPlist = try fx.file("Library/Preferences/com.example.app.lockfile", size: 10)
        let nested = try fx.file("Library/Preferences/Sub/com.example.app.plist", size: 10)
        let policy = fx.policy()
        #expect(policy.evaluate(good, as: .brokenPreference) == .allowed)
        #expect(!policy.evaluate(notPlist, as: .brokenPreference).isAllowed)
        #expect(!policy.evaluate(nested, as: .brokenPreference).isAllowed)
    }

    @Test("App files must be named after an app ID, sit directly in a known Library folder, and never be Apple's")
    func appSupportFiles() throws {
        let fx = try Fixture()
        let support = try fx.directory("Library/Application Support/com.example.gone")
        let byName = try fx.directory("Library/Application Support/Google")
        let apple = try fx.directory("Library/Application Support/com.apple.sharedfilelist")
        let deep = try fx.directory("Library/Application Support/com.example.gone/sub")
        let pref = try fx.file("Library/Preferences/com.example.gone.plist", size: 10)
        let agent = try fx.file("Library/LaunchAgents/com.example.gone.agent.plist", size: 10)
        let group = try fx.directory("Library/Group Containers/ABCDE12345.com.example.gone")
        let ownSupport = try fx.directory("Library/Caches/com.baremac.BareMac")
        let policy = fx.policy()

        for category in [CleanCategory.appLeftover, .appFile] {
            #expect(policy.evaluate(support, as: category) == .allowed)
            #expect(policy.evaluate(pref, as: category) == .allowed)
            #expect(policy.evaluate(agent, as: category) == .allowed)
            #expect(policy.evaluate(group, as: category) == .allowed)
            #expect(!policy.evaluate(byName, as: category).isAllowed)
            #expect(!policy.evaluate(apple, as: category).isAllowed)
            #expect(!policy.evaluate(deep, as: category).isAllowed)
            #expect(!policy.evaluate(ownSupport, as: category).isAllowed)
        }
    }

    @Test("Only user-owned, non-Apple .app bundles in Applications can be uninstalled")
    func appBundles() throws {
        let fx = try Fixture()
        let mine = try fx.app("Notely", bundleID: "com.example.notely")
        let inFolder = try fx.app("Suite", bundleID: "com.example.suite", in: fx.directory("Example Suite", under: fx.applications))
        let apple = try fx.app("Safari", bundleID: "com.apple.Safari")
        let itself = try fx.app("BareMac", bundleID: BareMacIdentity.bundleIdentifier)
        let elsewhere = try fx.app("Loose", bundleID: "com.example.loose", in: fx.directory("Downloads"))
        let nested = mine.appending(path: "Contents/Helpers/Helper.app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let policy = fx.policy()

        #expect(policy.evaluate(mine, as: .appBundle) == .allowed)
        #expect(policy.evaluate(inFolder, as: .appBundle) == .allowed)
        #expect(!policy.evaluate(apple, as: .appBundle).isAllowed)
        #expect(!policy.evaluate(itself, as: .appBundle).isAllowed)
        #expect(!policy.evaluate(elsewhere, as: .appBundle).isAllowed)
        #expect(!policy.evaluate(nested, as: .appBundle).isAllowed)

        let otherUser = SafetyPolicy(home: fx.home, applicationsDirectories: [fx.applications], userID: getuid() + 1)
        #expect(!otherUser.evaluate(mine, as: .appBundle).isAllowed, "an app owned by someone else must be refused")
    }

    @Test("Picked files must be regular, visible files outside ~/Library and outside packages")
    func userFiles() throws {
        let fx = try Fixture()
        let movie = try fx.file("Movies/holiday.mov", size: 100)
        let library = try fx.file("Library/Fonts/x.ttf", size: 100)
        let hidden = try fx.file(".config/tool/state.db", size: 100)
        let insideApp = try fx.file("Downloads/Tool.app/Contents/Resources/big.bin", size: 100)
        let folder = try fx.directory("Movies/Clips")
        let policy = fx.policy()

        #expect(policy.evaluate(movie, as: .userFile) == .allowed)
        #expect(!policy.evaluate(library, as: .userFile).isAllowed)
        #expect(!policy.evaluate(hidden, as: .userFile).isAllowed)
        #expect(!policy.evaluate(insideApp, as: .userFile).isAllowed)
        #expect(!policy.evaluate(folder, as: .userFile).isAllowed)
    }

    @Test("Device backups must be folders directly in MobileSync/Backup")
    func backups() throws {
        let fx = try Fixture()
        let backup = try fx.directory("Library/Application Support/MobileSync/Backup/00008110-001A")
        let stray = try fx.file("Library/Application Support/MobileSync/Backup/notes.txt", size: 3)
        #expect(fx.policy().evaluate(backup, as: .iosBackup) == .allowed)
        #expect(!fx.policy().evaluate(stray, as: .iosBackup).isAllowed)
    }

    @Test("A missing item is refused")
    func missing() throws {
        let fx = try Fixture()
        let ghost = fx.home.appending(path: "Library/Caches/com.example.ghost")
        #expect(!fx.policy().evaluate(ghost, as: .userCache).isAllowed)
    }
}
