//
//  FormatConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct FormatConfigView: View {
    @EnvironmentObject private var formatSettings: FormatSettingsStore
    @EnvironmentObject private var formatPanelManager: FormatPanelManager
    @State private var isRecordingShortcut = false
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "格式转换",
                subtitle: "通过全局快捷键呼出转换弹窗，支持 JSON 提取格式化、随机生成 UUID/身份证号，以及 Base64、MD5、URL、转义和 Unicode 等文本处理。"
            ) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "快捷键配置") {
                SettingsRow("弹出转换框", systemImage: "keyboard", description: "按下后显示格式转换弹窗") {
                    Button {
                        beginRecordingShortcut()
                    } label: {
                        Text(isRecordingShortcut ? "请按下按键..." : formatSettings.formatShortcut.displayName)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.bordered)
                    .tint(isRecordingShortcut ? .accentColor : .secondary)
                }

                if isRecordingShortcut {
                    SettingsDivider()
                    SettingsRow("录制快捷键", systemImage: "command", description: "按下新组合键，或按 Esc 取消") {
                        Button("停止录制") {
                            stopRecording()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            SettingsSection(title: "快速操作") {
                SettingsRow("立即打开", systemImage: "sparkles") {
                    Button("打开格式转换弹窗") {
                        formatPanelManager.togglePanel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func beginRecordingShortcut() {
        stopRecording()
        isRecordingShortcut = true
        formatPanelManager.suspendShortcut()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                guard let shortcut = ShortcutCombination.from(event: event), isRecordingShortcut else {
                    return event
                }
                formatSettings.formatShortcut = shortcut
                stopRecording()
                return nil
            }
        }
    }

    private func stopRecording() {
        isRecordingShortcut = false
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
        formatPanelManager.updateShortcut()
    }
}
