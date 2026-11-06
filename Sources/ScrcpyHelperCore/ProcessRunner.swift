import Foundation
import Darwin

public protocol ProcessRunning: Sendable {
    @discardableResult
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

public extension ProcessRunning {
    @discardableResult
    func run(executable: URL, arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await run(executable: executable, arguments: arguments, environment: [:])
    }
}

public enum ProcessExecutionError: LocalizedError, Equatable {
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            return "\(command) 执行超时（\(seconds.formatted()) 秒），请检查设备连接后重试。"
        }
    }
}

public struct FoundationProcessRunner: ProcessRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        precondition(timeout > 0 && timeout.isFinite)
        self.timeout = timeout
    }

    public func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Foundation Process and pipe I/O stay off the main actor and Swift's cooperative executor.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try execute(
                            executable: executable, arguments: arguments,
                            environment: environment, cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String], cancellation: ProcessCancellation) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
        }
        for pipe in [out, err] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        try process.run()
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stoppedAt: TimeInterval?
        var failure: Error?
        var stdout = Data()
        var stderr = Data()
        var descriptors = [out, err].map {
            pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        repeat {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if cancellation.isCancelled {
                    failure = CancellationError()
                } else if now >= deadline {
                    failure = ProcessExecutionError.timedOut(command: executable.lastPathComponent, seconds: timeout)
                }
            }
            if failure != nil, process.isRunning {
                if let stoppedAt {
                    if now - stoppedAt >= 0.25 { kill(process.processIdentifier, SIGKILL) }
                } else {
                    stoppedAt = now
                    process.terminate()
                }
            }
            do {
                if descriptors[0].fd >= 0, try drain(descriptors[0].fd, into: &stdout) { descriptors[0].fd = -1 }
                if descriptors[1].fd >= 0, try drain(descriptors[1].fd, into: &stderr) { descriptors[1].fd = -1 }
            } catch {
                if failure == nil { failure = error }
            }
            guard process.isRunning else { break }
            // A bounded poll keeps both streams moving and makes cancellation responsive.
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0, errno != EINTR, failure == nil {
                failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } while true

        process.waitUntilExit()
        if let failure { throw failure }
        if descriptors[0].fd >= 0 { _ = try drain(descriptors[0].fd, into: &stdout) }
        if descriptors[1].fd >= 0 { _ = try drain(descriptors[1].fd, into: &stderr) }
        if cancellation.isCancelled { throw CancellationError() }
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    private func drain(_ fd: Int32, into data: inout Data) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Bound each turn so a continuously writing process cannot starve timeout checks.
        for _ in 0..<64 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { return true }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        return false
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
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
