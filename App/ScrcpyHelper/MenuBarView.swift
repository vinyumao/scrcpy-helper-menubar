import AppKit
import ScrcpyHelperCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button(appModel.toolStatus.summaryLine) {
                if !appModel.toolStatus.allReady {
                    appModel.presentInstallHint()
                }
            }
            .disabled(appModel.toolStatus.allReady)

            if appModel.unavailableCount > 0 {
                Text("另有 \(appModel.unavailableCount) 台不可用")
            }

            Divider()

            if appModel.devices.isEmpty {
                Text(appModel.toolStatus.adbFound ? "暂无已连接设备" : "无法列出设备")
            } else {
                ForEach(appModel.devices) { device in
                    switch appModel.displayLookups[device.sn] {
                    case .available(let displayIds) where displayIds.count > 1:
                        Menu(device.displayName) {
                            Button("打开默认屏幕") {
                                appModel.launch(device: device)
                            }
                            Button("打开所有屏幕") {
                                appModel.launchAllDisplays(device: device, displayIds: displayIds)
                            }
                        }
                        .disabled(!appModel.canLaunchScrcpy || appModel.launchingAllSerials.contains(device.sn))
                    case .checking:
                        Menu(device.displayName) {
                            Button("打开默认屏幕") {
                                appModel.launch(device: device)
                            }
                            Text("正在检测屏幕…")
                        }
                        .disabled(!appModel.canLaunchScrcpy)
                    case .failed:
                        Menu(device.displayName) {
                            Button("打开默认屏幕") {
                                appModel.launch(device: device)
                            }
                            Text("无法读取屏幕列表，请重载设备")
                        }
                        .disabled(!appModel.canLaunchScrcpy)
                    default:
                        Button(device.displayName) {
                            appModel.launch(device: device)
                        }
                        .disabled(!appModel.canLaunchScrcpy)
                    }
                }
            }

            Divider()

            Toggle(
                "关闭音频",
                isOn: Binding(
                    get: { appModel.settings.launchOptions.noAudio },
                    set: { value in appModel.updateLaunchOptions { $0.noAudio = value } }
                )
            )
            Toggle(
                "保持亮屏",
                isOn: Binding(
                    get: { appModel.settings.launchOptions.stayAwake },
                    set: { value in appModel.updateLaunchOptions { $0.stayAwake = value } }
                )
            )
            Toggle(
                "限制分辨率 (1024)",
                isOn: Binding(
                    get: { appModel.settings.launchOptions.maxSize1024 },
                    set: { value in appModel.updateLaunchOptions { $0.maxSize1024 = value } }
                )
            )

            Divider()

            Button(appModel.isRefreshing ? "重载中…" : "重载设备") {
                appModel.refresh()
            }
            .disabled(appModel.isRefreshing)

            Button("设置…") {
                openSettings()
                WindowFront.scheduleRaise()
            }

            Divider()

            Button("退出") {
                appModel.stopTracking()
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            appModel.refresh()
        }
        .alert(
            "安装指引",
            isPresented: $appModel.showInstallHint
        ) {
            Button("复制指引") {
                appModel.copyInstallHintToPasteboard()
            }
            Button("打开设置") {
                appModel.showInstallHint = false
                openSettings()
                WindowFront.scheduleRaise()
            }
            Button("好", role: .cancel) {
                appModel.showInstallHint = false
            }
        } message: {
            Text(appModel.installHintText)
        }
        .alert(
            "错误",
            isPresented: Binding(
                get: { appModel.lastError != nil },
                set: { if !$0 { appModel.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                appModel.lastError = nil
            }
        } message: {
            Text(appModel.lastError ?? "")
        }
    }
}
