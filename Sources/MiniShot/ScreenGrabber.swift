import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// 按下快捷键那一刻冻结下来的某块屏幕
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    /// 像素 / 点
    let scale: CGFloat
}

enum GrabError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { "找不到要截取的显示器" }
}

enum ScreenGrabber {
    /// 截下所有屏幕的完整画面
    @MainActor
    static func freezeAll() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenScreen(screen: screen, image: image,
                                       scale: CGFloat(image.width) / screen.frame.width))
        }
        return result
    }
}

/// 长截图时反复截取同一块区域，排除 MiniShot 自己的边框和面板
final class RegionGrabber {
    let scale: CGFloat
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    private init(filter: SCContentFilter, config: SCStreamConfiguration, scale: CGFloat) {
        self.filter = filter
        self.config = config
        self.scale = scale
    }

    /// rect 是屏幕内的点坐标（左下角原点，和 NSView 一致）
    @MainActor
    static func make(screen: NSScreen, rect: CGRect) async throws -> RegionGrabber {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { throw GrabError.displayNotFound }
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // ScreenCaptureKit 的 sourceRect 以显示器左上角为原点
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return RegionGrabber(filter: filter, config: config, scale: scale)
    }

    func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// 屏幕上的普通窗口，用于框选时的窗口吸附
struct WindowInfo {
    /// Cocoa 全局坐标（主屏左下角原点）
    let frame: CGRect
}

enum WindowList {
    /// 从前到后排列的可见窗口
    @MainActor
    static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict),
                  cg.width > 20, cg.height > 20 else { return nil }
            // CGWindowList 用的是左上角原点
            return WindowInfo(frame: CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height))
        }
    }
}
