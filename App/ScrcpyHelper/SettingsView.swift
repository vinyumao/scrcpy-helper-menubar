import AppKit
import ScrcpyHelperCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft = AppSettings()
    @State private var selectedTab = "general"
    @State private var selectedSerial = ""
    @State private var saveMessage = ""

    private var deviceSerials: [String] {
        var serials = Set(appModel.devices.map(\.sn)).union(appModel.settings.devices.keys)
        if !selectedSerial.isEmpty { serials.insert(selectedSerial) }
        return serials.sorted()
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag("general")
            deviceSettings
                .tabItem { Label("设备", systemImage: "iphone") }
                .tag("devices")
        }
        .padding()
        .frame(width: 600, height: 540)
        .onAppear {
            draft = appModel.settings
            showRequestedDevice()
        }
        .onChange(of: appModel.settingsRequestId) { _, _ in showRequestedDevice() }
        .alert("错误", isPresented: Binding(
            get: { appModel.lastError != nil },
            set: { if !$0 { appModel.lastError = nil } }
        )) {
            Button("好", role: .cancel) { appModel.lastError = nil }
        } message: {
            Text(appModel.lastError ?? "")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("工具路径") {
                HStack {
                    TextField("adb 路径（留空自动查找）", text: Binding(
                        get: { draft.adbPath ?? "" },
                        set: { draft.adbPath = $0.isEmpty ? nil : $0 }
                    ))
                    Button("浏览…") { pickFile { draft.adbPath = $0 } }
                }
                Text("当前：\(appModel.toolStatus.adbPath ?? "未找到")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    TextField("scrcpy 路径（留空自动查找）", text: Binding(
                        get: { draft.scrcpyPath ?? "" },
                        set: { draft.scrcpyPath = $0.isEmpty ? nil : $0 }
                    ))
                    Button("浏览…") { pickFile { draft.scrcpyPath = $0 } }
                }
                Text("当前：\(appModel.toolStatus.scrcpyPath ?? "未找到")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("全局启动选项") {
                LaunchOptionsFields(options: $draft.launchOptions)
                Text("设备默认继承这里的选项，可在「设备」中单独配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("安装指引") {
                Text("adb: brew install android-platform-tools\nscrcpy: brew install scrcpy")
                    .font(.caption).textSelection(.enabled)
            }
            Section("关于") {
                HStack {
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    Spacer()
                    Button("打开配置目录") { appModel.openAppSupport() }
                }
            }
            HStack {
                Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复已保存设置") {
                    draft = appModel.settings
                    saveMessage = ""
                }
                Button("保存") {
                    saveMessage = appModel.saveSettings(draft) ? "已保存" : "保存失败"
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, _ in saveMessage = "" }
    }

    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if deviceSerials.isEmpty {
                ContentUnavailableView("暂无设备", systemImage: "iphone", description: Text("连接设备后，可以在这里设置别名、默认屏幕和启动选项。"))
            } else {
                Picker("设备", selection: $selectedSerial) {
                    Text("选择设备").tag("")
                    ForEach(deviceSerials, id: \.self) { serial in
                        Text(deviceLabel(serial)).tag(serial)
                    }
                }
                .padding(.horizontal)
                if !selectedSerial.isEmpty {
                    DeviceSettingsEditor(serial: selectedSerial)
                        .id(selectedSerial)
                } else {
                    Spacer()
                }
            }
        }
        .padding(.top)
    }

    private func deviceLabel(_ serial: String) -> String {
        if let device = appModel.devices.first(where: { $0.sn == serial }) {
            return appModel.deviceTitle(device)
        }
        return "\(appModel.settings.alias(for: serial) ?? serial)（未连接）"
    }

    private func showRequestedDevice() {
        if let serial = appModel.settingsDeviceSerial {
            selectedSerial = serial
            selectedTab = "devices"
        } else {
            selectedTab = "general"
            if selectedSerial.isEmpty { selectedSerial = deviceSerials.first ?? "" }
        }
    }

    private func pickFile(_ onPick: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
    }
}

private struct LaunchOptionsFields: View {
    @Binding var options: ScrcpyLaunchOptions

    var body: some View {
        Toggle("关闭音频", isOn: $options.noAudio)
        Toggle("保持亮屏", isOn: $options.stayAwake)
        Toggle("限制分辨率为 1024", isOn: $options.maxSize1024)
    }
}

private struct DeviceSettingsEditor: View {
    @EnvironmentObject private var appModel: AppModel
    let serial: String
    @State private var alias = ""
    @State private var inheritOptions = true
    @State private var options = ScrcpyLaunchOptions()
    @State private var preferredDisplay = -1
    @State private var saveMessage = ""

    private var displayIds: [Int] {
        var ids = Set(appModel.displayIds(for: serial) ?? [])
        if preferredDisplay >= 0 { ids.insert(preferredDisplay) }
        return ids.sorted()
    }

    var body: some View {
        Form {
            Section("设备信息") {
                LabeledContent("序列号", value: serial).textSelection(.enabled)
                TextField("别名", text: $alias, prompt: Text("例如：收银主机、测试手机"))
                Text("别名用于设备菜单和新打开的投屏窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("默认屏幕") {
                Picker("打开时使用", selection: $preferredDisplay) {
                    Text("系统默认屏幕").tag(-1)
                    ForEach(displayIds, id: \.self) { id in
                        Text("屏幕 \(id)\(id == 0 ? "（主屏）" : "")").tag(id)
                    }
                }
                Text("从菜单单独打开某个屏幕时会记住选择；屏幕不存在时回退到系统默认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("启动选项") {
                Toggle("继承全局启动选项", isOn: $inheritOptions)
                LaunchOptionsFields(options: inheritOptions ? .constant(appModel.settings.launchOptions) : $options)
                    .disabled(inheritOptions)
            }
            HStack {
                Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复已保存设置") { load() }
                Button("保存此设备") {
                    let profile = DeviceSettings(
                        alias: alias,
                        launchOptions: inheritOptions ? nil : options,
                        preferredDisplayId: preferredDisplay < 0 ? nil : preferredDisplay
                    )
                    saveMessage = appModel.saveDeviceSettings(profile, serial: serial) ? "已保存" : "保存失败"
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: alias) { _, _ in saveMessage = "" }
        .onChange(of: inheritOptions) { _, newValue in
            if !newValue { options = appModel.settings.options(for: serial) }
            saveMessage = ""
        }
        .onChange(of: options) { _, _ in saveMessage = "" }
        .onChange(of: preferredDisplay) { _, _ in saveMessage = "" }
    }

    private func load() {
        let profile = appModel.settings.devices[serial] ?? DeviceSettings()
        alias = profile.alias
        inheritOptions = profile.launchOptions == nil
        options = appModel.settings.options(for: serial)
        preferredDisplay = profile.preferredDisplayId ?? -1
        saveMessage = ""
    }
}
