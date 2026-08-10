import Foundation

public struct AppSettings: Codable, Sendable, Equatable {
    public var adbPath: String?
    public var scrcpyPath: String?
    public var launchOptions: ScrcpyLaunchOptions

    public init(
        adbPath: String? = nil,
        scrcpyPath: String? = nil,
        launchOptions: ScrcpyLaunchOptions = ScrcpyLaunchOptions()
    ) {
        self.adbPath = adbPath
        self.scrcpyPath = scrcpyPath
        self.launchOptions = launchOptions
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: AppSettings

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = appSupportDirectory.appendingPathComponent("settings.json")
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.cache = decoded
        } else {
            self.cache = AppSettings()
            persistLocked()
        }
    }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&cache)
        persistLocked()
    }

    public func save(_ settings: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        cache = settings
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.pretty.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
