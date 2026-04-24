//
//  TranslationConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct TranslationConfigView: View {
    private enum RecordingTarget {
        case input
        case selection
    }

    @EnvironmentObject private var translationSettings: TranslationSettingsStore
    @EnvironmentObject private var translatorPanelManager: TranslatorPanelManager
    @State private var draftAccessKeyId = ""
    @State private var draftAccessKeySecret = ""
    @State private var saveMessage = ""
    @State private var testMessage = ""
    @State private var isTesting = false
    @State private var recordingTarget: RecordingTarget?
    @State private var keyCaptureMonitor: Any?
    private let service = AlibabaTranslationService()

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "翻译",
                subtitle: "配置阿里云翻译服务与快捷键。完成后可通过系统级浮窗快速发起输入翻译或划词翻译。"
            ) {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "云服务配置") {
                SettingsRow("AccessKey ID", systemImage: "key", description: "阿里云账户的访问密钥 ID") {
                    TextField("必填", text: $draftAccessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                
                SettingsDivider()
                
                SettingsRow("AccessKey Secret", systemImage: "lock", description: "对应的私有访问密钥") {
                    SecureField("必填", text: $draftAccessKeySecret)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                
                SettingsDivider()
                
                SettingsRow("保存配置", systemImage: "tray.and.arrow.down") {
                    HStack {
                        if !saveMessage.isEmpty {
                            SettingsInfoBadge(text: saveMessage, tint: .green)
                        }
                        Button("保存") {
                            translationSettings.accessKeyId = draftAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
                            translationSettings.accessKeySecret = draftAccessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
                            saveMessage = "已保存"
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            SettingsSection(title: "接口偏好") {
                SettingsRow("API 版本", systemImage: "number") {
                    Picker("", selection: $translationSettings.apiVersion) {
                        ForEach(TranslationAPIVersion.allCases) { version in
                            Text(version.title).tag(version)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                
                SettingsDivider()
                
                SettingsRow("文本格式", systemImage: "textformat") {
                    Picker("", selection: $translationSettings.formatType) {
                        ForEach(TranslationFormatType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
            }

            SettingsSection(title: "快捷键") {
                SettingsRow("输入翻译", systemImage: "keyboard", description: "弹出输入框进行手动翻译") {
                    shortcutButton(for: .input, shortcut: translationSettings.inputTranslationShortcut)
                }
                
                SettingsDivider()
                
                SettingsRow("划词翻译", systemImage: "selection.pin.in.out", description: "自动复制并翻译选中文本") {
                    shortcutButton(for: .selection, shortcut: translationSettings.selectionTranslationShortcut)
                }
                
                if recordingTarget != nil {
                    SettingsDivider()
                    SettingsRow("录制快捷键", systemImage: "command", description: "按下新的组合键，或按 Esc 取消") {
                        Button("停止录制") {
                            stopRecording()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            SettingsSection(title: "连通性测试") {
                SettingsRow("验证服务", systemImage: "network") {
                    HStack {
                        if !testMessage.isEmpty {
                            SettingsInfoBadge(
                                text: testMessage,
                                tint: testMessage.contains("通过") ? .green : .red
                            )
                        }
                        Button(isTesting ? "测试中..." : "测试连接") {
                            testConnectivity()
                        }
                        .disabled(isTesting)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            draftAccessKeyId = translationSettings.accessKeyId
            draftAccessKeySecret = translationSettings.accessKeySecret
        }
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private func shortcutButton(for target: RecordingTarget, shortcut: ShortcutCombination) -> some View {
        Button {
            beginRecording(target)
        } label: {
            Text(recordingTarget == target ? "请按下按键..." : shortcut.displayName)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 80)
        }
        .buttonStyle(.bordered)
        .tint(recordingTarget == target ? .accentColor : .secondary)
    }

    private func testConnectivity() {
        let keyId = draftAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let keySecret = draftAccessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyId.isEmpty, !keySecret.isEmpty else {
            testMessage = "密钥不完整"
            return
        }

        isTesting = true
        testMessage = ""
        Task {
            do {
                _ = try await service.translateToChinese(
                    text: "test",
                    accessKeyId: keyId,
                    accessKeySecret: keySecret,
                    apiVersion: translationSettings.apiVersion.rawValue,
                    formatType: translationSettings.formatType.rawValue
                )
                await MainActor.run {
                    testMessage = "通过"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testMessage = "失败"
                    isTesting = false
                }
            }
        }
    }

    private func beginRecording(_ target: RecordingTarget) {
        stopRecording()
        recordingTarget = target
        translatorPanelManager.suspendShortcuts()
        if keyCaptureMonitor == nil {
            keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                guard let shortcut = ShortcutCombination.from(event: event),
                      let target = recordingTarget else {
                    return event
                }

                switch target {
                case .input:
                    translationSettings.inputTranslationShortcut = shortcut
                case .selection:
                    translationSettings.selectionTranslationShortcut = shortcut
                }
                stopRecording()
                return nil
            }
        }
    }

    private func stopRecording() {
        recordingTarget = nil
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
        translatorPanelManager.updateShortcuts()
    }
}
