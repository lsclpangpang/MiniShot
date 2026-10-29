import Carbon
import Foundation

enum AfterCapture: String, CaseIterable {
    case copy, save, both
    var title: String {
        switch self {
        case .copy: "复制到剪贴板"
        case .save: "保存到文件"
        case .both: "复制并保存"
        }
    }
}

enum ImageFormat: String, CaseIterable {
    case png, jpg
    var title: String { self == .png ? "PNG" : "JPG" }
}

enum ScrollMode: String, CaseIterable {
    case manual, auto
    var title: String { self == .manual ? "手动滚动" : "自动滚动" }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    var onHotKeysChanged: (() -> Void)?

    @Published var captureHotKey: KeyCombo {
        didSet { Self.store(captureHotKey, "captureHotKey"); onHotKeysChanged?() }
    }
    @Published var scrollHotKey: KeyCombo {
        didSet { Self.store(scrollHotKey, "scrollHotKey"); onHotKeysChanged?() }
    }
    @Published var afterCapture: AfterCapture {
        didSet { UserDefaults.standard.set(afterCapture.rawValue, forKey: "afterCapture") }
    }
    @Published var saveDirectory: String {
        didSet { UserDefaults.standard.set(saveDirectory, forKey: "saveDirectory") }
    }
    @Published var imageFormat: ImageFormat {
        didSet { UserDefaults.standard.set(imageFormat.rawValue, forKey: "imageFormat") }
    }
    @Published var scrollMode: ScrollMode {
        didSet { UserDefaults.standard.set(scrollMode.rawValue, forKey: "scrollMode") }
    }

    private init() {
        let d = UserDefaults.standard
        captureHotKey = Self.load("captureHotKey") ?? .defaultCapture
        scrollHotKey = Self.load("scrollHotKey") ?? .defaultScroll
        afterCapture = AfterCapture(rawValue: d.string(forKey: "afterCapture") ?? "") ?? .copy
        saveDirectory = d.string(forKey: "saveDirectory") ?? "~/Desktop"
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        scrollMode = ScrollMode(rawValue: d.string(forKey: "scrollMode") ?? "") ?? .manual
    }

    var saveDirectoryURL: URL {
        URL(fileURLWithPath: (saveDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private static func store(_ combo: KeyCombo, _ key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension KeyCombo {
    static let defaultCapture = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | shiftKey), display: "⌃⇧A")
    static let defaultScroll = KeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | shiftKey), display: "⌃⇧L")
}
