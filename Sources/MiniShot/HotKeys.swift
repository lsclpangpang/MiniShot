import AppKit
import Carbon
import SwiftUI

/// 全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能权限）
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon 修饰键：cmdKey、shiftKey、optionKey、controlKey
    var display: String

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// 从按键事件生成；必须带 ⌘ / ⌃ / ⌥ 之一，F1–F12 例外
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFunctionKey = Self.functionKeys[event.keyCode] != nil
        guard isFunctionKey || flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        var m: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { m |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { m |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { m |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { m |= UInt32(cmdKey); symbols += "⌘" }
        let name = Self.functionKeys[event.keyCode] ?? Self.specialKeys[event.keyCode]
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, display: symbols + name)
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var combo: KeyCombo
        var handler: @MainActor () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [UInt32: Entry] = [:]
    private var suspended = false
    private var installed = false

    func set(id: UInt32, combo: KeyCombo, handler: @escaping @MainActor () -> Void) {
        installIfNeeded()
        remove(id: id)
        entries[id] = Entry(combo: combo, handler: handler, ref: nil)
        if !suspended { register(id) }
    }

    func remove(id: UInt32) {
        if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
        entries[id] = nil
    }

    /// 录制新快捷键时暂停，否则按下已有的组合会直接触发截图
    func suspend() {
        suspended = true
        for id in entries.keys {
            if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        suspended = false
        for id in entries.keys { register(id) }
    }

    fileprivate func fire(_ id: UInt32) {
        entries[id]?.handler()
    }

    private func register(_ id: UInt32) {
        guard let entry = entries[id], entry.ref == nil else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D53_4854), id: id) // 'MSHT'
        let status = RegisterEventHotKey(entry.combo.keyCode, entry.combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { entries[id]?.ref = ref }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if err == noErr {
                let id = hotKeyID.id
                Task { @MainActor in HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// 设置页里的快捷键录制按钮
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "请按下快捷键…" : combo.display) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
            } else if let c = KeyCombo(event: event) {
                combo = c
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeyCenter.shared.resume()
    }
}
