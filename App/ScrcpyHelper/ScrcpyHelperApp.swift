import AppKit
import ScrcpyHelperCore
import SwiftUI

@main
struct ScrcpyHelperApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
        } label: {
            MenuBarLabel(ready: appModel.toolStatus.allReady, deviceCount: appModel.devices.count)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .raiseWindowOnAppear()
        }
    }
}

struct MenuBarLabel: View {
    let ready: Bool
    let deviceCount: Int

    var body: some View {
        HStack(spacing: 2) {
            Image("MenuBarIcon")
                .renderingMode(.template)
            if !ready {
                Text("!")
                    .font(.caption2.bold())
            } else if deviceCount > 0 {
                Text("\(min(deviceCount, 99))")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}
