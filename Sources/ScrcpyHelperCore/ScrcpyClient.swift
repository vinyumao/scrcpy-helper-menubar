import Foundation

public struct ScrcpyLaunchOptions: Sendable, Equatable, Codable {
    public var noAudio: Bool
    public var stayAwake: Bool
    public var maxSize1024: Bool

    public init(noAudio: Bool = true, stayAwake: Bool = true, maxSize1024: Bool = false) {
        self.noAudio = noAudio
        self.stayAwake = stayAwake
        self.maxSize1024 = maxSize1024
    }

    public func arguments(serial: String) -> [String] {
        var args = ["-s", serial]
        if noAudio { args.append("--no-audio") }
        if stayAwake { args.append("--stay-awake") }
        if maxSize1024 { args.append("--max-size=1024") }
        return args
    }
}

public enum ScrcpyError: LocalizedError, Sendable {
    case scrcpyNotFound
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scrcpyNotFound:
            return "未找到 scrcpy，请在设置中配置或执行 brew install scrcpy"
        case .launchFailed(let message):
            return "启动 scrcpy 失败: \(message)"
        }
    }
}

public protocol ScrcpyLaunching: Sendable {
    /// 启动 scrcpy 并返回进程 pid，便于调用方随后激活窗口。
    @discardableResult
    func launch(executable: URL, arguments: [String]) throws -> Int32
}

public struct FoundationScrcpyLauncher: ScrcpyLaunching {
    public init() {}

    @discardableResult
    public func launch(executable: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // 保留引用，避免调用方尚未读到 pid 前对象被提前释放（子进程仍会继续跑）。
        RunningScrcpyProcesses.retain(process)
        do {
            try process.run()
            return process.processIdentifier
        } catch {
            RunningScrcpyProcesses.release(process)
            throw ScrcpyError.launchFailed(error.localizedDescription)
        }
    }
}

enum RunningScrcpyProcesses {
    private static let lock = NSLock()
    private static var processes: [Process] = []

    static func retain(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.append(process)
        processes.removeAll { !$0.isRunning && $0.processIdentifier != process.processIdentifier }
    }

    static func release(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.removeAll { $0 === process }
    }
}

public struct ScrcpyClient {
    private let processRunner: any ProcessRunning
    private let launcher: any ScrcpyLaunching
    private let fileManager: FileManager
    private let configuredPath: String?
    private let pathEnvironment: String?

    public init(
        configuredPath: String? = nil,
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        launcher: any ScrcpyLaunching = FoundationScrcpyLauncher(),
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.configuredPath = configuredPath
        self.processRunner = processRunner
        self.launcher = launcher
        self.fileManager = fileManager
        self.pathEnvironment = pathEnvironment
    }

    public func resolveScrcpyURL() -> URL? {
        ToolPathResolver.resolve(
            name: "scrcpy",
            configuredPath: configuredPath,
            extraCandidates: [
                "/opt/homebrew/bin/scrcpy",
                "/usr/local/bin/scrcpy"
            ],
            fileManager: fileManager,
            pathEnvironment: pathEnvironment
        )
    }

    @discardableResult
    public func launch(serial: String, options: ScrcpyLaunchOptions) throws -> Int32 {
        guard let scrcpy = resolveScrcpyURL() else { throw ScrcpyError.scrcpyNotFound }
        let args = options.arguments(serial: serial)
        return try launcher.launch(executable: scrcpy, arguments: args)
    }

    /// 用于探测 scrcpy 是否能执行（可选 `--version`）。
    public func versionString() throws -> String? {
        guard let scrcpy = resolveScrcpyURL() else { throw ScrcpyError.scrcpyNotFound }
        let result = try processRunner.run(executable: scrcpy, arguments: ["--version"])
        if result.exitCode != 0 {
            throw ScrcpyError.launchFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
