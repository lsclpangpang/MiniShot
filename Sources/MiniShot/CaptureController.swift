import AppKit

/// 串起整个流程：冻结屏幕 → 框选 / 标注 → 输出，或进入长截图 → 编辑窗口
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var overlay: OverlaySession?
    private var scrollSession: ScrollSession?
    private var editors: [EditorWindowController] = []
    private var starting = false
    private var previousApp: NSRunningApplication?

    private var isBusy: Bool { starting || overlay != nil || scrollSession != nil }

    func capture(scroll: Bool, delay: TimeInterval = 0) {
        guard !isBusy else { return }
        guard Permissions.screenRecording else {
            Permissions.promptScreenRecording()
            return
        }
        starting = true
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { starting = false }
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do {
                let frozen = try await ScreenGrabber.freezeAll()
                guard !frozen.isEmpty else { return }
                let session = OverlaySession(mode: scroll ? .scroll : .normal, screens: frozen,
                                             windows: WindowList.onScreen()) { [weak self] outcome in
                    self?.overlayFinished(outcome)
                }
                overlay = session
                session.show()
            } catch {
                Alerts.show("截图失败", error.localizedDescription)
            }
        }
    }

    private func overlayFinished(_ outcome: OverlaySession.Outcome) {
        overlay = nil
        switch outcome {
        case .cancel:
            restoreFocus()
        case .image(let image, let scale, let action):
            Exporter.export(image, scale: scale, action: action)
            restoreFocus()
        case .scroll(let screen, let rect):
            // 把焦点还给要滚动的 App
            restoreFocus()
            startScroll(screen: screen, rect: rect)
        }
    }

    private func startScroll(screen: NSScreen, rect: CGRect) {
        let session = ScrollSession(screen: screen, rect: rect, auto: Settings.shared.scrollMode == .auto) { [weak self] result in
            guard let self else { return }
            scrollSession = nil
            if let result { openEditor(image: result.image, scale: result.scale) }
        }
        scrollSession = session
        session.start()
    }

    private func openEditor(image: CGImage, scale: CGFloat) {
        let editor = EditorWindowController(image: image, scale: scale)
        editor.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    private func restoreFocus() {
        guard let app = previousApp, app != NSRunningApplication.current else { return }
        app.activate(options: [])
    }
}
