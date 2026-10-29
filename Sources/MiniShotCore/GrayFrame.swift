import CoreGraphics

/// 用于比对的灰度帧：横向压缩到固定宽度，纵向保持原始像素行数，这样求出的垂直偏移是精确的像素值
public struct GrayFrame {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    /// 每行的哈希（像素先量化，容忍细微噪声）
    let rowHashes: [UInt64]
    /// 这一行有没有内容（纯色行不参与匹配，否则空白区域到处都能“匹配上”）
    let informative: [Bool]

    public static let defaultSampleWidth = 256

    public init?(image: CGImage, sampleWidth: Int = GrayFrame.defaultSampleWidth) {
        let w = min(sampleWidth, image.width), h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        var hashes = [UInt64](repeating: 0, count: height)
        var info = [Bool](repeating: false, count: height)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var lo: UInt8 = 255, hi: UInt8 = 0
                let base = y * width
                for x in 0..<width {
                    let v = p[base + x]
                    lo = min(lo, v)
                    hi = max(hi, v)
                    hash = (hash ^ UInt64(v >> 2)) &* 0x100_0000_01b3
                }
                hashes[y] = hash
                info[y] = hi - lo >= 16
            }
        }
        rowHashes = hashes
        informative = info
    }

    /// 两帧整体的平均灰度差（0–255）
    public func meanAbsDiff(_ other: GrayFrame) -> Double {
        guard width == other.width, height == other.height, !pixels.isEmpty else { return .infinity }
        var sum = 0
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
            }
        }
        return Double(sum) / Double(pixels.count)
    }

    /// 本帧第 row 行与 other 第 otherRow 行的平均灰度差
    func rowDiff(_ row: Int, _ other: GrayFrame, _ otherRow: Int) -> Double {
        var sum = 0
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                let ra = row * width, rb = otherRow * other.width
                for x in 0..<width { sum += abs(Int(a[ra + x]) - Int(b[rb + x])) }
            }
        }
        return Double(sum) / Double(width)
    }
}
