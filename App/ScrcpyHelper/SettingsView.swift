import AppKit
import ScrcpyHelperCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft: AppSettings = AppSettings()

    var body: some View {
        Form {
            Section("工具路径") {
                HStack {
                    TextField(
                        "adb 路径（可空，自动查找）",
                        text: Binding(
                            get: { draft.adbPath ?? "" },
                            set: { draft.adbPath = $0.isEmpty ? nil : $0 }
                        )
                    )
                    Button("浏览…") { pickFile { draft.adbPath = $0 } }
                }
                if let path = appModel.toolStatus.adbPath {
                    Text("当前: \(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前: 未找到")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    TextField(
                        "scrcpy 路径（可空，自动查找）",
                        text: Binding(
                            get: { draft.scrcpyPath ?? "" },
                            set: { draft.scrcpyPath = $0.isEmpty ? nil : $0 }
                        )
                    )
                    Button("浏览…") { pickFile { draft.scrcpyPath = $0 } }
                }
                if let path = appModel.toolStatus.scrcpyPath {
                    Text("当前: \(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前: 未找到")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("默认启动选项") {
                Toggle("关闭音频 (--no-audio)", isOn: $draft.launchOptions.noAudio)
                Toggle("保持亮屏 (--stay-awake)", isOn: $draft.launchOptions.stayAwake)
                Toggle("限制分辨率 (--max-size=1024)", isOn: $draft.launchOptions.maxSize1024)
            }

            Section("安装指引") {
                Text("adb: brew install android-platform-tools")
                    .font(.caption)
                    .textSelection(.enabled)
                Text("scrcpy: brew install scrcpy")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Section("关于") {
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                Button("打开 Application Support") {
                    appModel.openAppSupport()
                }
            }

            HStack {
                Spacer()
                Button("恢复") { draft = appModel.settings }
                Button("保存") {
                    appModel.saveSettings(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 420)
        .onAppear {
            draft = appModel.settings
        }
    }

    private func pickFile(_ onPick: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url.path)
        }
    }
}
