import Foundation

/// The only web addresses in BareMac. They open in your browser when you click
/// them; the app itself never connects to anything.
enum Links {
    static let repository = URL(string: "https://github.com/iamirrf/BareMac")!
    static let safety = URL(string: "https://github.com/iamirrf/BareMac/blob/main/docs/safety.md")!
    static let releases = URL(string: "https://github.com/iamirrf/BareMac/releases")!
    static let issues = URL(string: "https://github.com/iamirrf/BareMac/issues")!
}
