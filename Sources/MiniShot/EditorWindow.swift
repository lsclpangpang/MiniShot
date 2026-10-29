import AppKit

/// 长截图的编辑窗口：长图放在可滚动的画布里，工具栏在顶部
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, ToolbarDelegate {
    var onClose: ((EditorWindowController) -> Void)?

    private let canvas: CanvasView
    private let toolbar = Toolbar(kind: .editor(longCapture: false))
    private let scrollView = NSScrollView()
    private let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.scale = scale
        canvas = CanvasView(content: CanvasContent(image: image, scale: scale))

        let contentView = EditorContentView()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "长截图 \(image.width) × \(image.height)"
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        super.init(window: window)
        window.delegate = self

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = canvas

        toolbar.delegate = self
        toolbar.onResize = { [weak contentView] in contentView?.needsLayout = true }
        canvas.keyHost = contentView

        contentView.toolbar = toolbar
        contentView.scrollView = scrollView
        contentView.addSubview(scrollView)
        contentView.addSubview(toolbar)
        contentView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        contentView.isEditingText = { [weak self] in self?.canvas.isEditingText ?? false }

        // 窗口宽度贴合图片，高度不超过屏幕
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let imageSize = canvas.frame.size
        let width = min(max(imageSize.width + 40, toolbar.frame.width + 40, 480), visible.width * 0.9)
        let height = min(imageSize.height + toolbar.frame.height + 60, visible.height * 0.9)
        window.setContentSize(CGSize(width: width, height: max(height, 300)))
        window.minSize = CGSize(width: 480, height: 300)
        window.center()
        contentView.layoutSubtreeIfNeeded()
        scrollToTop()
        window.makeFirstResponder(contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func scrollToTop() {
        let clip = scrollView.contentView
        let y = max(0, canvas.frame.height - clip.bounds.height)
        clip.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    private func finish(_ action: ExportAction) {
        guard let image = canvas.render() else { return }
        Exporter.export(image, scale: scale, action: action)
        window?.close()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch chars {
            case "c": finish(.copy); return true
            case "s": finish(.save); return true
            case "z": canvas.undo(); return true
            case "w": window?.close(); return true
            default: return false
            }
        }
        if flags == [.command, .shift], chars == "z" {
            canvas.redo()
            return true
        }
        switch event.keyCode {
        case 53: canvas.deselect(); return true
        case 36, 76: finish(.done); return true
        case 51, 117: canvas.deleteSelected(); return true
        case 123: return canvas.nudgeSelected(dx: flags.contains(.shift) ? -10 : -1, dy: 0)
        case 124: return canvas.nudgeSelected(dx: flags.contains(.shift) ? 10 : 1, dy: 0)
        case 125: return canvas.nudgeSelected(dx: 0, dy: flags.contains(.shift) ? -10 : -1)
        case 126: return canvas.nudgeSelected(dx: 0, dy: flags.contains(.shift) ? 10 : 1)
        default: return false
        }
    }

    func toolbar(_ toolbar: Toolbar, didSelect tool: Tool?) {
        canvas.tool = tool
    }

    func toolbarStyleDidChange(_ toolbar: Toolbar) {
        canvas.color = toolbar.color
        canvas.size = toolbar.size
        canvas.redactBrush = toolbar.redactBrush
        canvas.applyStyle()
    }

    func toolbar(_ toolbar: Toolbar, perform action: ToolbarAction) {
        switch action {
        case .undo: canvas.undo()
        case .redo: canvas.redo()
        case .cancel: window?.close()
        case .save: finish(.save)
        case .done: finish(.done)
        case .longCapture, .startScroll: break
        }
    }
}

final class EditorContentView: NSView {
    var toolbar: Toolbar?
    var scrollView: NSScrollView?
    var keyHandler: ((NSEvent) -> Bool)?
    var isEditingText: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        guard let toolbar, let scrollView else { return }
        let size = toolbar.frame.size
        toolbar.setFrameOrigin(CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height - 8))
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - size.height - 16))
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditingText?() != true, window?.isKeyWindow == true,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        return keyHandler?(event) ?? false
    }
}
