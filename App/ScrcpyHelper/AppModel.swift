import AppKit
import Combine
import Foundation
import ScrcpyHelperCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var toolStatus: ToolStatus
    @Published var devices: [AdbDevice] = []
    @Published var unavailableCount: Int = 0
    @Published var isRefreshing: Bool = false
    @Published var lastError: String?
    @Published var showInstallHint: Bool = false
    @Published var installHintText: String = ""

    let settingsStore: SettingsStore
    let appSupportURL: URL

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
        isRefreshing = true
        defer { isRefreshing = false }

        let current = settingsStore.load()
        settings = current
        toolStatus = ToolDetector.check(settings: current)

        guard toolStatus.adbFound else {
            devices = []
            unavailableCount = 0
            return
        }

        do {
            let client = AdbClient(configuredPath: current.adbPath)
            let result = try client.listReadyDevices()
            devices = result.devices
            unavailableCount = result.unavailableCount
            lastError = nil
        } catch {
            devices = []
            unavailableCount = 0
            lastError = error.localizedDescription
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

    func launch(device: AdbDevice) {
        guard toolStatus.allReady else {
            presentInstallHint()
            return
        }
        do {
            let client = ScrcpyClient(configuredPath: settings.scrcpyPath)
            let pid = try client.launch(serial: device.sn, options: settings.launchOptions)
            lastError = nil
            WindowFront.scheduleActivateScrcpy(pid: pid)
        } catch {
            lastError = error.localizedDescription
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
}
