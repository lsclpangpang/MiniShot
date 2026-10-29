import AppKit
import UniformTypeIdentifiers

enum ExportAction {
    /// 按设置里的「截图完成后」处理
    case done
    case copy
    case save
}

enum ExportError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "无法写入图片文件" }
}

@MainActor
enum Exporter {
    static func export(_ image: CGImage, scale: CGFloat, action: ExportAction) {
        let after = Settings.shared.afterCapture
        let copy = action == .copy || (action == .done && after != .save)
        let save = action == .save || (action == .done && after != .copy)
        if copy { copyToPasteboard(image, scale: scale) }
        if save {
            do {
                try saveToFile(image, scale: scale)
            } catch {
                Alerts.show("保存失败", error.localizedDescription)
            }
        }
    }

    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    static func saveToFile(_ image: CGImage, scale: CGFloat) throws -> URL {
        let settings = Settings.shared
        let dir = settings.saveDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let isPNG = settings.imageFormat == .png
        let ext = isPNG ? "png" : "jpg"
        var url = dir.appendingPathComponent("MiniShot_\(stamp).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("MiniShot_\(stamp)-\(n).\(ext)")
            n += 1
        }

        let type = (isPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw ExportError.writeFailed }
        // 写入 DPI，预览等 App 才会按实际尺寸显示 Retina 截图
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if !isPNG { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed }
        return url
    }
}
