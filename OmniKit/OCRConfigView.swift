//
//  OCRConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct OCRConfigView: View {
    @EnvironmentObject private var ocrSettings: OCRSettingsStore
    @EnvironmentObject private var ocrManager: OCRManager
    @State private var isRecordingShortcut = false
    @State private var keyCaptureMonitor: Any?

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "OCR",
                subtitle: "调用系统截图并使用 Apple Vision 识别文本，适合快速摘取屏幕内容。"
            ) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "快捷键配置") {
                SettingsRow("截图识别", systemImage: "camera.viewfinder", description: "通过全局快捷键进入截图识别流程") {
                    Button {
                        beginRecordingShortcut()
                    } label: {
                        Text(isRecordingShortcut ? "请按下按键..." : ocrSettings.ocrShortcut.displayName)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 80)
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

            SettingsSection(title: "操作与状态") {
                SettingsRow("立即执行", systemImage: "play.circle") {
                    HStack(spacing: 8) {
                        if !ocrManager.lastStatusMessage.isEmpty {
                            SettingsInfoBadge(
                                text: ocrManager.lastStatusMessage,
                                tint: ocrManager.lastStatusMessage.contains("完成") ? .green : .secondary
                            )
                        }
                        
                        Button(ocrManager.isRecognizing ? "识别中..." : "开始截图识别") {
                            ocrManager.triggerOCR()
                        }
                        .disabled(ocrManager.isRecognizing)
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                if !ocrManager.lastRecognizedText.isEmpty {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "doc.text")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Text("最近识别结果")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Text(ocrManager.lastRecognizedText)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
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
        ocrManager.suspendShortcut()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                guard let shortcut = ShortcutCombination.from(event: event), isRecordingShortcut else {
                    return event
                }
                ocrSettings.ocrShortcut = shortcut
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
        ocrManager.updateShortcut()
    }
}
