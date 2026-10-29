import CoreGraphics
#if canImport(Vision)
import Vision
#endif

public struct OffsetEstimate: Equatable {
    /// 内容向上移动的像素数：current 的第 r 行 == previous 的第 r + dy 行
    public let dy: Int
    /// 重叠区域里有内容的行中，完全匹配的比例
    public let score: Double
}

public enum OffsetEstimator {
    /// 逐行哈希匹配求垂直偏移。只比较 [top, height - bottom) 之间的行（排除固定的头部和底部）。
    /// hint 是预期的偏移（自动滚动时已知），用来在重复内容造成的多个候选里挑一个。
    public static func estimate(previous p: GrayFrame, current c: GrayFrame,
                                top: Int = 0, bottom: Int = 0,
                                hint: Int? = nil, minScore: Double = 0.85) -> OffsetEstimate? {
        guard p.width == c.width, p.height == c.height else { return nil }
        let lo = max(0, top), hi = p.height - max(0, bottom)
        let band = hi - lo
        guard band >= 16 else { return nil }
        let minOverlap = max(8, band / 10)
        let minRows = 6

        var candidates: [(dy: Int, score: Double, matched: Int)] = []
        p.rowHashes.withUnsafeBufferPointer { ph in
            c.rowHashes.withUnsafeBufferPointer { ch in
                p.informative.withUnsafeBufferPointer { pi in
                    c.informative.withUnsafeBufferPointer { ci in
                        for dy in 0...(band - minOverlap) {
                            var compared = 0, matched = 0
                            for r in lo..<(hi - dy) where pi[r + dy] || ci[r] {
                                compared += 1
                                if ph[r + dy] == ch[r] { matched += 1 }
                            }
                            if compared >= minRows {
                                candidates.append((dy, Double(matched) / Double(compared), matched))
                            }
                        }
                    }
                }
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }), best.score >= minScore else { return nil }
        let near = candidates.filter { $0.score >= best.score - 0.02 }
        let chosen: (dy: Int, score: Double, matched: Int)
        if let hint {
            chosen = near.min(by: { abs($0.dy - hint) < abs($1.dy - hint) })!
        } else {
            // 重复内容时，匹配行数最多的就是位移最小的那个
            chosen = near.max(by: { $0.matched < $1.matched })!
        }
        return OffsetEstimate(dy: chosen.dy, score: chosen.score)
    }

    /// 按给定偏移，重叠区域的平均灰度差，用来验证候选偏移
    public static func overlapDiff(previous p: GrayFrame, current c: GrayFrame,
                                   dy: Int, top: Int = 0, bottom: Int = 0) -> Double? {
        guard p.width == c.width, p.height == c.height, dy >= 0 else { return nil }
        let lo = max(0, top), hi = p.height - max(0, bottom)
        guard hi - dy - lo >= 8 else { return nil }
        var sum = 0.0
        for r in lo..<(hi - dy) { sum += c.rowDiff(r, p, r + dy) }
        return sum / Double(hi - dy - lo)
    }

    #if canImport(Vision)
    /// 兜底：照片、渐变这类逐行哈希对不上的内容，用 Vision 求平移，再用灰度差验证
    public static func estimateWithVision(previous: CGImage, current: CGImage,
                                          previousGray: GrayFrame, currentGray: GrayFrame,
                                          top: Int = 0, bottom: Int = 0) -> OffsetEstimate? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let ty = Int(abs(observation.alignmentTransform.ty).rounded())
        guard ty > 0 else { return nil }
        // Vision 的结果有亚像素误差、方向也不确定，在附近找灰度差最小的整数偏移
        var best: (dy: Int, diff: Double)?
        for dy in max(1, ty - 2)...(ty + 2) {
            guard let d = overlapDiff(previous: previousGray, current: currentGray, dy: dy, top: top, bottom: bottom) else { continue }
            if best == nil || d < best!.diff { best = (dy, d) }
        }
        guard let best, best.diff < 6 else { return nil }
        return OffsetEstimate(dy: best.dy, score: 1 - best.diff / 255)
    }
    #endif
}
