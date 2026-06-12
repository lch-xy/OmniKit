//
//  TextDiffConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct TextDiffConfigView: View {
    @EnvironmentObject private var textDiffSettings: TextDiffSettingsStore
    @EnvironmentObject private var textDiffPanelManager: TextDiffPanelManager
    @State private var isRecordingShortcut = false
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "文本比对",
                subtitle: "通过全局快捷键呼出比对窗口，左右输入两段文本后快速查看新增、删除和修改行。"
            ) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "快捷键配置") {
                SettingsRow("弹出比对窗口", systemImage: "keyboard", description: "按下后显示文本比对窗口") {
                    Button {
                        beginRecordingShortcut()
                    } label: {
                        Text(isRecordingShortcut ? "请按下按键..." : textDiffSettings.textDiffShortcut.displayName)
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
                    Button("打开文本比对窗口") {
                        textDiffPanelManager.togglePanel()
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
        textDiffPanelManager.suspendShortcut()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }
                guard let shortcut = ShortcutCombination.from(event: event), isRecordingShortcut else {
                    return event
                }
                textDiffSettings.textDiffShortcut = shortcut
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
        textDiffPanelManager.updateShortcut()
    }
}
