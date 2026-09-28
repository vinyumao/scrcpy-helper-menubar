import Foundation

public protocol ProcessRunning: Sendable {
    @discardableResult
    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> (exitCode: Int32, stdout: String, stderr: String)
}

public extension ProcessRunning {
    @discardableResult
    func run(executable: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try run(executable: executable, arguments: arguments, environment: [:])
    }
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

public enum AppPaths {
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ScrcpyHelper", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension JSONEncoder {
    public static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
