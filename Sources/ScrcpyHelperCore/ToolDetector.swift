import Foundation

public struct ToolStatus: Sendable, Equatable {
    public var adbFound: Bool
    public var adbPath: String?
    public var scrcpyFound: Bool
    public var scrcpyPath: String?

    public init(
        adbFound: Bool,
        adbPath: String? = nil,
        scrcpyFound: Bool,
        scrcpyPath: String? = nil
    ) {
        self.adbFound = adbFound
        self.adbPath = adbPath
        self.scrcpyFound = scrcpyFound
        self.scrcpyPath = scrcpyPath
    }

    public var allReady: Bool { adbFound && scrcpyFound }

    public var summaryLine: String {
        switch (adbFound, scrcpyFound) {
        case (true, true):
            return "adb 已就绪 · scrcpy 已就绪"
        case (false, true):
            return "未找到 adb"
        case (true, false):
            return "未找到 scrcpy"
        case (false, false):
            return "未找到 adb / scrcpy"
        }
    }
}

public enum ToolDetector {
    public static let adbInstallHint = """
    未找到 adb。

    推荐安装：
    • Homebrew: brew install android-platform-tools
    • 或安装 Android Studio，使用 SDK 的 platform-tools

    也可在「设置」中手动指定 adb 路径。
    """

    public static let scrcpyInstallHint = """
    未找到 scrcpy。

    推荐安装：
    • Homebrew: brew install scrcpy

    也可在「设置」中手动指定 scrcpy 路径。
    """

    public static let bothMissingHint = """
    未找到 adb 与 scrcpy。

    推荐安装：
    • brew install android-platform-tools
    • brew install scrcpy

    也可在「设置」中手动指定可执行文件路径。
    """

    public static func check(settings: AppSettings) -> ToolStatus {
        let adb = AdbClient(configuredPath: settings.adbPath).resolveAdbURL()
        let scrcpy = ScrcpyClient(configuredPath: settings.scrcpyPath).resolveScrcpyURL()
        return ToolStatus(
            adbFound: adb != nil,
            adbPath: adb?.path,
            scrcpyFound: scrcpy != nil,
            scrcpyPath: scrcpy?.path
        )
    }

    public static func installHint(for status: ToolStatus) -> String {
        switch (status.adbFound, status.scrcpyFound) {
        case (true, true):
            return "工具已就绪。"
        case (false, true):
            return adbInstallHint
        case (true, false):
            return scrcpyInstallHint
        case (false, false):
            return bothMissingHint
        }
    }
}
