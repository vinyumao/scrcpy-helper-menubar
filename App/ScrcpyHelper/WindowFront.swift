import AppKit
import SwiftUI

enum WindowFront {
    static func scheduleRaise() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// 菜单栏 App 启动的 scrcpy 默认不会抢前台；按 pid 多次尝试置顶。
    static func scheduleActivateScrcpy(pid: Int32) {
        let delays: [TimeInterval] = [0.35, 0.8, 1.4, 2.2, 3.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                activateScrcpy(pid: pid)
            }
        }
    }

    private static func activateScrcpy(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        // SDL 窗口常需 System Events 才能真正 frontmost（无需额外权限时也可能成功）
        bringProcessFrontmostViaSystemEvents(pid: pid)
    }

    private static func bringProcessFrontmostViaSystemEvents(pid: Int32) {
        let source = """
        tell application "System Events"
          set frontmost of first process whose unix id is \(pid) to true
        end tell
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&error)
        }
    }
}

extension View {
    func raiseWindowOnAppear() -> some View {
        onAppear {
            WindowFront.scheduleRaise()
        }
    }
}
