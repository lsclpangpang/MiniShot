import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var scrollItem: NSMenuItem!
    private var settingsWindow: NSWindow?

    private static let captureHotKeyID: UInt32 = 1
    private static let scrollHotKeyID: UInt32 = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "MiniShot")
        icon?.isTemplate = true
        statusItem.button?.image = icon

        let menu = NSMenu()
        menu.delegate = self
        captureItem = menu.addItem(withTitle: "截图", action: #selector(captureFromMenu), keyEquivalent: "")
        captureItem.target = self
        scrollItem = menu.addItem(withTitle: "长截图", action: #selector(scrollFromMenu), keyEquivalent: "")
        scrollItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MiniShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        Settings.shared.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()

        if !Permissions.screenRecording {
            Permissions.requestScreenRecording()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        captureItem.title = "截图（\(Settings.shared.captureHotKey.display)）"
        scrollItem.title = "长截图（\(Settings.shared.scrollHotKey.display)）"
    }

    private func registerHotKeys() {
        let s = Settings.shared
        HotKeyCenter.shared.set(id: Self.captureHotKeyID, combo: s.captureHotKey) {
            CaptureController.shared.capture(scroll: false)
        }
        HotKeyCenter.shared.set(id: Self.scrollHotKeyID, combo: s.scrollHotKey) {
            CaptureController.shared.capture(scroll: true)
        }
    }

    // 从菜单触发时等菜单收起再截，避免把菜单截进去
    @objc private func captureFromMenu() { CaptureController.shared.capture(scroll: false, delay: 0.3) }
    @objc private func scrollFromMenu() { CaptureController.shared.capture(scroll: true, delay: 0.3) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "MiniShot 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 菜单栏 App 不显示主菜单，但文字输入框需要它提供 ⌘C / ⌘V / ⌘Z 等快捷键
    private func setupMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}
