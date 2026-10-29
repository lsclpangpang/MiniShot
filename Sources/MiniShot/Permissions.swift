import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 第一次调用会弹出系统授权框，之后再调用没有反应
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 截图时发现没有权限：先请求一次，再提示去系统设置里打开
    static func promptScreenRecording() {
        requestScreenRecording()
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 录屏与系统录音 中打开 MiniShot，然后重新打开 MiniShot。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

@MainActor
enum Alerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
