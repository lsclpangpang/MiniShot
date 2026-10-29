/// 找出两帧之间没有随滚动变化的顶部和底部区域（网页导航栏、聊天输入框等）。
/// 这些区域会干扰匹配，拼接时也只需要保留一份。
/// 纯色的空白区域也可能被当成固定区域，这不影响结果：内容总会在中间的滚动区域里被截到。
public enum StickyRegionDetector {
    public static func detect(_ a: GrayFrame, _ b: GrayFrame, maxFraction: Double = 0.4) -> (top: Int, bottom: Int) {
        guard a.width == b.width, a.height == b.height else { return (0, 0) }
        let limit = Int(Double(a.height) * maxFraction)
        var top = 0
        while top < limit, a.rowDiff(top, b, top) <= 1.0 { top += 1 }
        var bottom = 0
        while bottom < limit, a.rowDiff(a.height - 1 - bottom, b, a.height - 1 - bottom) <= 1.0 { bottom += 1 }
        return (top, bottom)
    }
}
