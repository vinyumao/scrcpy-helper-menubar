# Scrcpy Helper 菜单栏 App — 设计说明

- 日期：2026-08-10
- 状态：已共识，进入实现
- 工程目录：`~/work/tools/scrcpy-helper-menubar/`
- 参考实现：`~/work/tools/db-zip-menubar/`

## 1. 目标

做一款 macOS **菜单栏 App**，作为 scrcpy 快捷助手：

- 点击状态栏图标展示已连接的 adb 设备列表
- 点击设备即用 scrcpy 投屏连接
- 提供重载设备、设置、退出等常用操作
- 检测本机 adb / scrcpy 是否可用；缺失时只提示安装指引，不自动安装

## 2. 非目标（第一期不做）

- App Store / 公证 / 自动更新
- 沙盒化、捆绑 adb/scrcpy
- 自动 Homebrew 安装
- 无线 adb 配对向导
- 完整自定义命令行参数模板
- 登录项管理（可后续加）

## 3. 用户与分发

- 仅本人本机使用
- 非沙盒（需 spawn `adb` / `scrcpy`）
- 本地 Xcode 构建；`CODE_SIGN_IDENTITY="-"`
- 构建后复制到 `/Applications/Scrcpy Helper.app` 并启动

## 4. 已确认决策

| 项 | 选择 |
|----|------|
| 缺失工具 | 只检测 + 安装指引（不自动装） |
| scrcpy 参数 | 内置开关：关闭音频、保持亮屏、限制分辨率 1024 |
| 路径配置 | 设置里可手填 adb / scrcpy 路径 |
| 架构 | 对齐 db-zip：SPM Core + MenuBarExtra App + XcodeGen |

## 5. 菜单与交互

```
[状态区] adb / scrcpy 就绪或缺失提示（可点看指引）
[设备列表] 点击 → scrcpy -s <serial> + 当前选项
────────
[启动选项] 关闭音频 / 保持亮屏 / 限制分辨率(1024)（记住）
────────
重载设备
设置…
退出
```

行为：

- 打开菜单时自动刷新设备；也可点「重载设备」
- 允许同一设备多开 scrcpy 窗口
- 工具缺失时设备项禁用
- unauthorized / offline 设备不进入可点击列表；unavailable 数量可在状态区展示

## 6. 架构

```
Package.swift                 → ScrcpyHelperCore
project.yml                   → XcodeGen App
Sources/ScrcpyHelperCore/     → Adb / Scrcpy / Detector / Settings
App/ScrcpyHelper/             → MenuBarExtra UI
scripts/build-install-run.sh  → Release → /Applications → open
```

数据流：

1. 打开菜单 / 重载 → `ToolDetector` + `AdbClient.listReadyDevices()`
2. 点设备 → `ScrcpyClient.launch(serial, options)`（detached Process）
3. 改开关 / 路径 → `SettingsStore` 持久化

## 7. 工具探测

顺序：手填路径 → `PATH` → 常见位置

- adb：`~/Library/Android/sdk/platform-tools/adb`、`/opt/homebrew/bin/adb`、`/usr/local/bin/adb`
- scrcpy：`/opt/homebrew/bin/scrcpy`、`/usr/local/bin/scrcpy`

安装指引：

- adb：`brew install android-platform-tools` 或 Android Studio SDK platform-tools
- scrcpy：`brew install scrcpy`

## 8. 错误处理

| 场景 | 表现 |
|------|------|
| 未找到工具 | 状态区提示；设备禁用；可看指引 |
| 无设备 | 「暂无已连接设备」 |
| scrcpy 启动失败 | Alert 显示 stderr 摘要 |

## 9. 工程约定

- Bundle ID：`tools.wayne.scrcpy-helper-menubar`
- 显示名：`Scrcpy Helper`
- `LSUIElement=YES`
- macOS 14+
- App Icon + 菜单栏 template 图标

## 10. 测试

- Core 单元测试：`adb devices -l` 解析、scrcpy 参数组装、路径探测（mock ProcessRunner）
