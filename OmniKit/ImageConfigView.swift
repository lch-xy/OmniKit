//
//  ImageConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct ImageConfigView: View {
    @EnvironmentObject private var imageSettings: ImageSettingsStore
    @EnvironmentObject private var imagePanelManager: ImagePanelManager
    @State private var isRecordingShortcut = false
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "图片",
                subtitle: "通过全局快捷键呼出图片工具弹窗，支持压缩、格式转换和翻转。"
            ) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "快捷键配置") {
                SettingsRow("图片工具", systemImage: "keyboard", description: "按下后显示图片处理弹窗") {
                    Button {
                        beginRecordingShortcut()
                    } label: {
                        Text(isRecordingShortcut ? "请按下按键..." : imageSettings.imageShortcut.displayName)
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

            SettingsSection(title: "快速操作") {
                SettingsRow("立即打开", systemImage: "sparkles") {
                    Button("打开图片工具弹窗") {
                        imagePanelManager.togglePanel()
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
        imagePanelManager.suspendShortcut()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                guard let shortcut = ShortcutCombination.from(event: event), isRecordingShortcut else {
                    return event
                }
                imageSettings.imageShortcut = shortcut
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
        imagePanelManager.updateShortcut()
    }
}
