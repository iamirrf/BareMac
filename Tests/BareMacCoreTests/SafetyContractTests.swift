import Foundation
import Testing
@testable import BareMacCore

/// Proves the safety contract at the source level: the code that ships can't delete,
/// can't empty the Trash, can't reach the network, and can't ask for privileges.
@Suite("Safety contract: what the shipped code can and can't do")
struct SafetyContractTests {
    struct SourceFile {
        let relativePath: String
        let text: String
    }

    /// Every Swift file under Sources/, with comments stripped so documentation that
    /// *mentions* a forbidden API doesn't count.
    static let sources: [SourceFile] = {
        let testsFolder = URL(filePath: #filePath).deletingLastPathComponent()
        let root = testsFolder.deletingLastPathComponent().deletingLastPathComponent()
        let sourcesFolder = root.appending(path: "Sources")
        var files: [SourceFile] = []
        let enumerator = FileManager.default.enumerator(atPath: sourcesFolder.path)
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let text = (try? String(contentsOf: sourcesFolder.appending(path: relative), encoding: .utf8)) ?? ""
            files.append(SourceFile(relativePath: relative, text: stripComments(text)))
        }
        return files
    }()

    static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
            return String(line)
        }.joined(separator: "\n")
    }

    static func files(matching pattern: String) -> [String] {
        let regex = try! Regex(pattern)
        return sources.filter { $0.text.contains(regex) }.map(\.relativePath)
    }

    @Test("Sources were found")
    func sourcesExist() {
        #expect(Self.sources.count >= 10)
        #expect(Self.sources.contains { $0.relativePath.hasSuffix("Engine/FileEngine.swift") })
    }

    @Test("Nothing can permanently delete a file")
    func noDeletion() {
        for pattern in [#"removeItem\s*\("#, #"\bunlink\s*\("#, #"\brmdir\s*\("#, #"\bremovefile\s*\("#,
                        #"\bDarwin\.remove\s*\("#, #"\btruncate\s*\("#, #"\bexchangedata\s*\("#, #"\brm\s+-"#] {
            #expect(Self.files(matching: pattern).isEmpty, "found \(pattern) in \(Self.files(matching: pattern))")
        }
    }

    @Test("Nothing can empty the Trash")
    func noEmptyTrash() {
        for pattern in [#"(?i)emptyTrash"#, #"(?i)empty\s+the\s+trash"#, #"(?i)empty\s+trash"#] {
            let offenders = Self.files(matching: pattern).filter { !$0.hasPrefix("BareMac/") }
            #expect(offenders.isEmpty, "found \(pattern) in \(offenders)")
        }
    }

    @Test("Only the file engine moves files")
    func onlyEngineMoves() {
        for pattern in [#"trashItem\s*\("#, #"moveItem\s*\("#, #"\brename\s*\("#, #"\brenameat\s*\("#, #"replaceItem"#, #"\brecycle\s*\("#] {
            let offenders = Self.files(matching: pattern).filter { $0 != "BareMacCore/Engine/FileEngine.swift" }
            #expect(offenders.isEmpty, "found \(pattern) outside FileEngine.swift: \(offenders)")
        }
    }

    @Test("No networking of any kind")
    func noNetwork() {
        let patterns = [#"URLSession"#, #"NSURLConnection"#, #"import\s+Network\b"#, #"NWConnection"#, #"NWPathMonitor"#,
                        #"CFSocket"#, #"CFStream"#, #"\bsocket\s*\("#, #"\bconnect\s*\("#, #"getaddrinfo"#,
                        #"URLRequest"#, #"WKWebView"#, #"import\s+WebKit\b"#, #"Data\(contentsOf:\s*URL\(string"#]
        for pattern in patterns {
            #expect(Self.files(matching: pattern).isEmpty, "found \(pattern) in \(Self.files(matching: pattern))")
        }
        let webLinks = Self.files(matching: #"https?://"#).filter { $0 != "BareMac/Support/Links.swift" }
        #expect(webLinks.isEmpty, "web addresses may only appear in Links.swift (opened in the user's browser): \(webLinks)")
    }

    @Test("No privileges: no sudo, no helper tools, no authorization")
    func noPrivileges() {
        for pattern in [#"\bsudo\b"#, #"AuthorizationExecuteWithPrivileges"#, #"AuthorizationCreate"#, #"SMJobBless"#,
                        #"SMAppService\.daemon"#, #"\bsetuid\s*\("#, #"with administrator privileges"#] {
            #expect(Self.files(matching: pattern).isEmpty, "found \(pattern) in \(Self.files(matching: pattern))")
        }
    }

    @Test("Only the launchctl wrapper starts other programs")
    func processesOnlyForLaunchctl() {
        let offenders = Self.files(matching: #"\bProcess\s*\(|posix_spawn|NSTask|(^|[^.\w])system\s*\(|popen\s*\("#)
            .filter { $0 != "BareMacCore/System/LaunchControl.swift" }
        #expect(offenders.isEmpty, "found process launching in \(offenders)")
    }

    @Test("The core library has no UI imports")
    func coreHasNoUI() {
        let offenders = Self.sources.filter { $0.relativePath.hasPrefix("BareMacCore/") }
            .filter { $0.text.contains(try! Regex(#"import\s+(SwiftUI|AppKit|UIKit|Cocoa|QuickLookUI)\b"#)) }
            .map(\.relativePath)
        #expect(offenders.isEmpty, "UI imports in BareMacCore: \(offenders)")
    }

    @Test("Information-only items can never pass the allowlist")
    func informationOnlyAlwaysDenied() throws {
        let fx = try Fixture()
        let cache = try fx.directory("Library/Caches/com.example.anything")
        #expect(!fx.policy().evaluate(cache, as: .informationOnly).isAllowed)
    }

    @Test("Uninstall may take plain-named app folders; leftovers may not; shared vendor folders never")
    func plainNamesOnlyForUninstall() throws {
        let fx = try Fixture()
        let slack = try fx.directory("Library/Application Support/Slack")
        let google = try fx.directory("Library/Application Support/Google")
        let policy = fx.policy()
        #expect(policy.evaluate(slack, as: .appFile) == .allowed)
        #expect(!policy.evaluate(slack, as: .appLeftover).isAllowed)
        #expect(!policy.evaluate(google, as: .appFile).isAllowed)
    }

    @Test("ItemBuilder only offers items the allowlist accepts and that were fully measured")
    func itemBuilderGate() throws {
        let fx = try Fixture()
        let builder = ItemBuilder(policy: fx.policy())
        let good = try fx.directory("Library/Caches/com.example.ok")
        try fx.file("a", size: 5_000, under: good)
        let outside = try fx.file("x.bin", size: 5_000, under: fx.outside)

        let offered = try builder.make(url: good, category: .userCache, name: "ok", explanation: "", suggested: true)
        #expect(offered.isCleanable && offered.isSuggested)
        #expect(offered.bytes == foundationAllocatedSize(good))

        let refused = try builder.make(url: outside, category: .userCache, name: "x", explanation: "", suggested: true)
        #expect(!refused.isCleanable && !refused.isSuggested && refused.infoReason != nil)

        let locked = try fx.directory("Library/Caches/com.example.locked")
        let inner = try fx.directory("inner", under: locked)
        try fx.file("b", size: 100, under: inner)
        chmod(inner.path, 0o000)
        defer { chmod(inner.path, 0o755) }
        let partial = try builder.make(url: locked, category: .userCache, name: "locked", explanation: "", suggested: true)
        #expect(!partial.isCleanable)
        #expect(partial.infoReason == ItemBuilder.incompleteReason)
    }
}
