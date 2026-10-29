import AppKit

/// 选区边上的 8 个控制点
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .top: CGPoint(x: r.midX, y: r.maxY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottom: CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// 以拖动开始时的选区为基准，计算拖到 p 后的新选区（可以拖过对边翻转）
    func resize(_ r: CGRect, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch self {
        case .topLeft, .left, .bottomLeft: minX = p.x
        case .topRight, .right, .bottomRight: maxX = p.x
        default: break
        }
        switch self {
        case .topLeft, .top, .topRight: maxY = p.y
        case .bottomLeft, .bottom, .bottomRight: minY = p.y
        default: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}

extension CGRect {
    var roundedToPoints: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

/// 一次截图的交互过程：每块屏幕一个全屏浮层，显示冻结画面，在上面框选、标注
@MainActor
final class OverlaySession: ToolbarDelegate {
    enum Mode { case normal, scroll }

    enum Outcome {
        case cancel
        case image(CGImage, scale: CGFloat, action: ExportAction)
        /// 开始长截图；rect 是屏幕内的点坐标（左下角原点）
        case scroll(NSScreen, CGRect)
    }

    enum Phase {
        case idle
        case creating(CGPoint)
        case selected
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
        /// 已开始标注，选区固定
        case locked
    }

    let mode: Mode
    let screens: [FrozenScreen]
    private let windowInfos: [WindowInfo]
    private let onFinish: (Outcome) -> Void
    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []

    private(set) var phase: Phase = .idle
    private(set) var activeIndex: Int?
    private(set) var selection: CGRect?
    private(set) var hover: (index: Int, rect: CGRect)?
    private(set) var mouse: (index: Int, point: CGPoint)?
    private(set) var hexColor: String?
    private var toolbar: Toolbar?
    private var canvas: CanvasView?
    private var finished = false

    init(mode: Mode, screens: [FrozenScreen], windows: [WindowInfo], onFinish: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.screens = screens
        self.windowInfos = windows
        self.onFinish = onFinish
    }

    var showsHandles: Bool {
        switch phase {
        case .selected, .moving, .resizing: true
        default: false
        }
    }

    var showsMagnifier: Bool {
        switch phase {
        case .idle, .creating, .resizing: true
        default: false
        }
    }

    func show() {
        for (i, frozen) in screens.enumerated() {
            let window = OverlayWindow(screen: frozen.screen)
            let container = NSView(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
            let imageView = NSImageView(frame: container.bounds)
            imageView.image = NSImage(cgImage: frozen.image, size: frozen.screen.frame.size)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            container.addSubview(imageView)
            let view = SelectionView(session: self, index: i, frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            window.contentView = container
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }

        let location = NSEvent.mouseLocation
        let index = screens.firstIndex { $0.screen.frame.contains(location) } ?? 0
        windows[index].makeKey()
        windows[index].makeFirstResponder(views[index])
        let local = CGPoint(x: location.x - screens[index].screen.frame.minX, y: location.y - screens[index].screen.frame.minY)
        mouseMoved(index, local)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        toolbar = nil
        canvas = nil
        onFinish(outcome)
    }

    private func redraw() {
        for v in views { v.needsDisplay = true }
    }

    // MARK: - 鼠标

    func mouseMoved(_ i: Int, _ p: CGPoint) {
        mouse = (i, p)
        updateColor()
        if case .idle = phase {
            hover = windowRect(at: p, screen: i).map { (i, $0) }
        }
        updateCursor(i, p)
        redraw()
    }

    func mouseDown(_ i: Int, _ p: CGPoint, clickCount: Int) {
        mouse = (i, p)
        switch phase {
        case .idle:
            beginCreate(i, p)
        case .selected:
            guard let sel = selection, i == activeIndex else {
                beginCreate(i, p)
                break
            }
            if clickCount >= 2 && sel.contains(p) {
                if mode == .scroll { startScroll() } else { confirm(.done) }
                return
            }
            if let h = Handle.allCases.first(where: { hypot($0.point(in: sel).x - p.x, $0.point(in: sel).y - p.y) <= 8 }) {
                phase = .resizing(h, original: sel)
            } else if sel.contains(p) {
                phase = .moving(start: p, original: sel)
                NSCursor.closedHand.set()
            } else {
                beginCreate(i, p)
            }
            toolbar?.isHidden = true
        default:
            break
        }
        redraw()
    }

    func mouseDragged(_ i: Int, _ point: CGPoint) {
        let b = views[i].bounds
        let p = CGPoint(x: min(max(point.x, b.minX), b.maxX), y: min(max(point.y, b.minY), b.maxY))
        switch phase {
        case .creating(let start):
            selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y)).roundedToPoints
        case .moving(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
            r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
            selection = r.roundedToPoints
        case .resizing(let h, let original):
            selection = h.resize(original, to: p).roundedToPoints
        default:
            return
        }
        mouse = (i, p)
        updateColor()
        redraw()
    }

    func mouseUp(_ i: Int, _ p: CGPoint) {
        switch phase {
        case .creating:
            if selection == nil || (selection!.width < 4 && selection!.height < 4) {
                // 单击：选中鼠标下的窗口，没有窗口就选整块屏幕
                selection = windowRect(at: p, screen: i) ?? views[i].bounds
            }
            phase = .selected
            showToolbar()
        case .moving, .resizing:
            if let sel = selection, sel.width < 2 || sel.height < 2 {
                selection = sel.insetBy(dx: -1, dy: -1)
            }
            phase = .selected
            showToolbar()
        default:
            break
        }
        hover = nil
        updateCursor(i, p)
        redraw()
    }

    func rightMouseDown(_ i: Int, _ p: CGPoint) {
        switch phase {
        case .selected:
            // 右键回到重新框选
            phase = .idle
            selection = nil
            activeIndex = nil
            toolbar?.removeFromSuperview()
            hover = windowRect(at: p, screen: i).map { (i, $0) }
            redraw()
        case .locked:
            break
        default:
            finish(.cancel)
        }
    }

    private func beginCreate(_ i: Int, _ p: CGPoint) {
        activeIndex = i
        selection = nil
        hover = nil
        phase = .creating(p)
        toolbar?.removeFromSuperview()
    }

    private func windowRect(at p: CGPoint, screen i: Int) -> CGRect? {
        let frame = screens[i].screen.frame
        let global = CGPoint(x: p.x + frame.minX, y: p.y + frame.minY)
        guard let info = windowInfos.first(where: { $0.frame.contains(global) }) else { return nil }
        let r = info.frame.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return r.offsetBy(dx: -frame.minX, dy: -frame.minY).roundedToPoints
    }

    private func updateCursor(_ i: Int, _ p: CGPoint) {
        if let t = toolbar, !t.isHidden, t.superview === views[i], t.frame.contains(p) {
            NSCursor.arrow.set()
            return
        }
        switch phase {
        case .selected:
            guard let sel = selection, i == activeIndex else { NSCursor.crosshair.set(); return }
            let onHandle = Handle.allCases.contains { hypot($0.point(in: sel).x - p.x, $0.point(in: sel).y - p.y) <= 8 }
            if onHandle { NSCursor.crosshair.set() } else if sel.contains(p) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
        case .moving:
            NSCursor.closedHand.set()
        case .locked:
            if canvas?.tool == .text, let c = canvas, c.frame.contains(p) { NSCursor.iBeam.set() } else { NSCursor.crosshair.set() }
        default:
            NSCursor.crosshair.set()
        }
    }

    /// 取鼠标下像素的颜色
    private func updateColor() {
        guard let m = mouse else { hexColor = nil; return }
        let i = m.index, p = m.point
        let frozen = screens[i]
        let h = views[i].bounds.height
        let x = Int(p.x * frozen.scale), y = Int((h - p.y) * frozen.scale)
        guard x >= 0, y >= 0, x < frozen.image.width, y < frozen.image.height,
              let pixel = frozen.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { hexColor = nil; return }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        hexColor = ok ? String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2]) : nil
    }

    // MARK: - 键盘

    /// 返回 true 表示已处理
    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags == .command {
            switch chars {
            case "c": if selection != nil, mode == .normal { confirm(.copy) }; return true
            case "s": if selection != nil, mode == .normal { confirm(.save) }; return true
            case "z": canvas?.undo(); return true
            default: break
            }
        }
        if flags == [.command, .shift], chars == "z" {
            canvas?.redo()
            return true
        }

        switch event.keyCode {
        case 53: // Esc
            if canvas?.deselect() != true { finish(.cancel) }
            return true
        case 36, 76: // Return
            if selection != nil {
                if mode == .scroll { startScroll() } else { confirm(.done) }
            }
            return true
        case 51, 117: // Delete
            canvas?.deleteSelected()
            return true
        case 123, 124, 125, 126: // 方向键
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: (CGFloat, CGFloat) = switch event.keyCode {
            case 123: (-step, 0)
            case 124: (step, 0)
            case 125: (0, -step)
            default: (0, step)
            }
            if case .selected = phase, let sel = selection, let i = activeIndex {
                let b = views[i].bounds
                var r = sel.offsetBy(dx: d.0, dy: d.1)
                r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
                r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
                selection = r
                positionToolbar()
                redraw()
            } else if case .locked = phase {
                canvas?.nudgeSelected(dx: d.0, dy: d.1)
            }
            return true
        default:
            break
        }

        if flags.isEmpty, chars == "c", showsMagnifier, let hex = hexColor {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            return true
        }
        return false
    }

    /// 正在输入文字时，快捷键交给输入框和菜单处理
    var isEditingText: Bool { canvas?.isEditingText == true }

    // MARK: - 工具栏

    private func showToolbar() {
        guard let i = activeIndex else { return }
        let t: Toolbar
        if let existing = toolbar {
            t = existing
        } else {
            t = Toolbar(kind: mode == .scroll ? .scrollStart : .editor(longCapture: true))
            t.delegate = self
            t.onResize = { [weak self] in self?.positionToolbar() }
            toolbar = t
        }
        if t.superview !== views[i] {
            t.removeFromSuperview()
            views[i].addSubview(t)
        }
        t.isHidden = false
        positionToolbar()
    }

    /// 优先放在选区右下方外侧，放不下就放上方，再不行放在选区内部底部
    private func positionToolbar() {
        guard let t = toolbar, let sel = selection, let v = t.superview else { return }
        let size = t.frame.size, b = v.bounds, gap: CGFloat = 6
        let x = max(b.minX + 4, min(sel.maxX - size.width, b.maxX - size.width - 4))
        var y = sel.minY - gap - size.height
        if y < b.minY + 4 {
            y = sel.maxY + gap
            if y + size.height > b.maxY - 4 { y = sel.minY + gap }
        }
        t.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func toolbar(_ toolbar: Toolbar, didSelect tool: Tool?) {
        if canvas == nil, tool != nil { lock() }
        canvas?.tool = tool
    }

    func toolbarStyleDidChange(_ toolbar: Toolbar) {
        guard let canvas else { return }
        canvas.color = toolbar.color
        canvas.size = toolbar.size
        canvas.redactBrush = toolbar.redactBrush
        canvas.applyStyle()
    }

    func toolbar(_ toolbar: Toolbar, perform action: ToolbarAction) {
        switch action {
        case .undo: canvas?.undo()
        case .redo: canvas?.redo()
        case .cancel: finish(.cancel)
        case .save: confirm(.save)
        case .done: confirm(.done)
        case .longCapture, .startScroll: startScroll()
        }
    }

    /// 开始标注：把选区内的冻结画面放进画布，选区不再能调整
    private func lock() {
        guard let i = activeIndex, let sel = selection, let cropped = crop(i, sel) else { return }
        let (image, rect) = cropped
        selection = rect
        phase = .locked
        let c = CanvasView(content: CanvasContent(image: image, scale: screens[i].scale))
        c.setFrameOrigin(rect.origin)
        c.keyHost = views[i]
        if let t = toolbar {
            c.color = t.color
            c.size = t.size
            c.redactBrush = t.redactBrush
        }
        views[i].addSubview(c, positioned: .below, relativeTo: toolbar)
        canvas = c
        positionToolbar()
        redraw()
    }

    // MARK: - 完成

    private func crop(_ i: Int, _ sel: CGRect) -> (CGImage, CGRect)? {
        let frozen = screens[i]
        let s = frozen.scale
        let h = views[i].bounds.height
        let px = CGRect(x: sel.minX * s, y: (h - sel.maxY) * s, width: sel.width * s, height: sel.height * s)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))
        guard !px.isNull, px.width >= 1, px.height >= 1, let image = frozen.image.cropping(to: px) else { return nil }
        return (image, CGRect(x: px.minX / s, y: h - px.maxY / s, width: px.width / s, height: px.height / s))
    }

    private func confirm(_ action: ExportAction) {
        guard let i = activeIndex, let sel = selection else { return }
        let image = canvas?.render() ?? crop(i, sel)?.0
        guard let image else { finish(.cancel); return }
        finish(.image(image, scale: screens[i].scale, action: action))
    }

    private func startScroll() {
        guard let i = activeIndex, let sel = selection, sel.width >= 20, sel.height >= 40 else {
            NSSound.beep()
            return
        }
        finish(.scroll(screens[i].screen, sel))
    }
}
