import AppKit
import Combine
import Foundation
import ScrcpyHelperCore
import SwiftUI

enum DisplayLookup: Equatable {
    case checking
    case available([Int])
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var toolStatus: ToolStatus
    @Published var devices: [AdbDevice] = []
    @Published var displayLookups: [String: DisplayLookup] = [:]
    @Published var launchingAllSerials: Set<String> = []
    @Published var unavailableCount: Int = 0
    @Published var isRefreshing: Bool = false
    @Published var lastError: String?
    @Published var showInstallHint: Bool = false
    @Published var installHintText: String = ""
    @Published var settingsDeviceSerial: String?
    @Published var settingsRequestId = UUID()

    let settingsStore: SettingsStore
    let appSupportURL: URL
    private let processRunner: any ProcessRunning
    private let tracksDevices: Bool
    private var deviceTracker: AdbDeviceTracker?
    private var trackedAdbURL: URL?
    private var trackedRefreshTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var trackerGeneration = 0
    private var lastTrackedSnapshot: String?
    private var lastRefreshedAt: Date?
    private var launchAllTasks: [String: Task<Void, Never>] = [:]

    init(
        appSupportURL: URL = AppPaths.applicationSupportDirectory(),
        processRunner: any ProcessRunning = FoundationProcessRunner(),
        tracksDevices: Bool = true
    ) {
        let store = SettingsStore(appSupportDirectory: appSupportURL)
        let loaded = store.load()
        self.appSupportURL = appSupportURL
        self.processRunner = processRunner
        self.tracksDevices = tracksDevices
        self.settingsStore = store
        self.settings = loaded
        self.toolStatus = ToolDetector.check(settings: loaded)
        self.lastError = store.loadWarning
        refresh()
    }

    var canLaunchScrcpy: Bool { toolStatus.allReady }

    func refreshIfNeeded() {
        guard !isRefreshing else { return }
        if let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < 5 { return }
        refresh(force: false)
    }

    func refresh(force: Bool = true) {
        trackedRefreshTask?.cancel()
        refreshTask?.cancel()
        displayRefreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true

        let current = settingsStore.load()
        settings = current
        toolStatus = ToolDetector.check(settings: current)
        configureDeviceTracker(adbPath: current.adbPath)
        guard toolStatus.adbFound else {
            devices = []
            displayLookups = [:]
            unavailableCount = 0
            isRefreshing = false
            return
        }

        let known = force ? [:] : Dictionary(uniqueKeysWithValues: devices.map { ($0.sn, $0) })
        let runner = processRunner
        refreshTask = Task { [weak self] in
            do {
                let result = try await AdbClient(configuredPath: current.adbPath, processRunner: runner).listReadyDevices(knownDevices: known)
                guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
                self.devices = result.devices
                self.unavailableCount = result.unavailableCount
                self.lastRefreshedAt = Date()
                self.isRefreshing = false
                if self.toolStatus.scrcpyFound {
                    self.refreshDisplays(for: result.devices, settings: current, force: force, generation: generation)
                } else {
                    self.displayLookups = [:]
                }
            } catch {
                guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
                self.devices = []
                self.displayLookups = [:]
                self.unavailableCount = 0
                self.isRefreshing = false
                self.lastError = error.localizedDescription
            }
        }
    }

    private func configureDeviceTracker(adbPath: String?) {
        guard tracksDevices else { return }
        let adbURL = AdbClient(configuredPath: adbPath).resolveAdbURL()
        guard adbURL != trackedAdbURL else { return }
        deviceTracker?.stop()
        deviceTracker = nil
        trackedAdbURL = adbURL
        trackerGeneration += 1
        lastTrackedSnapshot = nil
        let generation = trackerGeneration
        guard let adbURL else { return }
        let tracker = AdbDeviceTracker(adbURL: adbURL) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.trackerGeneration == generation else { return }
                self.handleTrackedDevices(snapshot)
            }
        }
        deviceTracker = tracker
        tracker.start()
    }

    private func handleTrackedDevices(_ snapshot: String) {
        guard snapshot != lastTrackedSnapshot else { return }
        lastTrackedSnapshot = snapshot
        let parsed = AdbDevicesParser.parse(snapshot)
        let readySerials = Set(parsed.ready.map(\.sn))
        let currentSerials = Set(devices.map(\.sn))
        guard readySerials != currentSerials || parsed.unavailableCount != unavailableCount else { return }
        // Evict screens immediately: a reconnect may expose a different set of displays.
        displayLookups = displayLookups.filter { readySerials.contains($0.key) }
        trackedRefreshTask?.cancel()
        trackedRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh(force: false)
        }
    }

    private func refreshDisplays(for devices: [AdbDevice], settings: AppSettings, force: Bool, generation: Int) {
        displayLookups = Dictionary(uniqueKeysWithValues: devices.map { device in
            if !force, case .available(let ids) = displayLookups[device.sn] {
                return (device.sn, .available(ids))
            }
            return (device.sn, .checking)
        })
        let pending = devices.filter { displayLookups[$0.sn] == .checking }
        let runner = processRunner
        displayRefreshTask = Task { [weak self] in
            let client = ScrcpyClient(configuredPath: settings.scrcpyPath, configuredAdbPath: settings.adbPath, processRunner: runner)
            for device in pending {
                guard !Task.isCancelled else { return }
                let lookup: DisplayLookup
                do {
                    lookup = .available(try await client.listDisplays(serial: device.sn))
                } catch {
                    guard !Task.isCancelled else { return }
                    lookup = .failed
                }
                guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
                self.displayLookups[device.sn] = lookup
            }
        }
    }

    func displayIds(for serial: String) -> [Int]? {
        if case .available(let ids) = displayLookups[serial] { return ids }
        return nil
    }

    func preferredDisplay(for serial: String) -> Int? {
        settings.preferredDisplay(for: serial, available: displayIds(for: serial))
    }

    func deviceTitle(_ device: AdbDevice) -> String {
        guard let alias = settings.alias(for: device.sn) else { return device.displayName }
        return "\(alias) (\(device.sn))"
    }

    func requestSettings(for serial: String? = nil) {
        settingsDeviceSerial = serial
        settingsRequestId = UUID()
    }

    func updateLaunchOptions(_ mutate: (inout ScrcpyLaunchOptions) -> Void) {
        persistSettings { mutate(&$0.launchOptions) }
    }

    @discardableResult
    func saveSettings(_ newSettings: AppSettings) -> Bool {
        // A settings window may have been open while a device profile changed.
        let saved = persistSettings {
            $0.adbPath = newSettings.adbPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.scrcpyPath = newSettings.scrcpyPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.launchOptions = newSettings.launchOptions
        }
        if saved { refresh() }
        return saved
    }

    @discardableResult
    func saveDeviceSettings(_ profile: DeviceSettings, serial: String) -> Bool {
        persistSettings {
            var normalized = profile
            normalized.alias = normalized.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.devices[serial] = normalized
        }
    }

    @discardableResult
    private func persistSettings(_ mutate: (inout AppSettings) -> Void) -> Bool {
        do {
            try settingsStore.update(mutate)
            settings = settingsStore.load()
            return true
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
            return false
        }
    }

    func launch(device: AdbDevice, displayId: Int? = nil, rememberSelection: Bool = false) {
        guard toolStatus.allReady else {
            presentInstallHint()
            return
        }
        do {
            lastError = nil
            let client = ScrcpyClient(
                configuredPath: settings.scrcpyPath,
                configuredAdbPath: settings.adbPath
            )
            let title = settings.alias(for: device.sn) ?? "\(device.brand) \(device.model)"
            let windowTitle = displayId.map { "\(title) · 屏幕 \($0)" } ?? title
            let pid = try client.launch(
                serial: device.sn, displayId: displayId,
                options: settings.options(for: device.sn), windowTitle: windowTitle
            ) { [weak self] message in
                Task { @MainActor in
                    self?.lastError = "\(windowTitle) 的 scrcpy 已退出：\(message)"
                }
            }
            if rememberSelection {
                persistSettings { $0.devices[device.sn, default: DeviceSettings()].preferredDisplayId = displayId }
            }
            WindowFront.scheduleActivateScrcpy(pid: pid)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func launchAllDisplays(device: AdbDevice, displayIds: [Int]) {
        guard launchingAllSerials.insert(device.sn).inserted else { return }
        launchAllTasks[device.sn] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.launchingAllSerials.remove(device.sn)
                self.launchAllTasks[device.sn] = nil
            }
            for (index, displayId) in displayIds.enumerated() {
                if index > 0 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                self.launch(device: device, displayId: displayId)
            }
        }
    }

    func presentInstallHint() {
        installHintText = ToolDetector.installHint(for: toolStatus)
        showInstallHint = true
    }

    func openAppSupport() {
        NSWorkspace.shared.open(appSupportURL)
    }

    func copyInstallHintToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installHintText, forType: .string)
    }

    func stopTracking() {
        trackedRefreshTask?.cancel()
        displayRefreshTask?.cancel()
        refreshTask?.cancel()
        refreshGeneration += 1
        trackerGeneration += 1
        isRefreshing = false
        for task in launchAllTasks.values { task.cancel() }
        deviceTracker?.stop()
        deviceTracker = nil
        trackedAdbURL = nil
    }
}
