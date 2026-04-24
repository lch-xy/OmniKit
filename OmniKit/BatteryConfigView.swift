//
//  BatteryConfigView.swift
//  OmniKit
//

import SwiftUI

struct BatteryConfigView: View {
    @EnvironmentObject private var batteryManager: BatteryManager

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "电池",
                subtitle: "监控当前电池状态，设置最大充电百分比，并在超过阈值时给出明确提示。"
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "battery.100percent")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                    Text(batteryManager.currentChargeText)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                }
            }

            SettingsSection(title: "充电上限") {
                SettingsRow("启用充电上限", systemImage: "bolt.badge.clock", description: "开启后会自动把目标电量下发给后端；关闭后恢复系统默认充电") {
                    Toggle("", isOn: $batteryManager.isLimitEnabled)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow("最大充电百分比", systemImage: "battery.75", description: "当前目标 \(batteryManager.maximumChargePercent)% ，修改后会自动尝试应用（范围 \(BatteryManager.minimumLimitPercent)–\(BatteryManager.maximumLimitPercent)%）") {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { Double(batteryManager.maximumChargePercent) },
                                set: { batteryManager.maximumChargePercent = Int($0.rounded()) }
                            ),
                            in: Double(BatteryManager.minimumLimitPercent)...Double(BatteryManager.maximumLimitPercent),
                            step: 1
                        )
                        .frame(width: 220)
                        .disabled(!batteryManager.isLimitEnabled)

                        Text("\(batteryManager.maximumChargePercent)%")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            SettingsSection(title: "当前状态") {
                SettingsRow("电池电量", systemImage: "battery.100percent", description: batteryManager.statusMessage) {
                    SettingsInfoBadge(text: batteryManager.currentChargeText, tint: statusTint)
                }

                SettingsDivider()

                SettingsRow("供电状态", systemImage: "powerplug", description: "当前设备所处的供电来源") {
                    Text(batteryManager.powerSourceText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("充电状态", systemImage: "bolt.circle", description: "是否正在向电池写入电量") {
                    Text(batteryManager.chargingStateText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("电池健康", systemImage: "heart.text.square", description: "设计容量衰减和健康条件") {
                    Text(batteryManager.healthSummaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("循环次数", systemImage: "arrow.triangle.2.circlepath", description: "来自系统电池控制器的统计值") {
                    Text(batteryManager.cycleCountText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("立即刷新", systemImage: "arrow.clockwise", description: "手动重新读取一次电池状态") {
                    Button("刷新状态") {
                        batteryManager.refreshBatteryState()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsSection(title: "控制后端") {
                SettingsRow("后端状态", systemImage: "gearshape.2", description: batteryManager.chargeBackendDetail) {
                    SettingsInfoBadge(text: batteryManager.chargeBackendTitle, tint: backendTint)
                }

                SettingsDivider()

                SettingsRow("已应用限制", systemImage: "battery.25", description: batteryManager.chargeBackendActionMessage) {
                    Text(batteryManager.appliedChargeLimitText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("应用设置", systemImage: "checkmark.circle", description: "将当前页面的最大充电百分比下发给可用后端") {
                    HStack(spacing: 8) {
                        if batteryManager.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("应用充电上限") {
                            batteryManager.applyConfiguredChargeLimit()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!batteryManager.canApplyChargeLimit || batteryManager.isBusy)
                    }
                }

                SettingsDivider()

                SettingsRow("重新检测", systemImage: "arrow.triangle.2.circlepath", description: "重新读取可用后端和当前已应用限制") {
                    Button("检测后端") {
                        batteryManager.refreshChargeBackend()
                    }
                    .buttonStyle(.bordered)
                }

                if !batteryManager.suggestedCommand.isEmpty {
                    SettingsDivider()

                    SettingsRow("命令参考", systemImage: "terminal", description: "当前环境下建议的手动命令") {
                        Text(batteryManager.suggestedCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            SettingsSection(title: "能力说明") {
                SettingsRow("硬件停充", systemImage: "exclamationmark.triangle", description: batteryManager.capabilityMessage) {
                    SettingsInfoBadge(text: batteryManager.canApplyChargeLimit ? "可尝试" : "受限", tint: batteryManager.canApplyChargeLimit ? .blue : .orange)
                }
            }
        }
    }

    private var statusTint: Color {
        switch batteryManager.statusBadgeText {
        case "超出上限":
            return .red
        case "已超阈值":
            return .orange
        case "监控中":
            return .blue
        case "正常":
            return .secondary
        default:
            return .secondary
        }
    }

    private var backendTint: Color {
        batteryManager.canApplyChargeLimit ? .blue : .orange
    }
}
