import Foundation
import Testing
@testable import BareMacCore

extension Fixture {
    /// Every cleanable item must pass the allowlist for its category, and nothing
    /// outside the fixture home or app folders may ever be offered.
    func expectOnlyAllowedOffered(_ items: [FoundItem], sourceLocation: SourceLocation = #_sourceLocation) {
        let policy = policy()
        for item in items where item.isCleanable {
            #expect(policy.evaluate(item.url, as: item.category) == .allowed,
                    "offered \(item.url.path) as \(item.category) but the policy refuses it", sourceLocation: sourceLocation)
            #expect(!item.url.path.hasPrefix(outside.path), "offered a decoy outside home", sourceLocation: sourceLocation)
        }
        for item in items where !item.isCleanable {
            #expect(!item.isSuggested, "an information-only item must never be suggested", sourceLocation: sourceLocation)
            #expect(item.infoReason != nil, "information-only items explain why", sourceLocation: sourceLocation)
        }
    }

    /// Decoys a scanner must never offer: documents, keychains, iCloud Drive, and files outside home.
    @discardableResult
    func plantDecoys() throws -> [URL] {
        [
            try file("Documents/Taxes 2025.pdf", size: 40_000),
            try file("Library/Keychains/login.keychain-db", size: 8_000),
            try file("Library/Mobile Documents/com~apple~CloudDocs/notes.txt", size: 8_000),
            try file("Library/Caches/com.apple.bird/state.db", size: 8_000),
            try file("decoy-cache/data.bin", size: 50_000, under: outside),
        ]
    }

    /// The URLs of every item, for "never offered" checks.
    static func paths(_ items: [FoundItem]) -> Set<String> { Set(items.map(\.url.path)) }
}
