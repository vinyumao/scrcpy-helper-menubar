import Foundation

public struct AdbDevice: Sendable, Hashable, Equatable, Identifiable {
    public var sn: String
    public var brand: String
    public var model: String
    public var state: String

    public var id: String { sn }

    public init(sn: String, brand: String, model: String, state: String = "device") {
        self.sn = sn
        self.brand = brand
        self.model = model
        self.state = state
    }

    public var displayName: String { "\(brand) \(model) (\(sn))" }
}

public enum AdbError: LocalizedError, Sendable {
    case adbNotFound
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "未找到 adb，请在设置中配置或安装 Android platform-tools"
        case .commandFailed(let message):
            return "adb 命令失败: \(message)"
        }
    }
}

/// 解析 `adb devices -l` 输出（不含 getprop）。
public enum AdbDevicesParser {
    public struct RawLine: Sendable, Equatable {
        public var sn: String
        public var state: String
        public var product: String?
        public var model: String?

        public init(sn: String, state: String, product: String? = nil, model: String? = nil) {
            self.sn = sn
            self.state = state
            self.product = product
            self.model = model
        }
    }

    public static func parse(_ output: String) -> (ready: [RawLine], unavailableCount: Int) {
        var ready: [RawLine] = []
        var unavailable = 0
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("List") { continue }
            guard let parsed = parseLine(line) else { continue }
            if parsed.state == "device" {
                ready.append(parsed)
            } else {
                unavailable += 1
            }
        }
        return (ready, unavailable)
    }

    public static func parseLine(_ line: String) -> RawLine? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { return nil }
        let sn = parts[0]
        let state = parts[1]
        var product: String?
        var model: String?
        for part in parts.dropFirst(2) {
            if product == nil, part.hasPrefix("product:") {
                product = String(part.dropFirst("product:".count))
            } else if model == nil, part.hasPrefix("model:") {
                model = String(part.dropFirst("model:".count))
            }
        }
        return RawLine(sn: sn, state: state, product: product, model: model)
    }

    public static func sanitizeProp(_ value: String) -> String? {
        let trimmed = value
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("error:") { return nil }
        if trimmed.contains("not found") { return nil }
        return trimmed
    }
}

public struct AdbClient {
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let configuredPath: String?
    private let pathEnvironment: String?

    public init(
        configuredPath: String? = nil,
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.configuredPath = configuredPath
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.pathEnvironment = pathEnvironment
    }

    public func resolveAdbURL() -> URL? {
        ToolPathResolver.resolve(
            name: "adb",
            configuredPath: configuredPath,
            extraCandidates: [
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
                "/opt/homebrew/bin/adb",
                "/usr/local/bin/adb"
            ],
            fileManager: fileManager,
            pathEnvironment: pathEnvironment
        )
    }

    public func listReadyDevices() throws -> (devices: [AdbDevice], unavailableCount: Int) {
        let adb = try requireAdb()
        let result = try processRunner.run(executable: adb, arguments: ["devices", "-l"])
        if result.exitCode != 0 {
            throw AdbError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let parsed = AdbDevicesParser.parse(result.stdout)
        var devices: [AdbDevice] = []
        for line in parsed.ready {
            var brand = try? getProp(sn: line.sn, key: "ro.product.brand", adb: adb)
            if brand == nil {
                brand = try? getProp(sn: line.sn, key: "ro.product.manufacturer", adb: adb)
            }
            if brand == nil {
                brand = line.product
            }
            var model = line.model
            if model == nil {
                model = try? getProp(sn: line.sn, key: "ro.product.model", adb: adb)
            }
            devices.append(
                AdbDevice(
                    sn: line.sn,
                    brand: brand?.isEmpty == false ? brand! : "unknown",
                    model: model?.isEmpty == false ? model! : "unknown"
                )
            )
        }
        return (devices, parsed.unavailableCount)
    }

    private func getProp(sn: String, key: String, adb: URL) throws -> String? {
        let result = try processRunner.run(executable: adb, arguments: ["-s", sn, "shell", "getprop", key])
        return AdbDevicesParser.sanitizeProp(result.stdout)
    }

    private func requireAdb() throws -> URL {
        guard let url = resolveAdbURL() else { throw AdbError.adbNotFound }
        return url
    }
}

public enum ToolPathResolver {
    public static func resolve(
        name: String,
        configuredPath: String?,
        extraCandidates: [String],
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> URL? {
        if let configuredPath, !configuredPath.isEmpty {
            let url = URL(fileURLWithPath: (configuredPath as NSString).standardizingPath)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        if let fromPATH = findInPATH(name, pathEnvironment: pathEnvironment, fileManager: fileManager) {
            return fromPATH
        }

        for path in extraCandidates {
            let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func findInPATH(
        _ name: String,
        pathEnvironment: String?,
        fileManager: FileManager
    ) -> URL? {
        let path = pathEnvironment ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
