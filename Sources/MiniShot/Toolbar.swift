import AppKit

enum ToolbarAction {
    case undo, redo, longCapture, startScroll, cancel, save, done
}

@MainActor
protocol ToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: Toolbar, didSelect tool: Tool?)
    func toolbarStyleDidChange(_ toolbar: Toolbar)
    func toolbar(_ toolbar: Toolbar, perform action: ToolbarAction)
}

/// 浮动工具栏：第一行是工具和操作，选中工具后出现第二行（颜色、粗细、打码方式）
final class Toolbar: NSView {
    enum Kind {
        case editor(longCapture: Bool)
        /// 长截图框选时只有「开始」和「取消」
        case scrollStart
    }

    weak var delegate: ToolbarDelegate?
    var onResize: (() -> Void)?
    private(set) var tool: Tool?
    private(set) var color: NSColor = Toolbar.palette[0]
    private(set) var size = 1
    private(set) var redactBrush = false

    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    private let kind: Kind
    private var mainItems: [NSView] = []
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var sizeButtons: [NSButton] = []
    private let styleSeparator = SeparatorView()
    private let brushControl = NSSegmentedControl(labels: ["矩形", "涂抹"], trackingMode: .selectOne, target: nil, action: nil)

    private let pad: CGFloat = 5
    private let buttonSize: CGFloat = 28

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        build()
        refresh()
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // 工具栏上保持普通箭头光标
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - 构建

    private func build() {
        switch kind {
        case .scrollStart:
            mainItems = [
                textButton("开始长截图", symbol: "scroll", action: #selector(startScroll)),
                iconButton("xmark", "取消（Esc）", #selector(cancel)),
            ]
        case .editor(let showsLongCapture):
            let tools: [(Tool, String, String)] = [
                (.rect, "rectangle", "矩形"), (.ellipse, "circle", "椭圆"),
                (.arrow, "arrow.up.right", "箭头"), (.line, "line.diagonal", "直线"),
                (.pen, "scribble", "画笔"), (.highlighter, "highlighter", "荧光笔"),
                (.text, "textformat", "文字"), (.counter, "1.circle", "序号"),
                (.mosaic, "checkerboard.rectangle", "马赛克"), (.blur, "drop", "模糊"),
            ]
            for (t, symbol, tip) in tools {
                let b = iconButton(symbol, tip, #selector(toolClicked(_:)))
                b.tag = t.rawValue
                toolButtons[t] = b
                mainItems.append(b)
                if t == .counter { mainItems.append(SeparatorView()) }
            }
            mainItems.append(SeparatorView())
            mainItems.append(iconButton("arrow.uturn.backward", "撤销（⌘Z）", #selector(undo)))
            mainItems.append(iconButton("arrow.uturn.forward", "重做（⇧⌘Z）", #selector(redo)))
            mainItems.append(SeparatorView())
            if showsLongCapture {
                mainItems.append(iconButton("scroll", "长截图", #selector(longCapture)))
                mainItems.append(SeparatorView())
            }
            mainItems.append(iconButton("xmark", "取消（Esc）", #selector(cancel)))
            mainItems.append(iconButton("square.and.arrow.down", "保存到文件（⌘S）", #selector(save)))
            mainItems.append(iconButton("checkmark", "完成（↩ 或双击）", #selector(done)))

            for i in Self.palette.indices {
                let b = NSButton(image: NSImage(), target: self, action: #selector(colorClicked(_:)))
                b.isBordered = false
                b.imagePosition = .imageOnly
                b.tag = i
                colorButtons.append(b)
                addSubview(b)
            }
            for (i, tip) in ["细", "中", "粗"].enumerated() {
                let b = NSButton(image: NSImage(), target: self, action: #selector(sizeClicked(_:)))
                b.isBordered = false
                b.imagePosition = .imageOnly
                b.tag = i
                b.toolTip = tip
                sizeButtons.append(b)
                addSubview(b)
            }
            brushControl.target = self
            brushControl.action = #selector(brushChanged)
            brushControl.selectedSegment = 0
            brushControl.controlSize = .small
            addSubview(brushControl)
            addSubview(styleSeparator)
        }
        mainItems.forEach(addSubview)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b: NSButton
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            let configured = img.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? img
            b = NSButton(image: configured, target: self, action: action)
        } else {
            b = NSButton(title: String(tip.prefix(2)), target: self, action: action)
        }
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.contentTintColor = .labelColor
        return b
    }

    private func textButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b: NSButton
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            b = NSButton(title: title, image: img, target: self, action: action)
            b.imagePosition = .imageLeading
        } else {
            b = NSButton(title: title, target: self, action: action)
        }
        b.isBordered = false
        b.contentTintColor = .controlAccentColor
        b.font = .systemFont(ofSize: 13, weight: .medium)
        return b
    }

    // MARK: - 布局

    private func width(of v: NSView) -> CGFloat {
        if v is SeparatorView { return 9 }
        if v === brushControl { return brushControl.fittingSize.width }
        if colorButtons.contains(where: { $0 === v }) { return 22 }
        if sizeButtons.contains(where: { $0 === v }) { return 24 }
        if let b = v as? NSButton, !b.title.isEmpty, b.imagePosition != .imageOnly { return b.fittingSize.width + 12 }
        return buttonSize
    }

    private func relayout() {
        var x = pad
        for v in mainItems {
            let w = width(of: v)
            let h = v is SeparatorView ? 18 : buttonSize
            v.frame = CGRect(x: x, y: pad + (buttonSize - h) / 2, width: w, height: h)
            x += w + 2
        }
        var totalWidth = x - 2 + pad
        var totalHeight = pad * 2 + buttonSize

        var styleItems: [NSView] = []
        if let tool {
            styleItems = tool.isRedaction
                ? sizeButtons + [styleSeparator, brushControl]
                : colorButtons + [styleSeparator] + sizeButtons
        }
        let allStyle: [NSView] = colorButtons + sizeButtons + [styleSeparator, brushControl]
        for v in allStyle { v.isHidden = !styleItems.contains { $0 === v } }

        if !styleItems.isEmpty {
            let rowY = totalHeight - 2
            let rowHeight: CGFloat = 26
            var sx = pad
            for v in styleItems {
                let w = width(of: v)
                let h = v === brushControl ? brushControl.fittingSize.height : (v is SeparatorView ? 16 : 22)
                v.frame = CGRect(x: sx, y: rowY + (rowHeight - h) / 2, width: w, height: h)
                sx += w + 3
            }
            totalWidth = max(totalWidth, sx - 3 + pad)
            totalHeight = rowY + rowHeight + pad
        }
        setFrameSize(CGSize(width: totalWidth, height: totalHeight))
        onResize?()
    }

    private func refresh() {
        for (t, b) in toolButtons {
            let on = t == tool
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
            b.contentTintColor = on ? .controlAccentColor : .labelColor
        }
        for (i, b) in colorButtons.enumerated() {
            b.image = swatch(Self.palette[i], selected: Self.palette[i] == color)
        }
        for (i, b) in sizeButtons.enumerated() {
            b.image = dot(diameter: [4, 7, 11][i], selected: i == size)
        }
    }

    private func swatch(_ c: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4))
            c.setFill()
            circle.fill()
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
            return true
        }
    }

    private func dot(diameter: CGFloat, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 22), flipped: false) { r in
            let d = NSBezierPath(ovalIn: CGRect(x: r.midX - diameter / 2, y: r.midY - diameter / 2, width: diameter, height: diameter))
            (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
            d.fill()
            return true
        }
    }

    // MARK: - 操作

    @objc private func toolClicked(_ sender: NSButton) {
        let t = Tool(rawValue: sender.tag)
        tool = (tool == t) ? nil : t
        refresh()
        relayout()
        delegate?.toolbar(self, didSelect: tool)
    }

    @objc private func colorClicked(_ sender: NSButton) {
        color = Self.palette[sender.tag]
        refresh()
        delegate?.toolbarStyleDidChange(self)
    }

    @objc private func sizeClicked(_ sender: NSButton) {
        size = sender.tag
        refresh()
        delegate?.toolbarStyleDidChange(self)
    }

    @objc private func brushChanged() {
        redactBrush = brushControl.selectedSegment == 1
        delegate?.toolbarStyleDidChange(self)
    }

    @objc private func undo() { delegate?.toolbar(self, perform: .undo) }
    @objc private func redo() { delegate?.toolbar(self, perform: .redo) }
    @objc private func longCapture() { delegate?.toolbar(self, perform: .longCapture) }
    @objc private func startScroll() { delegate?.toolbar(self, perform: .startScroll) }
    @objc private func cancel() { delegate?.toolbar(self, perform: .cancel) }
    @objc private func save() { delegate?.toolbar(self, perform: .save) }
    @objc private func done() { delegate?.toolbar(self, perform: .done) }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}
