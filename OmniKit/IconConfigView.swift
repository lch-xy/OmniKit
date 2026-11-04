//
//  IconConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI

struct IconConfigView: View {
    @EnvironmentObject private var menuBarIconManager: MenuBarIconManager
    @EnvironmentObject private var menuBarFolder: MenuBarFolderController

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "图标",
                subtitle: "仅折叠标记收纳的第三方图标，未标记图标保持显示。OmniKit 会自动排列图标，新程序启动后也会重新核验分组。系统自带图标请前往「系统设置 › 控制中心」调整。"
            ) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "折叠已收纳图标（不退出 App）") {
                SettingsRow(
                    "启用折叠功能",
                    systemImage: "rectangle.compress.vertical",
                    description: "显示折叠按钮，按收纳名单自动排列并折叠图标，应用继续运行。"
                ) {
                    Toggle("", isOn: Binding(
                        get: { menuBarFolder.isEnabled },
                        set: { menuBarFolder.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(
                    "当前状态",
                    systemImage: menuBarFolder.isCollapsed ? "chevron.right.2" : "chevron.left.2",
                    description: menuBarFolder.isEnabled ? menuBarFolder.statusMessage : "折叠功能未启用。"
                ) {
                    Button(menuBarFolder.isArranging ? "排列中…" : (menuBarFolder.isCollapsed ? "展开" : "折叠已收纳")) {
                        menuBarFolder.toggleCollapsed()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!menuBarFolder.isEnabled || menuBarFolder.isArranging)
                }

                SettingsDivider()

                if menuBarFolder.needsAccessibility || menuBarFolder.needsScreenRecording {
                    SettingsRow(
                        "自动排列权限",
                        systemImage: "hand.raised",
                        description: "辅助功能用于移动图标，屏幕录制权限用于读取图标名称。授权后如系统提示，请重新打开 OmniKit。"
                    ) {
                        HStack(spacing: 8) {
                            if menuBarFolder.needsAccessibility {
                                Button("授权辅助功能") { menuBarFolder.requestAccessibilityPermission() }
                            }
                            if menuBarFolder.needsScreenRecording {
                                Button("授权屏幕录制") { menuBarFolder.requestScreenRecordingPermission() }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    SettingsDivider()
                }

                SettingsRow(
                    "已标记收纳",
                    systemImage: "tray.full",
                    description: "标记后会自动归入折叠组；取消标记会恢复显示。无法确认身份的图标保持显示。"
                ) {
                    SettingsInfoBadge(text: "\(menuBarIconManager.stashedItemsCount) 个", tint: .blue)
                }

                SettingsDivider()

                SettingsRow(
                    "使用说明",
                    systemImage: "lightbulb",
                    description: nil
                ) {
                    EmptyView()
                }

                FolderUsageInstructions()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            SettingsSection(title: "第三方应用图标") {
                let owners = menuBarIconManager.thirdPartyOwners
                if owners.isEmpty {
                    SettingsRow(
                        "暂无可控制的第三方图标",
                        systemImage: "app.dashed",
                        description: menuBarFolder.needsScreenRecording
                            ? "请先授予屏幕录制权限，再刷新实际的菜单栏图标。"
                            : "没有读取到第三方菜单栏图标。启动带菜单栏图标的 App 后点击「刷新状态」。"
                    ) {
                        SettingsInfoBadge(text: "空", tint: .orange)
                    }
                } else {
                    ForEach(Array(owners.enumerated()), id: \.element.id) { ownerIndex, owner in
                        let items = owner.items
                        ForEach(Array(items.enumerated()), id: \.element.id) { itemIndex, item in
                            ThirdPartyStatusItemRow(
                                owner: owner,
                                item: item,
                                isApplying: menuBarIconManager.isApplying,
                                isStashed: menuBarIconManager.isStashed(item),
                                toggle: { isHidden in
                                    menuBarIconManager.setVisibility(!isHidden, for: item)
                                },
                                toggleStashed: { isStashed in
                                    menuBarIconManager.setStashed(isStashed, for: item)
                                }
                            )

                            if !(ownerIndex == owners.count - 1 && itemIndex == items.count - 1) {
                                SettingsDivider()
                            }
                        }
                    }
                }
            }

            SettingsSection(title: "当前状态") {
                SettingsRow("状态", systemImage: "info.circle", description: menuBarIconManager.statusMessage) {
                    SettingsInfoBadge(
                        text: menuBarIconManager.isApplying ? "应用中" : "就绪",
                        tint: menuBarIconManager.isApplying ? .orange : .blue
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "已读取图标",
                    systemImage: "list.bullet.rectangle",
                    description: "当前扫描到的第三方菜单栏图标总数（含运行时项与持久偏好项）"
                ) {
                    SettingsInfoBadge(text: "\(menuBarIconManager.thirdPartyOwners.flatMap { $0.items }.count) 个")
                }

                SettingsDivider()

                SettingsRow("重新读取", systemImage: "arrow.clockwise", description: "重新扫描当前运行的菜单栏 App 和偏好设置里的状态栏图标") {
                    Button("刷新状态") {
                        menuBarIconManager.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(menuBarIconManager.isApplying)
                }
            }
        }
    }
}

private struct FolderUsageInstructions: View {
    private let steps: [(String, String)] = [
        ("1", "启用折叠功能，并授予辅助功能和屏幕录制权限。"),
        ("2", "在下方标记要收纳的图标。若同一应用有多个图标，可以分别选择。"),
        ("3", "点击折叠按钮后，OmniKit 自动排列并核验，只折叠已标记图标。"),
        ("4", "新图标出现时会自动重新排列，期间可能短暂展开；排列失败时保持展开并提示原因。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps, id: \.0) { step in
                HStack(alignment: .top, spacing: 8) {
                    Text(step.0)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor.opacity(0.85)))
                    Text(step.1)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ThirdPartyStatusItemRow: View {
    let owner: ThirdPartyStatusOwner
    let item: ThirdPartyStatusItem
    let isApplying: Bool
    let isStashed: Bool
    let toggle: (Bool) -> Void
    let toggleStashed: (Bool) -> Void

    var body: some View {
        SettingsRow(
            label,
            description: descriptionText
        ) {
            control
        }
        .overlay(alignment: .leading) {
            if let image = appIcon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .padding(.leading, 15)
            }
        }
    }

    private var label: String {
        switch item.control {
        case .persistent:
            return "\(owner.displayName) · \(item.title)"
        case .runtimeOnly:
            return owner.items.count > 1 ? "\(owner.displayName) · \(item.title)" : owner.displayName
        }
    }

    private var descriptionText: String {
        let stashSuffix = isStashed ? "当前已标记收纳。" : "当前未标记收纳。"
        switch item.control {
        case .persistent:
            return "\(item.summary)\(stashSuffix)"
        case .runtimeOnly:
            return "\(item.summary)\(stashSuffix)"
        }
    }

    @ViewBuilder
    private var control: some View {
        HStack(spacing: 8) {
            stashToggle

            switch item.control {
            case .persistent:
                Toggle(
                    "隐藏",
                    isOn: Binding(
                        get: { !item.isVisible },
                        set: { toggle($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isApplying)

            case .runtimeOnly:
                SettingsInfoBadge(text: owner.isRunning ? "运行中" : "已退出", tint: owner.isRunning ? .green : .secondary)
            }
        }
    }

    private var stashToggle: some View {
        Toggle(
            "标记收纳",
            isOn: Binding(
                get: { isStashed },
                set: { toggleStashed($0) }
            )
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isApplying)
    }

    private var appIcon: NSImage? {
        if let path = item.ownerAppPath {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        return nil
    }
}
