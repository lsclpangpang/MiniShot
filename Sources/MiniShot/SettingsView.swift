import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var screenOK = Permissions.screenRecording
    @State private var accessibilityOK = Permissions.accessibility
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("截图") { KeyRecorder(combo: $settings.captureHotKey) }
                LabeledContent("长截图") { KeyRecorder(combo: $settings.scrollHotKey) }
            }

            Section("输出") {
                Picker("截图完成后", selection: $settings.afterCapture) {
                    ForEach(AfterCapture.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("保存位置") {
                    HStack {
                        Text(settings.saveDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…", action: chooseDirectory)
                    }
                }
                Picker("图片格式", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("滚动方式", selection: $settings.scrollMode) {
                    ForEach(ScrollMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("长截图")
            } footer: {
                Text(settings.scrollMode == .manual
                     ? "框选区域后自己滚动页面，MiniShot 在后台截取并拼接。"
                     : "MiniShot 自动向下滚动直到底部，需要辅助功能权限，未授权时改为手动滚动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通用") {
                Toggle("登录时自动打开", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("权限") {
                permissionRow("屏幕录制", granted: screenOK, note: "截图必需，授权后需重新打开 MiniShot") {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
                permissionRow("辅助功能", granted: accessibilityOK, note: "仅长截图的自动滚动需要") {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(refresh) { _ in
            screenOK = Permissions.screenRecording
            accessibilityOK = Permissions.accessibility
        }
    }

    private func permissionRow(_ title: String, granted: Bool, note: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("去授权", action: action)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectoryURL
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
