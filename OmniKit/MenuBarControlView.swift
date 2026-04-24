//
//  MenuBarControlView.swift
//  OmniKit
//

import AppKit
import SwiftUI

enum OmniKitSceneID {
    static let mainWindow = "main-window"
}

struct MenuBarControlView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var translatorPanelManager: TranslatorPanelManager
    @EnvironmentObject private var ocrManager: OCRManager
    @EnvironmentObject private var meetingManager: MeetingManager
    @EnvironmentObject private var formatPanelManager: FormatPanelManager
    @EnvironmentObject private var imagePanelManager: ImagePanelManager
    @EnvironmentObject private var clipboardPanelManager: ClipboardPanelManager
    @EnvironmentObject private var batteryManager: BatteryManager

    var body: some View {
        Group {
            Button {
                openMainWindow()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }

            Divider()

            Section("快捷操作") {
                Button {
                    translatorPanelManager.showInputPanel()
                } label: {
                    Label("输入翻译", systemImage: "globe")
                }

                Button {
                    ocrManager.triggerOCR()
                } label: {
                    Label("截图 OCR", systemImage: "text.viewfinder")
                }

                Button {
                    formatPanelManager.presentPanel()
                } label: {
                    Label("格式转换", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }

                Button {
                    imagePanelManager.presentPanel()
                } label: {
                    Label("图片工具", systemImage: "photo.on.rectangle.angled")
                }

                Button {
                    clipboardPanelManager.presentPanel()
                } label: {
                    Label("剪贴板历史", systemImage: "doc.on.clipboard")
                }
            }

            Divider()

            Section("会议") {
                Button {
                    toggleMeetingRecording()
                } label: {
                    Label(
                        meetingManager.isRecording ? "停止录音" : "开始录音",
                        systemImage: meetingManager.isRecording ? "stop.circle" : "record.circle"
                    )
                }

                Button {
                    meetingManager.openRecordingsFolder()
                } label: {
                    Label("打开录音目录", systemImage: "folder")
                }
            }

            Divider()

            Section("状态") {
                LabeledContent("电池") {
                    Text(batteryManager.currentChargeText)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("录音") {
                    Text(meetingManager.isRecording ? "进行中" : "空闲")
                        .foregroundStyle(meetingManager.isRecording ? .red : .secondary)
                }
            }

            Divider()

            Button("退出 OmniKit") {
                NSApp.terminate(nil)
            }
        }
    }

    private func openMainWindow() {
        openWindow(id: OmniKitSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleMeetingRecording() {
        if meetingManager.isRecording {
            meetingManager.stopRecording()
        } else {
            meetingManager.startRecording()
        }
    }
}
