import CoreGraphics

/// 把连续滚动的帧拼成长图。
/// 输出 = 第一帧（含固定头部）[0, H - bottom) + 每帧新增的内容 + 最后一帧的固定底部 [H - bottom, H)
public final class Stitcher {
    public let width: Int
    public let frameHeight: Int
    public private(set) var top = 0
    public private(set) var bottom = 0
    public var appendedCount: Int { strips.count }
    public var totalHeight: Int { frameHeight + stripsHeight }

    private let first: CGImage
    private var last: CGImage
    /// 每次新增的内容条带，已拷贝成独立图片，不再引用整帧
    private var strips: [CGImage] = []
    private var stripsHeight = 0
    private let colorSpace: CGColorSpace

    public init?(first: CGImage) {
        guard first.width > 0, first.height > 16 else { return nil }
        self.first = first
        self.last = first
        width = first.width
        frameHeight = first.height
        if let cs = first.colorSpace, cs.supportsOutput {
            colorSpace = cs
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    /// 设置固定的头部和底部高度，只能在追加第一帧之前调用
    public func setSticky(top: Int, bottom: Int) {
        guard strips.isEmpty else { return }
        var t = max(0, top), b = max(0, bottom)
        let maxTotal = frameHeight - 16
        if t + b > maxTotal {
            let excess = t + b - maxTotal
            let cutTop = min(t, (excess + 1) / 2)
            t -= cutTop
            b -= excess - cutTop
        }
        self.top = t
        self.bottom = max(0, b)
    }

    /// 追加一帧，dy 是相对上一次追加的帧，内容向上移动的像素数
    @discardableResult
    public func append(_ frame: CGImage, offset dy: Int) -> Bool {
        guard frame.width == width, frame.height == frameHeight,
              dy > 0, dy <= frameHeight - top - bottom else { return false }
        let rect = CGRect(x: 0, y: frameHeight - bottom - dy, width: width, height: dy)
        guard let cropped = frame.cropping(to: rect), let strip = copy(cropped) else { return false }
        strips.append(strip)
        stripsHeight += dy
        last = frame
        return true
    }

    /// 生成拼接结果；scale < 1 时生成缩略图
    public func makeImage(scale: CGFloat = 1) -> CGImage? {
        let outW = max(1, Int((CGFloat(width) * scale).rounded()))
        let outH = max(1, Int((CGFloat(totalHeight) * scale).rounded()))
        guard let ctx = makeContext(outW, outH) else { return nil }
        ctx.interpolationQuality = scale == 1 ? .none : .medium
        ctx.scaleBy(x: CGFloat(outW) / CGFloat(width), y: CGFloat(outH) / CGFloat(totalHeight))

        var cursor = CGFloat(totalHeight)
        func put(_ image: CGImage?, _ h: Int) {
            guard h > 0, let image else { return }
            cursor -= CGFloat(h)
            ctx.draw(image, in: CGRect(x: 0, y: cursor, width: CGFloat(width), height: CGFloat(h)))
        }
        put(first.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight - bottom)), frameHeight - bottom)
        for s in strips { put(s, s.height) }
        put(last.cropping(to: CGRect(x: 0, y: frameHeight - bottom, width: width, height: bottom)), bottom)
        return ctx.makeImage()
    }

    private func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private func copy(_ image: CGImage) -> CGImage? {
        guard let ctx = makeContext(image.width, image.height) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
