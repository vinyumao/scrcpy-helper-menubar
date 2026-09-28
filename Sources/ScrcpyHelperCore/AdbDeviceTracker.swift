import Foundation
import Darwin

public enum AdbTrackDevicesFrameError: Error {
    case invalidLength
}

/// `adb track-devices` sends a four-character hexadecimal length before each snapshot.
public struct AdbTrackDevicesFrameParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [String] {
        buffer.append(chunk)
        var snapshots: [String] = []
        while buffer.count >= 4 {
            let header = String(decoding: buffer.prefix(4), as: UTF8.self)
            guard let length = Int(header, radix: 16), length >= 0 else {
                throw AdbTrackDevicesFrameError.invalidLength
            }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: 4..<(4 + length))
            snapshots.append(String(decoding: payload, as: UTF8.self))
            buffer.removeSubrange(0..<(4 + length))
        }
        return snapshots
    }
}

/// Keeps an ADB device-change stream open and reconnects after the ADB server exits.
public final class AdbDeviceTracker: @unchecked Sendable {
    private let adbURL: URL
    private let onSnapshot: @Sendable (String) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var stopped = true

    public init(adbURL: URL, onSnapshot: @escaping @Sendable (String) -> Void) {
        self.adbURL = adbURL
        self.onSnapshot = onSnapshot
    }

    public func start() {
        lock.lock()
        guard stopped else {
            lock.unlock()
            return
        }
        stopped = false
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            await runLoop()
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func register(_ newProcess: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        process = newProcess
        return true
    }

    private func clear(_ finishedProcess: Process) {
        lock.lock()
        defer { lock.unlock() }
        if process === finishedProcess { process = nil }
    }

    private func runLoop() async {
        while isActive {
            let process = Process()
            let output = Pipe()
            process.executableURL = adbURL
            process.arguments = ["track-devices", "-l"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            guard register(process) else { return }

            do {
                try process.run()
                try? output.fileHandleForWriting.close()
                if !isActive, process.isRunning { process.terminate() }

                var parser = AdbTrackDevicesFrameParser()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while isActive {
                    let count = bytes.withUnsafeMutableBytes { buffer in
                        Darwin.read(output.fileHandleForReading.fileDescriptor, buffer.baseAddress, buffer.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    let chunk = Data(bytes.prefix(count))
                    for snapshot in try parser.append(chunk) where isActive {
                        onSnapshot(snapshot)
                    }
                }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            } catch {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()

            clear(process)
            if isActive {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
