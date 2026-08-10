# Scrcpy Helper Implementation Plan

> 用户已确认设计并要求直接实现。本计划为精简执行清单。

**Goal:** macOS 菜单栏 Scrcpy Helper，检测 adb/scrcpy、列设备、一点即投屏，打包到 `/Applications` 并启动。

**Tech:** Swift 5.9 / macOS 14 / SPM Core + XcodeGen MenuBarExtra / 非沙盒

## Files

- `Package.swift`, `project.yml`, `.gitignore`
- `Sources/ScrcpyHelperCore/{ProcessRunner,AdbClient,ScrcpyClient,ToolDetector,SettingsStore,AppPaths}.swift`
- `App/ScrcpyHelper/{ScrcpyHelperApp,AppModel,MenuBarView,SettingsView,WindowFront}.swift` + Assets/entitlements
- `Tests/ScrcpyHelperCoreTests/*`
- `scripts/build-install-run.sh`

## Tasks

1. Core：ProcessRunner + Adb 解析/列表 + Scrcpy 参数/启动 + Settings + Detector
2. 单测：parser / args / detector mock
3. App UI：MenuBarExtra + Settings + icons
4. xcodegen + Release 构建 → `/Applications` → open
