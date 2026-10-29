import AppKit
import MiniShotCore

/// 长截图：反复截取选区，计算与上一帧的偏移，把新出现的内容拼接起来
@MainActor
final class ScrollSession {
    typealias Result = (image: CGImage, scale: CGFloat)

    private enum Step { case unchanged, appended, failed, backward, limitReached }

    private static let maxHeight = 30_000
    private static let escHotKeyID: UInt32 = 90

    private let screen: NSScreen
    /// 屏幕内的点坐标（左下角原点）
    private let rect: CGRect
    private var auto: Bool
    private let onFinish: (Result?) -> Void
    private let border: BorderWindow
    private let panel: ScrollPanel

    private var grabber: RegionGrabber?
    private var stitcher: Stitcher?
    private var lastGray: GrayFrame?
    private var lastImage: CGImage?
    private var stickyDecided = false
    private var scale: CGFloat = 2
    private var task: Task<Void, Never>?
    private var finished = false
    private var lastPreview = Date.distantPast
    /// 滚轮方向：先假设负值是向下，不对的话第一次滚动后自动翻转
    private var wheelSign: Int32 = -1

    private var globalRect: CGRect { rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }

    init(screen: NSScreen, rect: CGRect, auto: Bool, onFinish: @escaping (Result?) -> Void) {
        self.screen = screen
        self.rect = rect
        self.auto = auto
        self.onFinish = onFinish
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        border = BorderWindow(around: global)
        panel = ScrollPanel(beside: global, on: screen)
    }

    func start() {
        border.orderFrontRegardless()
        panel.onDone = { [weak self] in self?.finish(cancelled: false) }
        panel.onCancel = { [weak self] in self?.finish(cancelled: true) }
        panel.show()
        HotKeyCenter.shared.set(id: Self.escHotKeyID, combo: KeyCombo(keyCode: 53, modifiers: 0, display: "⎋")) { [weak self] in
            self?.finish(cancelled: false)
        }
        if auto && !Permissions.accessibility {
            auto = false
            Permissions.requestAccessibility()
            panel.setWarning("未授权辅助功能，已改为手动滚动")
        }
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            // 等边框和面板出现在窗口列表里，才能把它们排除在截图之外
            try await Task.sleep(nanoseconds: 150_000_000)
            let g = try await RegionGrabber.make(screen: screen, rect: rect,
                                                 canCaptureByRect: !panel.frame.intersects(globalRect))
            grabber = g
            scale = g.scale
            let first = try await g.capture()
            guard let st = Stitcher(first: first), let gray = GrayFrame(image: first) else {
                throw GrabError.displayNotFound
            }
            stitcher = st
            lastGray = gray
            lastImage = first
            updateStatus()
            updatePreview(force: true)
            if auto { try await autoLoop() } else { try await manualLoop() }
        } catch is CancellationError {
        } catch {
            guard !finished else { return }
            finish(cancelled: true)
            Alerts.show("长截图失败", error.localizedDescription)
        }
    }

    // MARK: - 手动滚动

    private func manualLoop() async throws {
        panel.setHint("请向下滚动页面\n完成后按 Esc 或点「完成」")
        while !finished {
            try await Task.sleep(nanoseconds: 80_000_000)
            guard let image = try? await grabber?.capture(), !finished else { continue }
            handle(process(image, hint: nil))
        }
    }

    // MARK: - 自动滚动

    private func autoLoop() async throws {
        panel.setHint("正在自动滚动，请不要移动鼠标\n按 Esc 或点「完成」停止")
        let center = CGPoint(x: globalRect.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - globalRect.midY)
        CGWarpMouseCursorPosition(center)
        let stepPoints = rect.height * 0.6
        var stalls = 0, failures = 0, flipped = false

        while !finished {
            try await scroll(by: stepPoints, at: center)
            let image = try await waitForStableFrame()
            guard !finished else { break }
            let result = process(image, hint: Int(stepPoints * scale))
            handle(result)
            switch result {
            case .appended:
                stalls = 0
                failures = 0
            case .unchanged:
                // 一帧都还没拼上就不动，可能是方向反了
                if stitcher?.appendedCount == 0 && !flipped {
                    flipped = true
                    wheelSign = -wheelSign
                } else {
                    stalls += 1
                    if stalls >= 2 { finish(cancelled: false) }
                }
            case .backward:
                if !flipped {
                    flipped = true
                    wheelSign = -wheelSign
                } else {
                    stalls += 1
                    if stalls >= 2 { finish(cancelled: false) }
                }
            case .failed:
                failures += 1
                if failures >= 3 { finish(cancelled: false) }
            case .limitReached:
                break
            }
        }
    }

    /// 分几次发送滚轮事件，避免单次滚动量过大被 App 截断
    private func scroll(by points: CGFloat, at location: CGPoint) async throws {
        let chunks = 6
        let delta = Int32((points / CGFloat(chunks)).rounded()) * wheelSign
        for _ in 0..<chunks {
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: delta, wheel2: 0, wheel3: 0) {
                event.location = location
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    /// 等平滑滚动、懒加载等动画结束：连续两帧相同才返回
    private func waitForStableFrame() async throws -> CGImage {
        guard let g = grabber else { throw CancellationError() }
        var previous = try await g.capture()
        var previousGray = GrayFrame(image: previous)
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 70_000_000)
            let image = try await g.capture()
            let gray = GrayFrame(image: image)
            if let a = gray, let b = previousGray, a.meanAbsDiff(b) < 0.4 { return image }
            previous = image
            previousGray = gray
        }
        return previous
    }

    // MARK: - 拼接

    private func process(_ image: CGImage, hint: Int?) -> Step {
        guard let stitcher, let previous = lastGray, let current = GrayFrame(image: image) else { return .failed }
        if current.meanAbsDiff(previous) < 0.4 { return .unchanged }

        var top = stitcher.top, bottom = stitcher.bottom
        if !stickyDecided {
            let sticky = StickyRegionDetector.detect(previous, current)
            // 变化的行太少，多半是光标闪烁、悬停效果，不是滚动，不能据此判断固定区域
            if Double(sticky.top + sticky.bottom) < Double(current.height) * 0.6 {
                top = sticky.top
                bottom = sticky.bottom
            } else {
                top = 0
                bottom = 0
            }
        }

        var estimate = OffsetEstimator.estimate(previous: previous, current: current, top: top, bottom: bottom, hint: hint)
        if estimate == nil, let lastImage {
            estimate = OffsetEstimator.estimateWithVision(previous: lastImage, current: image, previousGray: previous,
                                                          currentGray: current, top: top, bottom: bottom)
        }
        guard let estimate else {
            let reverse = OffsetEstimator.estimate(previous: current, current: previous, top: top, bottom: bottom)
            return (reverse?.dy ?? 0) > 0 ? .backward : .failed
        }
        if estimate.dy == 0 { return .unchanged }

        if !stickyDecided {
            stitcher.setSticky(top: top, bottom: bottom)
            stickyDecided = true
        }
        guard stitcher.append(image, offset: estimate.dy) else { return .failed }
        lastGray = current
        lastImage = image
        return stitcher.totalHeight >= Self.maxHeight ? .limitReached : .appended
    }

    private func handle(_ step: Step) {
        switch step {
        case .appended:
            panel.setWarning(nil)
            updateStatus()
            updatePreview(force: false)
        case .failed:
            panel.setWarning(auto ? "对不齐，正在重试" : "滚动太快了，请往回滚一点再慢慢滚")
        case .backward:
            if !auto { panel.setWarning("只支持向下滚动") }
        case .limitReached:
            updateStatus()
            finish(cancelled: false)
        case .unchanged:
            break
        }
    }

    private func updateStatus() {
        guard let stitcher else { return }
        panel.setStatus("已拼接 \(stitcher.totalHeight) 像素")
    }

    private func updatePreview(force: Bool) {
        guard let stitcher, force || Date().timeIntervalSince(lastPreview) > 0.3 else { return }
        lastPreview = Date()
        let previewWidth = ScrollPanel.previewWidth * 2
        if let thumb = stitcher.makeImage(scale: previewWidth / CGFloat(stitcher.width)) {
            panel.setPreview(thumb)
        }
    }

    // MARK: - 结束

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        task?.cancel()
        HotKeyCenter.shared.remove(id: Self.escHotKeyID)
        border.orderOut(nil)
        panel.close()
        let image = cancelled ? nil : stitcher?.makeImage()
        onFinish(image.map { ($0, scale) })
    }
}

/// 选区外围的虚线框，不接收鼠标，滚轮事件能穿透到下面的 App
final class BorderWindow: NSWindow {
    init(around rect: CGRect) {
        super.init(contentRect: rect.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = BorderView()
    }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 画在选区外侧 1–3pt 处，不会进入截图
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

/// 选区旁边的浮动面板：拼接预览、状态和完成 / 取消按钮
@MainActor
final class ScrollPanel {
    static let previewWidth: CGFloat = 200
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let imageView = NSImageView()
    private let status = NSTextField(labelWithString: "准备中…")
    private let warning = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let target = ButtonTarget()

    init(beside rect: CGRect, on screen: NSScreen) {
        panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "长截图"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignBottom
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let previewHeight = min(320, max(160, rect.height * 0.6))
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: Self.previewWidth),
            imageView.heightAnchor.constraint(equalToConstant: previewHeight),
        ])

        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .systemOrange
        warning.isHidden = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Self.previewWidth

        let cancel = NSButton(title: "取消", target: target, action: #selector(ButtonTarget.cancel))
        let done = NSButton(title: "完成", target: target, action: #selector(ButtonTarget.done))
        done.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [cancel, done])
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [imageView, status, warning, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Self.previewWidth).isActive = true
        panel.contentView = stack

        let size = stack.fittingSize
        panel.setContentSize(size)
        let frameSize = panel.frame.size
        let visible = screen.visibleFrame
        var x = rect.maxX + 12
        if x + frameSize.width > visible.maxX {
            x = rect.minX - 12 - frameSize.width
            if x < visible.minX { x = visible.maxX - frameSize.width - 12 }
        }
        let y = min(max(rect.maxY - frameSize.height, visible.minY), visible.maxY - frameSize.height)
        panel.setFrameOrigin(CGPoint(x: x, y: y))

        target.onDone = { [weak self] in self?.onDone?() }
        target.onCancel = { [weak self] in self?.onCancel?() }
    }

    var frame: CGRect { panel.frame }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }

    func setStatus(_ text: String) { status.stringValue = text }
    func setHint(_ text: String) { hint.stringValue = text }

    func setWarning(_ text: String?) {
        warning.stringValue = text ?? ""
        warning.isHidden = text == nil
    }

    func setPreview(_ image: CGImage) {
        let w = Self.previewWidth
        imageView.image = NSImage(cgImage: image, size: CGSize(width: w, height: CGFloat(image.height) * w / CGFloat(image.width)))
    }
}

private final class ButtonTarget: NSObject {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    @objc func done() { onDone?() }
    @objc func cancel() { onCancel?() }
}
