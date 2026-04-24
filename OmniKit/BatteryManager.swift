//
//  BatteryManager.swift
//  OmniKit
//

import Combine
import Foundation
import IOKit
import IOKit.ps

private let batteryLimitEnabledDefaultsKey = "battery.limit.enabled"
private let batteryLimitPercentDefaultsKey = "battery.limit.percent"
private let batteryRefreshInterval: TimeInterval = 15
private let batteryMinimumLimitPercent = 30
private let batteryMaximumLimitPercent = 100

struct BatterySnapshot {
    let percentage: Int
    let isOnExternalPower: Bool
    let isCharging: Bool
    let isCharged: Bool
    let isChargeCapable: Bool
    let cycleCount: Int?
    let maximumCapacityPercent: Int?
    let healthCondition: String?
}

@MainActor
final class BatteryManager: ObservableObject {
    static let minimumLimitPercent = batteryMinimumLimitPercent
    static let maximumLimitPercent = batteryMaximumLimitPercent

    @Published var isLimitEnabled: Bool {
        didSet {
            OmniKitStore.shared.set(isLimitEnabled, forKey: batteryLimitEnabledDefaultsKey)
            updateStatusMessage()
            guard !suppressAutoSync else { return }
            scheduleLimitSync()
        }
    }

    @Published var maximumChargePercent: Int {
        didSet {
            let clamped = max(batteryMinimumLimitPercent, min(batteryMaximumLimitPercent, maximumChargePercent))
            if clamped != maximumChargePercent {
                maximumChargePercent = clamped
                return
            }
            OmniKitStore.shared.set(clamped, forKey: batteryLimitPercentDefaultsKey)
            updateStatusMessage()
            guard !suppressAutoSync else { return }
            if isLimitEnabled {
                scheduleLimitSync()
            }
        }
    }

    @Published private(set) var snapshot: BatterySnapshot?
    @Published private(set) var statusMessage = "正在读取电池状态..."
    @Published private(set) var capabilityMessage = "受限：macOS 公共 API 不提供沙箱应用直接控制停充，这一版先做上限监控和状态提示。"
    @Published private(set) var chargeBackendTitle = "检测中..."
    @Published private(set) var chargeBackendDetail = "正在检测可用的电池控充后端。"
    @Published private(set) var appliedChargeLimitText = "--"
    @Published private(set) var chargeBackendActionMessage = "尚未尝试应用充电上限。"
    @Published private(set) var suggestedCommand = ""
    @Published private(set) var canApplyChargeLimit = false
    @Published private(set) var canReadAppliedChargeLimit = false
    @Published private(set) var isBusy = false

    private var refreshTimer: Timer?
    private var chargeBackend: BatteryChargeBackend = .unavailable(reason: "检测中...")
    private var pendingLimitSyncWorkItem: DispatchWorkItem?
    /// 初始化期间读取 UserDefaults 触发 didSet，我们不希望把过去的值又"自动下发"一遍。
    private var suppressAutoSync = true
    private var backendRefreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    init() {
        isLimitEnabled = OmniKitStore.shared.object(forKey: batteryLimitEnabledDefaultsKey) as? Bool ?? false
        let storedLimit = OmniKitStore.shared.object(forKey: batteryLimitPercentDefaultsKey) as? Int ?? 80
        maximumChargePercent = max(batteryMinimumLimitPercent, min(batteryMaximumLimitPercent, storedLimit))

        refreshBatteryState()
        // 启动时只做"检测 + 读取"，不主动下发命令，避免在后端需要管理员权限时弹密码框。
        refreshChargeBackend()
        startMonitoring()

        // 初始化结束后恢复自动同步，且如果用户之前就启用了限制，补一次下发。
        suppressAutoSync = false
        if isLimitEnabled {
            scheduleLimitSync()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        pendingLimitSyncWorkItem?.cancel()
        backendRefreshTask?.cancel()
        commandTask?.cancel()
    }

    func refreshBatteryState() {
        snapshot = loadBatterySnapshot()
        updateStatusMessage()
    }

    func refreshChargeBackend() {
        backendRefreshTask?.cancel()
        backendRefreshTask = Task { [weak self] in
            let backend = await Task.detached(priority: .userInitiated) {
                BatteryChargeController.detectBackend()
            }.value

            guard let self else { return }
            await MainActor.run {
                self.applyDetected(backend: backend)
            }

            let readResult: BatteryChargeControlResult? = backend.canRead
                ? await Task.detached(priority: .userInitiated) {
                    BatteryChargeController.readCurrentLimit(using: backend)
                }.value
                : nil

            await MainActor.run {
                self.applyRead(result: readResult, for: backend)
            }
        }
    }

    func applyConfiguredChargeLimit() {
        runBackendCommand(description: "应用充电上限") { [chargeBackend, maximumChargePercent] in
            BatteryChargeController.apply(limit: maximumChargePercent, using: chargeBackend)
        } onSuccess: { [weak self] in
            self?.refreshChargeBackend()
        }
    }

    func disableConfiguredChargeLimit() {
        runBackendCommand(description: "关闭充电上限") { [chargeBackend] in
            BatteryChargeController.disable(using: chargeBackend)
        } onSuccess: { [weak self] in
            self?.refreshChargeBackend()
        }
    }

    var currentChargeText: String {
        guard let snapshot else { return "--" }
        return "\(snapshot.percentage)%"
    }

    var powerSourceText: String {
        guard let snapshot else { return "未知" }
        return snapshot.isOnExternalPower ? "已接电源" : "电池供电"
    }

    var chargingStateText: String {
        guard let snapshot else { return "未知" }
        if snapshot.isCharging {
            return "充电中"
        }
        if snapshot.isCharged {
            return "已充满"
        }
        if snapshot.isOnExternalPower {
            return "接电未充电"
        }
        return "未充电"
    }

    var healthSummaryText: String {
        guard let snapshot else { return "未知" }

        let condition = localizedHealthCondition(snapshot.healthCondition)
        if let maximumCapacityPercent = snapshot.maximumCapacityPercent {
            if let condition {
                return "\(maximumCapacityPercent)% · \(condition)"
            }
            return "\(maximumCapacityPercent)%"
        }
        return condition ?? "未知"
    }

    var cycleCountText: String {
        guard let cycleCount = snapshot?.cycleCount else { return "--" }
        return "\(cycleCount)"
    }

    var statusBadgeText: String {
        guard let snapshot else { return "不可用" }
        if isLimitExceeded(snapshot) {
            return snapshot.isOnExternalPower && snapshot.isCharging ? "超出上限" : "已超阈值"
        }
        if !isLimitEnabled {
            return "未启用"
        }
        if snapshot.isOnExternalPower && snapshot.isCharging {
            return "监控中"
        }
        return "正常"
    }

    // MARK: - Private

    private func startMonitoring() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: batteryRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshBatteryState()
                // 后端重新检测会走后台 Task，不阻塞主线程。
                self.refreshChargeBackend()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func applyDetected(backend: BatteryChargeBackend) {
        chargeBackend = backend
        chargeBackendTitle = backend.title
        chargeBackendDetail = backend.detail
        capabilityMessage = backend.detail
        canApplyChargeLimit = backend.canWrite
        canReadAppliedChargeLimit = backend.canRead
        suggestedCommand = BatteryChargeController.suggestedCommand(for: maximumChargePercent, using: backend) ?? ""

        if !backend.canRead {
            appliedChargeLimitText = "--"
            chargeBackendActionMessage = "当前后端不可读。"
        }
    }

    private func applyRead(result: BatteryChargeControlResult?, for backend: BatteryChargeBackend) {
        guard let result else { return }
        switch result {
        case let .success(value):
            appliedChargeLimitText = value + "%"
            if backend.writeRequiresAdminPrompt {
                chargeBackendActionMessage = "已读取当前后端设置。写入需要管理员权限。"
            } else {
                chargeBackendActionMessage = "已读取当前后端设置。"
            }
        case let .failure(message):
            appliedChargeLimitText = "--"
            chargeBackendActionMessage = message
        }
    }

    private func runBackendCommand(
        description: String,
        operation: @escaping @Sendable () -> BatteryChargeControlResult,
        onSuccess: (() -> Void)? = nil
    ) {
        commandTask?.cancel()
        isBusy = true
        chargeBackendActionMessage = "\(description)中..."

        commandTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated, operation: operation).value
            guard let self else { return }
            await MainActor.run {
                self.isBusy = false
                switch result {
                case let .success(message):
                    self.chargeBackendActionMessage = message
                    onSuccess?()
                case let .failure(message):
                    self.chargeBackendActionMessage = message
                    self.suggestedCommand = BatteryChargeController.suggestedCommand(
                        for: self.maximumChargePercent,
                        using: self.chargeBackend
                    ) ?? ""
                }
                self.updateStatusMessage()
            }
        }
    }

    private func loadBatterySnapshot() -> BatterySnapshot? {
        guard let description = powerSourceDescription() else { return nil }
        let registry = smartBatteryProperties()

        let currentCapacity = intValue(forKeys: ["Current Capacity", "CurrentCapacity"], in: description)
        let maxCapacity = intValue(forKeys: ["Max Capacity", "MaxCapacity"], in: description)
        guard let currentCapacity, let maxCapacity, maxCapacity > 0 else { return nil }

        let percentage = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
        let powerSourceState = stringValue(forKeys: ["Power Source State"], in: description)
        let isOnExternalPower = powerSourceState == "AC Power" || boolValue(forKeys: ["ExternalConnected"], in: description) == true
        let isCharging = boolValue(forKeys: ["Is Charging", "IsCharging"], in: description) ?? false
        let isCharged = boolValue(forKeys: ["Is Charged", "IsCharged"], in: description) ?? false
        let isChargeCapable = boolValue(forKeys: ["ExternalChargeCapable"], in: registry) ?? true
        let cycleCount = intValue(forKeys: ["CycleCount", "Cycle Count"], in: registry)
        let healthCondition = stringValue(forKeys: ["BatteryHealthCondition", "Condition"], in: description) ??
            stringValue(forKeys: ["BatteryHealthCondition", "Condition"], in: registry)
        let maximumCapacityPercent = computedMaximumCapacityPercent(from: registry)

        return BatterySnapshot(
            percentage: percentage,
            isOnExternalPower: isOnExternalPower,
            isCharging: isCharging,
            isCharged: isCharged,
            isChargeCapable: isChargeCapable,
            cycleCount: cycleCount,
            maximumCapacityPercent: maximumCapacityPercent,
            healthCondition: healthCondition
        )
    }

    private func updateStatusMessage() {
        guard let snapshot else {
            statusMessage = "当前设备没有可读的内置电池信息。"
            return
        }

        let backendCanControl = chargeBackend.canWrite

        guard isLimitEnabled else {
            if backendCanControl {
                statusMessage = "已读取到电池状态。当前充电上限已关闭，系统会按默认方式充电。"
            } else {
                statusMessage = "已读取到电池状态。当前充电上限未启用。"
            }
            return
        }

        let limit = maximumChargePercent
        if isLimitExceeded(snapshot) {
            if !backendCanControl {
                statusMessage = "当前电量 \(snapshot.percentage)% 已超过上限 \(limit)% ，但这台机器当前还没有接入可写控充后端，所以设置的上限现在不会真正生效。"
            } else if snapshot.isOnExternalPower && snapshot.isCharging {
                statusMessage = "当前电量 \(snapshot.percentage)% 已超过上限 \(limit)% ，系统还在充电；请检查 batt/bclm 后端是否真的写入成功。"
            } else if snapshot.isOnExternalPower {
                statusMessage = "当前电量 \(snapshot.percentage)% 已高于上限 \(limit)% 。这时正常行为不是立刻掉回 \(limit)% ，而是停止继续充电，等你继续使用后自然回落。"
            } else {
                statusMessage = "当前电量 \(snapshot.percentage)% 已超过上限 \(limit)% ，但设备目前未接电源。"
            }
            return
        }

        if snapshot.isOnExternalPower && snapshot.isCharging {
            if backendCanControl {
                statusMessage = "当前电量 \(snapshot.percentage)% ，正在充电。达到 \(limit)% 后后端会尝试停止继续充电。"
            } else {
                statusMessage = "当前电量 \(snapshot.percentage)% ，正在充电。但当前机器没有可写控充后端，所以这个 \(limit)% 目标值还不会真正拦住充电。"
            }
        } else if snapshot.isOnExternalPower {
            statusMessage = "当前电量 \(snapshot.percentage)% ，已接电源但未充电。"
        } else {
            statusMessage = "当前电量 \(snapshot.percentage)% ，设备正在使用电池供电。"
        }
    }

    private func isLimitExceeded(_ snapshot: BatterySnapshot) -> Bool {
        snapshot.percentage > maximumChargePercent
    }

    private func scheduleLimitSync() {
        pendingLimitSyncWorkItem?.cancel()
        guard chargeBackend.canWrite else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.syncConfiguredLimitToBackend()
            }
        }
        pendingLimitSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func syncConfiguredLimitToBackend() {
        guard chargeBackend.canWrite else { return }
        if isLimitEnabled {
            applyConfiguredChargeLimit()
        } else {
            disableConfiguredChargeLimit()
        }
    }

    private func powerSourceDescription() -> [String: Any]? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array

        for source in list {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source as CFTypeRef),
                  let description = unmanagedDescription.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let isPresent = boolValue(forKeys: ["Is Present", "BatteryInstalled"], in: description) ?? true
            if isPresent {
                return description
            }
        }

        return nil
    }

    private func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    private func computedMaximumCapacityPercent(from dictionary: [String: Any]?) -> Int? {
        guard let dictionary else { return nil }

        if let maximumCapacityPercent = intValue(forKeys: ["MaximumCapacityPercent"], in: dictionary) {
            return maximumCapacityPercent
        }

        guard let rawMaxCapacity = intValue(forKeys: ["AppleRawMaxCapacity"], in: dictionary),
              let designCapacity = intValue(forKeys: ["DesignCapacity"], in: dictionary),
              designCapacity > 0 else {
            return nil
        }

        return Int((Double(rawMaxCapacity) / Double(designCapacity) * 100).rounded())
    }

    private func intValue(forKeys keys: [String], in dictionary: [String: Any]?) -> Int? {
        guard let dictionary else { return nil }

        for key in keys {
            if let value = dictionary[key] as? Int {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.intValue
            }
        }

        return nil
    }

    private func boolValue(forKeys keys: [String], in dictionary: [String: Any]?) -> Bool? {
        guard let dictionary else { return nil }

        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
        }

        return nil
    }

    private func stringValue(forKeys keys: [String], in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }

        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        return nil
    }

    private func localizedHealthCondition(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        switch rawValue.lowercased() {
        case "good", "normal":
            return "正常"
        case "fair":
            return "一般"
        case "poor":
            return "较差"
        default:
            return rawValue
        }
    }
}
