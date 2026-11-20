import BareMacCore
import Foundation

/// Formatting shared by every screen.
enum Format {
    /// "2.31 GB"
    static func bytes(_ value: Int64) -> String { ByteText.string(value) }

    /// ("2.31", "GB") for big headline numbers.
    static func splitBytes(_ value: Int64) -> (number: String, unit: String) {
        let text = ByteText.string(value)
        guard let index = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }) else {
            return (text, "")
        }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    /// "Zero KB" reads oddly in a headline; say "0 bytes".
    static func headline(_ value: Int64) -> String {
        value == 0 ? "0 bytes" : bytes(value)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        let number = value.formatted(.number)
        return "\(number) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func path(_ url: URL, home: URL) -> String {
        PathTools.abbreviated(url.path, home: home.path)
    }

    static func path(_ path: String, home: URL) -> String {
        PathTools.abbreviated(path, home: home.path)
    }

    /// Accessible spoken size, e.g. "2.3 gigabytes".
    static func spokenBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: value)
            .replacingOccurrences(of: "KB", with: "kilobytes")
            .replacingOccurrences(of: "MB", with: "megabytes")
            .replacingOccurrences(of: "GB", with: "gigabytes")
            .replacingOccurrences(of: "TB", with: "terabytes")
    }
}
