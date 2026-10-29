import AppKit

/// 覆盖整块屏幕的浮层窗口
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 和弹出菜单同一层级：盖住菜单栏和 Dock，输入法候选框仍能显示在上面
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 浮层上的交互层：压暗、选区、控制点、尺寸标签、放大镜。状态都在 OverlaySession 里。
final class SelectionView: NSView {
    private weak var session: OverlaySession?
    private let index: Int

    init(session: OverlaySession, index: Int, frame: CGRect) {
        self.session = session
        self.index = index
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        // 还没开始框选时，鼠标移到哪块屏幕，哪块屏幕的浮层接收键盘
        if case .idle = session?.phase, window?.isKeyWindow == false {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        session?.mouseMoved(index, location(event))
    }
    override func mouseDown(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        window?.makeFirstResponder(self)
        session?.mouseDown(index, location(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(index, location(event)) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(index, location(event)) }
    override func rightMouseDown(with event: NSEvent) { session?.rightMouseDown(index, location(event)) }

    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) != true { super.keyDown(with: event) }
    }

    /// ⌘C、⌘S、⌘Z 先于主菜单处理；正在输入文字时交给输入框
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let session, !session.isEditingText, window?.isKeyWindow == true,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        return session.keyDown(event)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }

        var hole: CGRect?
        var isHover = false
        if s.activeIndex == index, let sel = s.selection {
            hole = sel
        } else if case .idle = s.phase, let h = s.hover, h.index == index {
            hole = h.rect
            isHover = true
        }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        if let hole {
            ctx.addRect(bounds)
            ctx.addRect(hole)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(isHover ? 3 : 1.5)
            let inset: CGFloat = isHover ? 1.5 : -0.75
            ctx.stroke(hole.insetBy(dx: inset, dy: inset))
        } else {
            ctx.fill(bounds)
        }

        if s.activeIndex == index, let sel = s.selection {
            if s.showsHandles {
                for h in Handle.allCases {
                    let p = h.point(in: sel)
                    let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(r)
                    ctx.setStrokeColor(NSColor.systemBlue.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(r)
                }
            }
            drawSizeLabel(sel, scale: s.screens[index].scale)
        }

        if s.showsMagnifier, let m = s.mouse, m.index == index {
            drawMagnifier(at: m.point, session: s, ctx: ctx)
        }
    }

    private func drawLabel(_ text: String, at origin: CGPoint) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
        return box
    }

    private func drawSizeLabel(_ sel: CGRect, scale: CGFloat) {
        let text = "\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))"
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 4)
        if origin.y + 20 > bounds.maxY { origin = CGPoint(x: sel.minX + 4, y: sel.maxY - 22) }
        _ = drawLabel(text, at: origin)
    }

    /// 鼠标旁的放大镜：8 倍像素放大，显示坐标和颜色
    private func drawMagnifier(at p: CGPoint, session s: OverlaySession, ctx: CGContext) {
        let frozen = s.screens[index]
        let scale = frozen.scale
        let cells = 15, zoom: CGFloat = 8
        let side = CGFloat(cells) * zoom
        let labelHeight: CGFloat = 40

        var box = CGRect(x: p.x + 20, y: p.y - 20 - side, width: side, height: side)
        if box.maxX > bounds.maxX - 4 { box.origin.x = p.x - 20 - side }
        if box.minY - labelHeight < bounds.minY + 4 { box.origin.y = p.y + 20 }

        let px = Int(p.x * scale), py = Int((bounds.height - p.y) * scale)
        let half = cells / 2
        let src = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let visible = src.intersection(imageBounds)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(box)
        if !visible.isNull, let crop = frozen.image.cropping(to: visible) {
            let top = box.maxY - (visible.minY - src.minY) * zoom
            let dest = CGRect(x: box.minX + (visible.minX - src.minX) * zoom, y: top - visible.height * zoom,
                              width: visible.width * zoom, height: visible.height * zoom)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: dest)
        }
        // 十字线和中心格
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: box.minX, y: box.midY - zoom / 2, width: side, height: zoom))
        ctx.fill(CGRect(x: box.midX - zoom / 2, y: box.minY, width: zoom, height: side))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: box.midX - zoom / 2, y: box.midY - zoom / 2, width: zoom, height: zoom))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(box)
        ctx.restoreGState()

        let info = "\(px), \(py)   \(s.hexColor ?? "")\n按 C 复制颜色"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let labelBox = CGRect(x: box.minX, y: box.minY - labelHeight, width: side, height: labelHeight)
        NSColor.black.withAlphaComponent(0.75).setFill()
        labelBox.fill()
        (info as NSString).draw(in: labelBox.insetBy(dx: 6, dy: 4), withAttributes: attrs)
    }
}
