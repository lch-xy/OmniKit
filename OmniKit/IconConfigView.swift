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
                subtitle: "管理菜单栏里的第三方 App 图标。启用「折叠菜单栏图标」后，OmniKit 会在菜单栏里注入 chevron + 分隔符两个图标。你可以在下方先把图标「标记收纳」；对大多数运行时图标，只需按住 ⌘ 手动摆到分隔符左侧一次，之后就能长期记住并直接点折叠。少数写入了 NSStatusItem 持久化开关的 App 还支持直接真隐藏。系统自带图标请前往「系统设置 › 控制中心」调整。"
            ) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }

            SettingsSection(title: "折叠已收纳图标（不退出 App）") {
                SettingsRow(
                    "启用折叠功能",
                    systemImage: "rectangle.compress.vertical",
                    description: "在菜单栏里额外显示 OmniKit 的 chevron 按钮和一个透明分隔符。关闭后这两个图标会被移除。"
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
                    description: menuBarFolder.isEnabled
                        ? (menuBarFolder.isCollapsed ? "已折叠：位于分隔符左侧的已收纳图标会被挤出可视区。" : "已展开：所有图标可见。")
                        : "折叠功能未启用。"
                ) {
                    Button(menuBarFolder.isCollapsed ? "展开" : "折叠已收纳") {
                        menuBarFolder.toggleCollapsed()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!menuBarFolder.isEnabled)
                }

                SettingsDivider()

                SettingsRow(
                    "已标记收纳",
                    systemImage: "tray.full",
                    description: "运行时图标首次仍需按住 ⌘ 摆到分隔符左侧一次；之后 OmniKit 会记住它属于折叠组。"
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
                        description: "没有扫描到当前运行的菜单栏常驻 App，也没有 App 在偏好设置里写入 NSStatusItem 可见性。启动一些带状态栏图标的 App 后再点击右下角「刷新状态」。"
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
        ("1", "启用上方的「启用折叠功能」开关。OmniKit 会在菜单栏右侧放置一个 chevron 按钮和一个透明分隔符。"),
        ("2", "在下方「第三方应用图标」里，把你想长期隐藏的条目标记为「收纳」。这里的作用是记住名单，不会自动搬动第三方图标。"),
        ("3", "对于大多数运行时图标，首次仍需按住 ⌘ 键把它拖到分隔符左侧一次；之后布局会保留，不需要每次都重新摆放。"),
        ("4", "点击 chevron：分隔符左侧的已收纳图标会被挤出可视区实现折叠；再点一次即恢复。期间对应 App 始终在运行。")
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
            return owner.displayName
        }
    }

    private var descriptionText: String {
        let stashSuffix = isStashed ? "当前已标记收纳。" : "当前未标记收纳。"
        switch item.control {
        case .persistent:
            return "\(item.summary)\(stashSuffix)"
        case .runtimeOnly:
            return "\(item.summary)\(stashSuffix) 首次需要手动摆到分隔符左侧一次。"
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
