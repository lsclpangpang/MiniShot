import AppKit

/// 标注画布：显示底图和标注，处理绘制、选中、移动、缩放、文字输入和撤销重做。
/// 截图浮层和长截图编辑窗口共用。键盘事件由宿主视图（keyHost）接收后调用这里的方法。
final class CanvasView: NSView, NSTextViewDelegate {
    let content: CanvasContent
    private(set) var annotations: [Annotation] = []

    var tool: Tool? {
        didSet { if tool != oldValue { commitText() } }
    }
    var color: NSColor = .systemRed
    var size = 1
    var redactBrush = false
    weak var keyHost: NSResponder?

    private(set) var selected: Annotation? {
        didSet { needsDisplay = true }
    }

    private enum Drag {
        case none
        case create(Annotation)
        case move(CGPoint)
        case handle(Int)
    }
    private var drag = Drag.none
    /// 移动或缩放前的快照，真的发生改动才放进撤销栈
    private var pendingSnapshot: [Annotation]?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    private var textView: NSTextView?
    private var editingText: TextAnnotation?
    private var editingIsNew = false
    private var textSnapshot: [Annotation]?

    init(content: CanvasContent) {
        self.content = content
        super.init(frame: CGRect(origin: .zero, size: content.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isEditingText: Bool { textView != nil }

    func render() -> CGImage? {
        commitText()
        return Renderer.render(content: content, annotations: annotations)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(content.image, in: bounds)
        for a in Renderer.ordered(annotations) where !a.hidden && a.bounds.intersects(dirtyRect) {
            a.draw(in: ctx, content: content)
        }
        if let s = selected, !s.hidden { drawSelection(s, ctx) }
        if let tv = textView {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(tv.frame.insetBy(dx: -4, dy: -3))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setLineDash(phase: 3.5, lengths: [4, 3])
            ctx.stroke(tv.frame.insetBy(dx: -4, dy: -3))
        }
    }

    private func drawSelection(_ a: Annotation, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if a.handles.isEmpty {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(a.bounds)
            return
        }
        for p in a.handles {
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r)
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if textView != nil {
            commitText()
            return
        }
        if let s = selected, let i = s.handles.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 7 }) {
            pendingSnapshot = snapshot()
            drag = .handle(i)
            return
        }
        if let hit = annotations.reversed().first(where: { $0.hitTest(p) }) {
            selected = hit
            if event.clickCount == 2, let t = hit as? TextAnnotation {
                beginEditing(t, isNew: false)
                return
            }
            pendingSnapshot = snapshot()
            drag = .move(p)
            return
        }
        selected = nil
        guard let tool else { return }

        let a: Annotation
        switch tool {
        case .rect: a = ShapeAnnotation(kind: .rect, start: p, end: p, color: color, size: size)
        case .ellipse: a = ShapeAnnotation(kind: .ellipse, start: p, end: p, color: color, size: size)
        case .line: a = ShapeAnnotation(kind: .line, start: p, end: p, color: color, size: size)
        case .arrow: a = ShapeAnnotation(kind: .arrow, start: p, end: p, color: color, size: size)
        case .pen: a = PenAnnotation(points: [p], highlighter: false, color: color, size: size)
        case .highlighter: a = PenAnnotation(points: [p], highlighter: true, color: color, size: size)
        case .mosaic, .blur:
            a = RedactionAnnotation(kind: tool == .mosaic ? .mosaic : .blur, start: p, end: p,
                                    points: redactBrush ? [p] : nil, size: size)
        case .counter:
            let next = (annotations.compactMap { ($0 as? CounterAnnotation)?.number }.max() ?? 0) + 1
            a = CounterAnnotation(center: p, number: next, color: color, size: size)
        case .text:
            let t = TextAnnotation(origin: .zero, text: "", color: color, size: size)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: t.font)
            t.origin = CGPoint(x: p.x, y: p.y + lineHeight / 2)
            beginEditing(t, isNew: true)
            return
        }
        pushUndo(snapshot())
        annotations.append(a)
        if tool == .counter {
            selected = a
            drag = .move(p)
        } else {
            drag = .create(a)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .create(let a):
            if let s = a as? ShapeAnnotation {
                s.end = shift ? constrained(from: s.start, to: p, kind: s.kind) : p
            } else if let pen = a as? PenAnnotation {
                pen.points.append(p)
            } else if let r = a as? RedactionAnnotation {
                if r.points != nil { r.points?.append(p) } else { r.end = p }
            }
        case .move(let last):
            guard let s = selected else { break }
            commitPendingSnapshot()
            s.move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .move(p)
        case .handle(let i):
            commitPendingSnapshot()
            selected?.moveHandle(i, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .create(let a) = drag {
            if a.isTrivial {
                annotations.removeAll { $0 === a }
                _ = undoStack.popLast()
            } else if !(a is PenAnnotation) {
                selected = a
            }
        }
        drag = .none
        pendingSnapshot = nil
        needsDisplay = true
    }

    /// 按住 Shift：矩形、椭圆变正方形、正圆，直线、箭头吸附到 45° 的倍数
    private func constrained(from s: CGPoint, to p: CGPoint, kind: ShapeAnnotation.Kind) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch kind {
        case .rect, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * length, y: s.y + sin(angle) * length)
        }
    }

    // MARK: - 编辑操作（由宿主调用）

    @discardableResult
    func deleteSelected() -> Bool {
        guard let s = selected else { return false }
        pushUndo(snapshot())
        annotations.removeAll { $0 === s }
        selected = nil
        return true
    }

    @discardableResult
    func deselect() -> Bool {
        guard selected != nil else { return false }
        selected = nil
        return true
    }

    @discardableResult
    func nudgeSelected(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let s = selected else { return false }
        pushUndo(snapshot())
        s.move(by: CGVector(dx: dx, dy: dy))
        needsDisplay = true
        return true
    }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selected = nil
    }

    func redo() {
        commitText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selected = nil
    }

    /// 工具栏改了颜色或粗细：作用到正在输入的文字或选中的标注上
    func applyStyle() {
        if let t = editingText, let tv = textView {
            t.color = color
            t.size = size
            tv.font = t.font
            tv.textColor = color
            tv.insertionPointColor = color
            layoutTextView()
            needsDisplay = true
            return
        }
        guard let s = selected else { return }
        let colorChanged = !s.isRedaction && s.color != color
        guard colorChanged || s.size != size else { return }
        pushUndo(snapshot())
        if !s.isRedaction { s.color = color }
        s.size = size
        needsDisplay = true
    }

    // MARK: - 撤销

    /// 深拷贝当前标注。撤销栈里存的是拷贝，当前数组里的对象可以放心修改。
    private func snapshot() -> [Annotation] { annotations.map { $0.clone() } }

    private func pushUndo(_ s: [Annotation]) {
        undoStack.append(s)
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func commitPendingSnapshot() {
        if let s = pendingSnapshot {
            pushUndo(s)
            pendingSnapshot = nil
        }
    }

    // MARK: - 文字输入

    private func beginEditing(_ t: TextAnnotation, isNew: Bool) {
        commitText()
        editingText = t
        editingIsNew = isNew
        textSnapshot = snapshot()
        t.hidden = true
        selected = nil

        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = t.font
        tv.textColor = t.color
        tv.insertionPointColor = t.color
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.string = t.text
        tv.delegate = self
        addSubview(tv)
        textView = tv
        layoutTextView()
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    /// 输入框随内容变大，保持左上角不动
    private func layoutTextView() {
        guard let tv = textView, let t = editingText,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let w = max(used.width + 12, 40)
        let h = max(used.height, lm.defaultLineHeight(for: t.font))
        tv.frame = CGRect(x: t.origin.x, y: t.origin.y - h, width: w, height: h)
    }

    func textDidChange(_ notification: Notification) {
        layoutTextView()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    func commitText() {
        guard let tv = textView, let t = editingText else { return }
        let text = tv.string
        textView = nil
        editingText = nil
        window?.makeFirstResponder(keyHost)
        tv.removeFromSuperview()
        t.hidden = false

        let before = textSnapshot ?? []
        textSnapshot = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !editingIsNew {
                pushUndo(before)
                annotations.removeAll { $0 === t }
            }
        } else if editingIsNew {
            t.text = text
            pushUndo(before)
            annotations.append(t)
        } else if text != t.text {
            pushUndo(before)
            t.text = text
        }
        needsDisplay = true
    }
}
