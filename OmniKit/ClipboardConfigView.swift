//
//  ClipboardConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct ClipboardConfigView: View {
    @EnvironmentObject private var clipboardSettings: ClipboardSettingsStore
    @EnvironmentObject private var clipboardPanelManager: ClipboardPanelManager
    @State private var isRecordingShortcut = false
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "剪贴板",
                subtitle: "自动记录文本、图片和文件复制历史，支持搜索、筛选、固定和快速回贴。"
            ) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "快捷键配置") {
                SettingsRow("剪贴板面板", systemImage: "keyboard", description: "按下后显示剪贴板历史弹窗") {
                    Button {
                        beginRecordingShortcut()
                    } label: {
                        Text(isRecordingShortcut ? "请按下按键..." : clipboardSettings.clipboardShortcut.displayName)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.bordered)
                    .tint(isRecordingShortcut ? .accentColor : .secondary)
                }

                if isRecordingShortcut {
                    SettingsDivider()
                    SettingsRow("录制快捷键", systemImage: "command", description: "按下新的组合键，或按 Esc 取消") {
                        Button("停止录制") {
                            stopRecording()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            SettingsSection(title: "历史状态") {
                SettingsRow("当前记录数", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    Text("\(clipboardPanelManager.totalCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("已固定内容", systemImage: "pin") {
                    Text("\(clipboardPanelManager.pinnedCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "快速操作") {
                SettingsRow("立即打开", systemImage: "sparkles") {
                    Button("打开剪贴板弹窗") {
                        clipboardPanelManager.togglePanel()
                    }
                    .buttonStyle(.borderedProminent)
                }

                SettingsDivider()

                SettingsRow("清空未固定", systemImage: "trash", description: "保留固定内容，仅清理普通历史") {
                    Button("清空") {
                        clipboardPanelManager.clearUnpinnedEntries()
                    }
                    .buttonStyle(.bordered)
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
        clipboardPanelManager.suspendShortcut()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                guard let shortcut = ShortcutCombination.from(event: event), isRecordingShortcut else {
                    return event
                }
                clipboardSettings.clipboardShortcut = shortcut
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
        clipboardPanelManager.updateShortcut()
    }
}
