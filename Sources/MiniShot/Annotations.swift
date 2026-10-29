import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum Tool: Int, CaseIterable {
    case rect, ellipse, arrow, line, pen, highlighter, text, counter, mosaic, blur
    var isRedaction: Bool { self == .mosaic || self == .blur }
}

/// 画布的底图，以及打码用的滤镜。坐标都是画布的点坐标（左下角原点）。
final class CanvasContent {
    let image: CGImage
    let scale: CGFloat
    private let source: CIImage
    private let ciContext = CIContext()

    enum Effect: Equatable {
        case mosaic(block: CGFloat)   // 像素块边长（点）
        case blur(radius: CGFloat)    // 模糊半径（点）
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        source = CIImage(cgImage: image).clampedToExtent()
    }

    var size: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// 对 rect 范围内的底图应用效果，返回结果图和它实际覆盖的范围
    func filteredPatch(_ effect: Effect, covering rect: CGRect) -> (image: CGImage, rect: CGRect)? {
        let r = rect.intersection(CGRect(origin: .zero, size: size))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        let output: CIImage?
        switch effect {
        case .mosaic(let block):
            let f = CIFilter.pixellate()
            f.inputImage = source
            f.center = .zero          // 像素块对齐到图片原点，移动打码区域时块不会跳
            f.scale = Float(block * scale)
            output = f.outputImage
        case .blur(let radius):
            let f = CIFilter.gaussianBlur()
            f.inputImage = source
            f.radius = Float(radius * scale)
            output = f.outputImage
        }
        guard let output, let cg = ciContext.createCGImage(output, from: px) else { return nil }
        return (cg, CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale))
    }
}

/// 标注的基类。标注以矢量形式保存，导出时才和底图合成。
class Annotation {
    var color: NSColor
    /// 0 小、1 中、2 大
    var size: Int
    /// 正在编辑的文字暂时隐藏，由输入框代替显示
    var hidden = false

    init(color: NSColor, size: Int) {
        self.color = color
        self.size = size
    }

    func clone() -> Annotation { fatalError("subclass must override") }

    var level: Int { max(0, min(2, size)) }
    var lineWidth: CGFloat { [2, 4, 7][level] }
    var bounds: CGRect { .zero }
    var handles: [CGPoint] { [] }
    var isRedaction: Bool { false }
    /// 拖得太小，视为误触
    var isTrivial: Bool { bounds.width < 3 && bounds.height < 3 }

    func draw(in ctx: CGContext, content: CanvasContent) {}
    func hitTest(_ p: CGPoint) -> Bool { false }
    func move(by d: CGVector) {}
    func moveHandle(_ index: Int, to p: CGPoint) {}
}

private func corners(_ r: CGRect) -> [CGPoint] {
    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
}

private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

private func offset(_ p: CGPoint, _ d: CGVector) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }

/// 由两点确定的图形：矩形、椭圆、直线、箭头
final class ShapeAnnotation: Annotation {
    enum Kind { case rect, ellipse, line, arrow }
    let kind: Kind
    var start: CGPoint
    var end: CGPoint

    init(kind: Kind, start: CGPoint, end: CGPoint, color: NSColor, size: Int) {
        self.kind = kind
        self.start = start
        self.end = end
        super.init(color: color, size: size)
    }

    override func clone() -> Annotation {
        ShapeAnnotation(kind: kind, start: start, end: end, color: color, size: size)
    }

    var rect: CGRect { rectFrom(start, end) }
    override var bounds: CGRect { rect.insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3) }
    override var isTrivial: Bool {
        switch kind {
        case .line, .arrow: hypot(end.x - start.x, end.y - start.y) < 4
        case .rect, .ellipse: rect.width < 3 || rect.height < 3
        }
    }

    override var handles: [CGPoint] {
        switch kind {
        case .line, .arrow: [start, end]
        case .rect, .ellipse: corners(rect)
        }
    }

    override func moveHandle(_ index: Int, to p: CGPoint) {
        switch kind {
        case .line, .arrow:
            if index == 0 { start = p } else { end = p }
        case .rect, .ellipse:
            start = corners(rect)[(index + 2) % 4]
            end = p
        }
    }

    override func move(by d: CGVector) {
        start = offset(start, d)
        end = offset(end, d)
    }

    private var path: CGPath {
        switch kind {
        case .rect: return CGPath(rect: rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .line, .arrow:
            let m = CGMutablePath()
            m.move(to: start)
            m.addLine(to: end)
            return m
        }
    }

    override func draw(in ctx: CGContext, content: CanvasContent) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if kind == .arrow {
            drawArrow(ctx)
        } else {
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    private func drawArrow(_ ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let angle = atan2(dy, dx)
        let head = min(length * 0.6, max(12, lineWidth * 4.5))
        let spread = CGFloat.pi / 7
        let base = CGPoint(x: end.x - cos(angle) * head * cos(spread), y: end.y - sin(angle) * head * cos(spread))
        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.strokePath()
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
        ctx.closePath()
        ctx.fillPath()
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        path.copy(strokingWithWidth: lineWidth + 10, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }
}

/// 自由画笔和荧光笔
final class PenAnnotation: Annotation {
    var points: [CGPoint]
    let highlighter: Bool

    init(points: [CGPoint], highlighter: Bool, color: NSColor, size: Int) {
        self.points = points
        self.highlighter = highlighter
        super.init(color: color, size: size)
    }

    override func clone() -> Annotation {
        PenAnnotation(points: points, highlighter: highlighter, color: color, size: size)
    }

    override var lineWidth: CGFloat { highlighter ? [10, 18, 28][level] : super.lineWidth }
    override var isTrivial: Bool { false }
    override var bounds: CGRect { path.boundingBoxOfPath.insetBy(dx: -lineWidth, dy: -lineWidth) }

    /// 用相邻点的中点做二次曲线，让笔迹平滑
    var path: CGPath {
        let m = CGMutablePath()
        guard let first = points.first else { return m }
        m.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { m.addLine(to: p) }
            if points.count == 1 { m.addLine(to: first) }
            return m
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            m.addQuadCurve(to: mid, control: points[i])
        }
        m.addLine(to: points[points.count - 1])
        return m
    }

    override func draw(in ctx: CGContext, content: CanvasContent) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if highlighter {
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
        } else {
            ctx.setStrokeColor(color.cgColor)
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        path.copy(strokingWithWidth: lineWidth + 8, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }

    override func move(by d: CGVector) {
        points = points.map { offset($0, d) }
    }
}

/// 文字，origin 是左上角
final class TextAnnotation: Annotation {
    var origin: CGPoint
    var text: String

    init(origin: CGPoint, text: String, color: NSColor, size: Int) {
        self.origin = origin
        self.text = text
        super.init(color: color, size: size)
    }

    override func clone() -> Annotation {
        TextAnnotation(origin: origin, text: text, color: color, size: size)
    }

    var font: NSFont { .systemFont(ofSize: [16, 24, 36][level], weight: .semibold) }
    var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: color] }

    var rect: CGRect {
        let s = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin], attributes: attributes)
        return CGRect(x: origin.x, y: origin.y - ceil(s.height), width: ceil(s.width), height: ceil(s.height))
    }

    override var bounds: CGRect { rect.insetBy(dx: -3, dy: -3) }
    override var isTrivial: Bool { text.isEmpty }

    override func draw(in ctx: CGContext, content: CanvasContent) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    override func hitTest(_ p: CGPoint) -> Bool { bounds.contains(p) }
    override func move(by d: CGVector) { origin = offset(origin, d) }
}

/// 序号 ①②③
final class CounterAnnotation: Annotation {
    var center: CGPoint
    let number: Int

    init(center: CGPoint, number: Int, color: NSColor, size: Int) {
        self.center = center
        self.number = number
        super.init(color: color, size: size)
    }

    override func clone() -> Annotation {
        CounterAnnotation(center: center, number: number, color: color, size: size)
    }

    var radius: CGFloat { [10, 13, 17][level] }
    override var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    override var isTrivial: Bool { false }

    override func draw(in ctx: CGContext, content: CanvasContent) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: bounds)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: bounds.insetBy(dx: 0.75, dy: 0.75))
        ctx.restoreGState()

        // 白色底的序号用黑字
        let rgb = color.usingColorSpace(.sRGB)
        let isLight = (rgb?.brightnessComponent ?? 0) > 0.85 && (rgb?.saturationComponent ?? 1) < 0.3
        let textColor: NSColor = isLight ? .black : .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
            .foregroundColor: textColor,
        ]
        let s = "\(number)" as NSString
        let size = s.size(withAttributes: attrs)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ p: CGPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) <= radius + 3 }
    override func move(by d: CGVector) { center = offset(center, d) }
}

/// 打码：马赛克或模糊，区域可以是矩形或涂抹路径
final class RedactionAnnotation: Annotation {
    enum Kind { case mosaic, blur }
    let kind: Kind
    var start: CGPoint
    var end: CGPoint
    /// 涂抹路径；nil 表示矩形区域
    var points: [CGPoint]?
    private var cache: (key: String, image: CGImage, rect: CGRect)?

    init(kind: Kind, start: CGPoint, end: CGPoint, points: [CGPoint]?, size: Int) {
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        super.init(color: .clear, size: size)
    }

    override func clone() -> Annotation {
        RedactionAnnotation(kind: kind, start: start, end: end, points: points, size: size)
    }

    override var isRedaction: Bool { true }
    var brushWidth: CGFloat { [16, 28, 44][level] }
    var effect: CanvasContent.Effect {
        kind == .mosaic ? .mosaic(block: [6, 10, 16][level]) : .blur(radius: [5, 10, 18][level])
    }

    var region: CGPath {
        if let points {
            let m = CGMutablePath()
            if let first = points.first {
                m.move(to: first)
                for p in points.dropFirst() { m.addLine(to: p) }
                if points.count == 1 { m.addLine(to: first) }
            }
            return m.copy(strokingWithWidth: brushWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        return CGPath(rect: rectFrom(start, end), transform: nil)
    }

    override var bounds: CGRect { region.boundingBoxOfPath }
    override var isTrivial: Bool {
        guard points == nil else { return false }
        let r = rectFrom(start, end)
        return r.width < 3 || r.height < 3
    }
    override var handles: [CGPoint] { points == nil ? corners(rectFrom(start, end)) : [] }

    override func moveHandle(_ index: Int, to p: CGPoint) {
        guard points == nil else { return }
        start = corners(rectFrom(start, end))[(index + 2) % 4]
        end = p
    }

    override func move(by d: CGVector) {
        start = offset(start, d)
        end = offset(end, d)
        points = points?.map { offset($0, d) }
    }

    override func draw(in ctx: CGContext, content: CanvasContent) {
        let b = bounds.integral
        guard b.width > 0, b.height > 0 else { return }
        let key = "\(b)-\(level)"
        if cache?.key != key {
            cache = content.filteredPatch(effect, covering: b).map { (key, $0.image, $0.rect) }
        }
        guard let cache else { return }
        ctx.saveGState()
        ctx.addPath(region)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(cache.image, in: cache.rect)
        ctx.restoreGState()
    }

    override func hitTest(_ p: CGPoint) -> Bool { region.contains(p) }
}

enum Renderer {
    /// 打码在最下层，其余标注按添加顺序叠加
    static func ordered(_ annotations: [Annotation]) -> [Annotation] {
        annotations.filter(\.isRedaction) + annotations.filter { !$0.isRedaction }
    }

    /// 按原始像素分辨率合成底图和标注
    static func render(content: CanvasContent, annotations: [Annotation]) -> CGImage? {
        let img = content.image
        guard !annotations.isEmpty else { return img }
        let cs = img.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.scaleBy(x: content.scale, y: content.scale)
        for a in ordered(annotations) { a.draw(in: ctx, content: content) }
        return ctx.makeImage()
    }
}
