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

    let settingsStore: SettingsStore
    let appSupportURL: URL
    private var deviceTracker: AdbDeviceTracker?
    private var trackedAdbURL: URL?
    private var trackedRefreshTask: Task<Void, Never>?
    private var displayRefreshTask: Task<Void, Never>?
    private var displayRefreshGeneration = 0

    init() {
        let support = AppPaths.applicationSupportDirectory()
        let store = SettingsStore(appSupportDirectory: support)
        let loaded = store.load()
        self.appSupportURL = support
        self.settingsStore = store
        self.settings = loaded
        self.toolStatus = ToolDetector.check(settings: loaded)
        refresh()
    }

    var canLaunchScrcpy: Bool { toolStatus.allReady }

    func refresh() {
        trackedRefreshTask?.cancel()
        displayRefreshTask?.cancel()
        displayRefreshGeneration += 1
        isRefreshing = true
        defer { isRefreshing = false }

        let current = settingsStore.load()
        settings = current
        toolStatus = ToolDetector.check(settings: current)
        configureDeviceTracker(adbPath: current.adbPath)

        guard toolStatus.adbFound else {
            devices = []
            displayLookups = [:]
            unavailableCount = 0
            return
        }

        do {
            let client = AdbClient(configuredPath: current.adbPath)
            let result = try client.listReadyDevices()
            devices = result.devices
            unavailableCount = result.unavailableCount
            lastError = nil
            if toolStatus.scrcpyFound {
                refreshDisplays(for: result.devices, settings: current)
            } else {
                displayLookups = [:]
            }
        } catch {
            devices = []
            displayLookups = [:]
            unavailableCount = 0
            lastError = error.localizedDescription
        }
    }

    private func configureDeviceTracker(adbPath: String?) {
        let adbURL = AdbClient(configuredPath: adbPath).resolveAdbURL()
        guard adbURL != trackedAdbURL else { return }
        deviceTracker?.stop()
        deviceTracker = nil
        trackedAdbURL = adbURL
        guard let adbURL else { return }
        let tracker = AdbDeviceTracker(adbURL: adbURL) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.handleTrackedDevices(snapshot)
            }
        }
        deviceTracker = tracker
        tracker.start()
    }

    private func handleTrackedDevices(_ snapshot: String) {
        let parsed = AdbDevicesParser.parse(snapshot)
        let readySerials = Set(parsed.ready.map(\.sn))
        let currentSerials = Set(devices.map(\.sn))
        guard readySerials != currentSerials || parsed.unavailableCount != unavailableCount else { return }
        trackedRefreshTask?.cancel()
        trackedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refreshDisplays(for devices: [AdbDevice], settings: AppSettings) {
        displayLookups = Dictionary(uniqueKeysWithValues: devices.map {
            ($0.sn, displayLookups[$0.sn] ?? .checking)
        })
        let scrcpyPath = settings.scrcpyPath
        let adbPath = settings.adbPath
        let generation = displayRefreshGeneration
        displayRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let client = ScrcpyClient(configuredPath: scrcpyPath, configuredAdbPath: adbPath)
            for device in devices {
                guard !Task.isCancelled else { return }
                let lookup: DisplayLookup
                do {
                    lookup = .available(try client.listDisplays(serial: device.sn))
                } catch {
                    lookup = .failed
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.displayRefreshGeneration == generation else { return }
                    self.displayLookups[device.sn] = lookup
                }
            }
        }
    }

    func updateLaunchOptions(_ mutate: (inout ScrcpyLaunchOptions) -> Void) {
        settingsStore.update { settings in
            mutate(&settings.launchOptions)
        }
        settings = settingsStore.load()
    }

    func saveSettings(_ newSettings: AppSettings) {
        settingsStore.save(newSettings)
        settings = newSettings
        refresh()
    }

    func launch(device: AdbDevice, displayId: Int? = nil) {
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
            let pid = try client.launch(serial: device.sn, displayId: displayId, options: settings.launchOptions) { [weak self] message in
                Task { @MainActor in
                    self?.lastError = "scrcpy 已退出：\(message)"
                }
            }
            WindowFront.scheduleActivateScrcpy(pid: pid)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func launchAllDisplays(device: AdbDevice, displayIds: [Int]) {
        guard launchingAllSerials.insert(device.sn).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.launchingAllSerials.remove(device.sn) }
            for (index, displayId) in displayIds.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
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
        deviceTracker?.stop()
    }
}
