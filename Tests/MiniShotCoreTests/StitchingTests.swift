import CoreGraphics
import XCTest
@testable import MiniShotCore

/// 用合成图模拟“带固定头尾的页面滚动”，验证偏移计算和拼接能逐像素还原原图
final class StitchingTests: XCTestCase {
    let width = 320
    let header = 40
    let footer = 30
    let body = 400
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 合成数据

    /// 伪随机的块状内容，每两行一变，相邻列成块，近似文字和图标
    func makeContent(height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var h = UInt32(truncatingIfNeeded: (x / 6) &* 73_856_093) ^ UInt32(truncatingIfNeeded: (y / 2) &* 19_349_663)
                h = (h ^ (h >> 13)) &* 0x5bd1_e995
                h ^= h >> 15
                let i = (y * width + x) * 4
                bytes[i] = UInt8(h & 0xff)
                bytes[i + 1] = UInt8((h >> 8) & 0xff)
                bytes[i + 2] = UInt8((h >> 16) & 0xff)
            }
        }
        return image(from: bytes, width: width, height: height)
    }

    func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let data = CFDataCreate(nil, bytes, bytes.count)!
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func context(height: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        return ctx
    }

    /// 在上下文里从顶部往下依次画：固定头部、内容的 [offset, offset + bodyHeight)、固定底部
    func compose(content: CGImage, offset: Int, bodyHeight: Int) -> CGImage {
        let total = header + bodyHeight + footer
        let ctx = context(height: total)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: total - header, width: width, height: header))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: total - header + 10, width: 120, height: 16))
        let slice = content.cropping(to: CGRect(x: 0, y: offset, width: width, height: bodyHeight))!
        ctx.draw(slice, in: CGRect(x: 0, y: footer, width: width, height: bodyHeight))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 8, width: 200, height: 12))
        return ctx.makeImage()!
    }

    func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: image.width * image.height * 4))
    }

    // MARK: - 测试

    func testStickyRegionDetection() {
        let content = makeContent(height: 1200)
        let a = GrayFrame(image: compose(content: content, offset: 0, bodyHeight: body))!
        let b = GrayFrame(image: compose(content: content, offset: 150, bodyHeight: body))!
        let sticky = StickyRegionDetector.detect(a, b)
        XCTAssertEqual(sticky.top, header)
        XCTAssertEqual(sticky.bottom, footer)
    }

    func testNoMovementGivesZero() {
        let content = makeContent(height: 1200)
        let a = GrayFrame(image: compose(content: content, offset: 100, bodyHeight: body))!
        let est = OffsetEstimator.estimate(previous: a, current: a)
        XCTAssertEqual(est?.dy, 0)
    }

    func testOffsetsAndStitchReproduceOriginal() {
        let steps = [150, 230, 220, 200, 340, 10, 90, 300]
        let offsets = steps.reduce(into: [0]) { $0.append($0.last! + $1) }
        let content = makeContent(height: offsets.last! + body)
        let frames = offsets.map { compose(content: content, offset: $0, bodyHeight: body) }
        let grays = frames.map { GrayFrame(image: $0)! }

        let sticky = StickyRegionDetector.detect(grays[0], grays[1])
        let stitcher = Stitcher(first: frames[0])!
        stitcher.setSticky(top: sticky.top, bottom: sticky.bottom)

        for i in 1..<frames.count {
            let est = OffsetEstimator.estimate(previous: grays[i - 1], current: grays[i],
                                               top: stitcher.top, bottom: stitcher.bottom)
            XCTAssertEqual(est?.dy, steps[i - 1], "第 \(i) 帧偏移不对")
            XCTAssertTrue(stitcher.append(frames[i], offset: est?.dy ?? 0))
        }

        let expected = compose(content: content, offset: 0, bodyHeight: offsets.last! + body)
        let result = stitcher.makeImage()!
        XCTAssertEqual(result.width, expected.width)
        XCTAssertEqual(result.height, expected.height)
        XCTAssertTrue(pixels(result) == pixels(expected), "拼接结果和原图不一致")
    }

    func testBackwardScrollIsNotMatchedForward() {
        let content = makeContent(height: 1200)
        let a = GrayFrame(image: compose(content: content, offset: 300, bodyHeight: body))!
        let b = GrayFrame(image: compose(content: content, offset: 150, bodyHeight: body))!
        XCTAssertNil(OffsetEstimator.estimate(previous: a, current: b, top: header, bottom: footer))
        XCTAssertEqual(OffsetEstimator.estimate(previous: b, current: a, top: header, bottom: footer)?.dy, 150)
    }

    func testThumbnail() {
        let content = makeContent(height: 1200)
        let stitcher = Stitcher(first: compose(content: content, offset: 0, bodyHeight: body))!
        let thumb = stitcher.makeImage(scale: 0.5)!
        XCTAssertEqual(thumb.width, width / 2)
        XCTAssertEqual(thumb.height, (header + body + footer) / 2)
    }
}
