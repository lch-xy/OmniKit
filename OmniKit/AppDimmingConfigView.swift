//
//  AppDimmingConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppDimmingConfigView: View {
    @EnvironmentObject private var appDimmingManager: AppDimmingManager
    @State private var selectionMessage = ""

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "软件淡化",
                subtitle: appDimmingManager.effect == .dimming
                    ? "为选定软件的窗口添加白色遮罩，文字和图片会一起变淡，也会同时降低自己与旁人的可读性。仅支持普通桌面窗口，不支持全屏。"
                    : "透明效果会实时显示窗口后方画面，需要屏幕录制权限。仅支持单屏普通窗口，不支持全屏；重叠窗口可能显示不准确。"
            ) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "淡化设置") {
                SettingsRow("显示效果", systemImage: "circle.lefthalf.filled", description: "淡化使用白色遮罩；透明显示后方画面。") {
                    Picker("显示效果", selection: $appDimmingManager.effect) {
                        ForEach(AppDisplayEffect.allCases) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow("启用软件淡化", systemImage: "circle.lefthalf.filled", description: "关闭后立即移除所有遮罩，保留软件设置。") {
                    Toggle("启用软件淡化", isOn: $appDimmingManager.isEnabled)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow("选择软件", systemImage: "plus.app", description: selectionMessage.isEmpty ? "选择应用程序，可为多个软件分别设置淡化强度。" : selectionMessage) {
                    Button("添加软件") { selectApplication() }
                        .buttonStyle(OmniKitButtonStyle(prominent: true))
                }
                if appDimmingManager.effect == .transparency && (appDimmingManager.needsScreenRecording || !appDimmingManager.transparencyStatus.isEmpty) {
                    SettingsDivider()
                    SettingsRow("屏幕录制权限", systemImage: "record.circle", description: appDimmingManager.needsScreenRecording ? "需要屏幕录制权限；授权后请重新检查，如系统提示请重启 OmniKit。" : appDimmingManager.transparencyStatus) {
                        HStack {
                            if appDimmingManager.needsScreenRecording {
                                Button("授权屏幕录制") { appDimmingManager.requestScreenRecordingPermission() }
                            }
                            Button("重新检查") { appDimmingManager.checkScreenRecordingPermission() }
                        }
                        .buttonStyle(OmniKitButtonStyle())
                    }
                }
            }

            SettingsSection(title: "已选软件") {
                if appDimmingManager.rules.isEmpty {
                    SettingsRow("尚未选择软件", systemImage: "app.dashed", description: "添加软件后可调整其淡化强度。") { EmptyView() }
                } else {
                    ForEach(Array(appDimmingManager.rules.enumerated()), id: \.element.id) { index, rule in
                        SettingsRow(rule.name, systemImage: "app", description: appDimmingManager.effect == .dimming ? "0% 不淡化，100% 完全遮挡。" : "0% 不透明，100% 完全透出后方画面。") {
                            HStack(spacing: 10) {
                                Slider(value: Binding(
                                    get: { Double(rule.strength) },
                                    set: { appDimmingManager.setStrength(Int($0.rounded()), for: rule.bundleID) }
                                ), in: 0...100, step: 1)
                                .frame(width: 180)
                                .accessibilityLabel("\(rule.name)淡化强度")
                                .disabled(!appDimmingManager.isEnabled)
                                Text("\(rule.strength)%")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 40, alignment: .trailing)
                                Button("移除") { appDimmingManager.removeApplication(rule.bundleID) }
                                    .accessibilityLabel("移除\(rule.name)")
                                    .buttonStyle(OmniKitButtonStyle())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        if index < appDimmingManager.rules.count - 1 { SettingsDivider() }
                    }
                }
            }
        }
    }

    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要淡化的软件"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectionMessage = appDimmingManager.addApplication(at: url) ? "已添加软件。" : "无法添加：该软件已添加或不支持。"
    }
}
