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
    case adbNotFound
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scrcpyNotFound:
            return "未找到 scrcpy，请在设置中配置或执行 brew install scrcpy"
        case .adbNotFound:
            return "未找到 adb，请在设置中配置或安装 Android platform-tools"
        case .launchFailed(let message):
            return "启动 scrcpy 失败: \(message)"
        }
    }
}

public protocol ScrcpyLaunching: Sendable {
    /// 启动 scrcpy 并返回进程 pid，便于调用方随后激活窗口。
    /// 若进程以非零状态退出，回调会带回 scrcpy 的错误输出。
    @discardableResult
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onFailure: @escaping @Sendable (String) -> Void
    ) throws -> Int32
}

public struct FoundationScrcpyLauncher: ScrcpyLaunching {
    public init() {}

    @discardableResult
    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onFailure: @escaping @Sendable (String) -> Void
    ) throws -> Int32 {
        let process = Process()
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrcpy-helper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        process.executableURL = executable
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorFile
        process.terminationHandler = { finishedProcess in
            try? errorFile.close()
            defer {
                try? FileManager.default.removeItem(at: errorURL)
                RunningScrcpyProcesses.release(finishedProcess)
            }
            guard finishedProcess.terminationStatus != 0 else { return }
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            onFailure(detail.isEmpty ? "scrcpy 意外退出（退出码 \(finishedProcess.terminationStatus)）" : detail)
        }
        // 保留引用，避免调用方尚未读到 pid 前对象被提前释放（子进程仍会继续跑）。
        RunningScrcpyProcesses.retain(process)
        do {
            try process.run()
            return process.processIdentifier
        } catch {
            RunningScrcpyProcesses.release(process)
            try? errorFile.close()
            try? FileManager.default.removeItem(at: errorURL)
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
    private let configuredAdbPath: String?
    private let pathEnvironment: String?

    public init(
        configuredPath: String? = nil,
        configuredAdbPath: String? = nil,
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        launcher: any ScrcpyLaunching = FoundationScrcpyLauncher(),
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.configuredPath = configuredPath
        self.configuredAdbPath = configuredAdbPath
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
    public func launch(
        serial: String,
        options: ScrcpyLaunchOptions,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> Int32 {
        guard let scrcpy = resolveScrcpyURL() else { throw ScrcpyError.scrcpyNotFound }
        guard let adb = AdbClient(
            configuredPath: configuredAdbPath,
            fileManager: fileManager,
            pathEnvironment: pathEnvironment
        ).resolveAdbURL() else { throw ScrcpyError.adbNotFound }
        let args = options.arguments(serial: serial)
        return try launcher.launch(
            executable: scrcpy,
            arguments: args,
            environment: ["ADB": adb.path],
            onFailure: onFailure
        )
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
