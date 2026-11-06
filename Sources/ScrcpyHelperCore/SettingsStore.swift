import Foundation

public struct DeviceSettings: Codable, Sendable, Equatable {
    public var alias: String
    /// nil inherits the current global options, including future changes.
    public var launchOptions: ScrcpyLaunchOptions?
    public var preferredDisplayId: Int?

    public init(alias: String = "", launchOptions: ScrcpyLaunchOptions? = nil, preferredDisplayId: Int? = nil) {
        self.alias = alias
        self.launchOptions = launchOptions
        self.preferredDisplayId = preferredDisplayId
    }

    private enum CodingKeys: String, CodingKey { case alias, launchOptions, preferredDisplayId }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alias = try values.decodeIfPresent(String.self, forKey: .alias) ?? ""
        launchOptions = try values.decodeIfPresent(ScrcpyLaunchOptions.self, forKey: .launchOptions)
        preferredDisplayId = try values.decodeIfPresent(Int.self, forKey: .preferredDisplayId)
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var adbPath: String?
    public var scrcpyPath: String?
    public var launchOptions: ScrcpyLaunchOptions
    public var devices: [String: DeviceSettings]

    public init(
        adbPath: String? = nil,
        scrcpyPath: String? = nil,
        launchOptions: ScrcpyLaunchOptions = ScrcpyLaunchOptions(),
        devices: [String: DeviceSettings] = [:]
    ) {
        self.adbPath = adbPath
        self.scrcpyPath = scrcpyPath
        self.launchOptions = launchOptions
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey { case adbPath, scrcpyPath, launchOptions, devices }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        adbPath = try values.decodeIfPresent(String.self, forKey: .adbPath)
        scrcpyPath = try values.decodeIfPresent(String.self, forKey: .scrcpyPath)
        launchOptions = try values.decodeIfPresent(ScrcpyLaunchOptions.self, forKey: .launchOptions) ?? ScrcpyLaunchOptions()
        devices = try values.decodeIfPresent([String: DeviceSettings].self, forKey: .devices) ?? [:]
    }

    public func options(for serial: String) -> ScrcpyLaunchOptions {
        devices[serial]?.launchOptions ?? launchOptions
    }

    public func alias(for serial: String) -> String? {
        let alias = devices[serial]?.alias.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return alias.isEmpty ? nil : alias
    }

    public func preferredDisplay(for serial: String, available: [Int]?) -> Int? {
        guard let preferred = devices[serial]?.preferredDisplayId else { return nil }
        // A disconnected secondary display must not break the default launch action.
        if let available, !available.contains(preferred) { return nil }
        return preferred
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: AppSettings
    private var needsBackup = false
    public let loadWarning: String?

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("settings.json")
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                self.cache = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL))
                self.loadWarning = nil
            } catch {
                self.cache = AppSettings()
                self.needsBackup = true
                self.loadWarning = "配置读取失败，暂用默认配置；下次保存前会备份原文件。\n\(error.localizedDescription)"
            }
        } else {
            self.cache = AppSettings()
            self.loadWarning = nil
        }
    }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func update(_ mutate: (inout AppSettings) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = cache
        mutate(&updated)
        try persistLocked(updated)
        cache = updated
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try persistLocked(settings)
        cache = settings
    }

    private func persistLocked(_ settings: AppSettings) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if needsBackup {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("settings-backup-\(UUID().uuidString).json")
            try fileManager.copyItem(at: fileURL, to: backup)
            needsBackup = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
