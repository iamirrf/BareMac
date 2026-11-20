import Darwin
import Foundation

/// The parts of `launchctl` BareMac uses, so tests can substitute a fake.
public protocol LaunchControlling: Sendable {
    /// Overrides in the user's launchd domain: label → `true` if disabled.
    func disabledLabels() throws -> [String: Bool]
    /// Labels currently loaded in the user's session.
    func loadedLabels() throws -> Set<String>
    func disable(label: String) throws
    func enable(label: String) throws
    func bootout(label: String) throws
    func bootstrap(plist: URL) throws
}

public enum LaunchControlError: Error, LocalizedError, Equatable {
    case invalidLabel(String)
    case failed(command: String, status: Int32, output: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidLabel(label): "“\(label)” isn't a label BareMac can safely pass to launchctl."
        case let .failed(command, status, output): "launchctl \(command) failed (\(status)): \(output)"
        case let .timedOut(command): "launchctl \(command) didn't answer in time."
        }
    }
}

/// Runs `/bin/launchctl` in the signed-in user's own `gui/<uid>` domain. Never with
/// `sudo`, never for system-wide items. This file is the only place in BareMac that
/// starts another program.
public struct SystemLaunchControl: LaunchControlling {
    public let userID: uid_t

    public init(userID: uid_t = getuid()) {
        self.userID = userID
    }

    var domain: String { "gui/\(userID)" }

    public func disabledLabels() throws -> [String: Bool] {
        Self.parseDisabled(try run(["print-disabled", domain]).output)
    }

    public func loadedLabels() throws -> Set<String> {
        Self.parseList(try run(["list"]).output)
    }

    public func disable(label: String) throws {
        try Self.validate(label)
        try run(["disable", "\(domain)/\(label)"], allowed: [0])
    }

    public func enable(label: String) throws {
        try Self.validate(label)
        try run(["enable", "\(domain)/\(label)"], allowed: [0])
    }

    /// Stops the item now. "Not loaded" counts as success.
    public func bootout(label: String) throws {
        try Self.validate(label)
        try run(["bootout", "\(domain)/\(label)"], allowed: [0, 3, 36, 113])
    }

    /// Loads the item now. "Already loaded" counts as success.
    public func bootstrap(plist: URL) throws {
        let result = try run(["bootstrap", domain, plist.path], allowed: [0, 5, 17, 37])
        if result.status == 5, !result.output.localizedCaseInsensitiveContains("already") {
            throw LaunchControlError.failed(command: "bootstrap", status: 5, output: result.output)
        }
    }

    // MARK: Parsing (static so tests can feed real launchctl output)

    /// `"com.example.agent" => disabled` (macOS 13+) or `=> true` (older).
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var inServices = false
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("disabled services") { inServices = true; continue }
            if line == "}" { inServices = false; continue }
            guard inServices, line.hasPrefix("\""), let arrow = line.range(of: "=>") else { continue }
            let label = line[line.index(after: line.startIndex)..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    /// `launchctl list`: tab-separated PID, status, label, with a header line.
    public static func parseList(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let label = String(columns[2]).trimmingCharacters(in: .whitespaces)
            if label == "Label" { continue }
            labels.insert(label)
        }
        return labels
    }

    static func validate(_ label: String) throws {
        guard !label.isEmpty, label.count <= 255,
              label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { throw LaunchControlError.invalidLabel(label) }
    }

    // MARK: Running launchctl

    @discardableResult
    private func run(_ arguments: [String], allowed: Set<Int32> = [0]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        var data = Data()
        let handle = pipe.fileHandleForReading
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw LaunchControlError.timedOut(arguments.first ?? "")
            }
            data.append(handle.availableData)
        }
        data.append(handle.readDataToEndOfFile())
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus
        guard allowed.contains(status) else {
            throw LaunchControlError.failed(command: arguments.first ?? "", status: status, output: output)
        }
        return (status, output)
    }
}
