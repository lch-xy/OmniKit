//
//  MenuBarIconManager.swift
//  OmniKit
//
//  只负责扫描和控制"第三方 App 注册到菜单栏的状态栏图标"。
//
//  发现路径有两条，互补：
//  1) 偏好扫描：~/Library/Preferences(ByHost) 下带 `NSStatusItem Visible X` 的 plist。
//     这要求 App 使用了 `NSStatusItem.autosaveName`，AppKit 才会把可见性写回 plist。
//     实际绝大多数 App 没开这个，所以这条路径命中率不高（常见的只有钉钉、1Password 等）。
//  2) 运行时扫描：`NSWorkspace.runningApplications` 里 activationPolicy == .accessory
//     的 App 都会在菜单栏里放至少一个状态栏图标，这就是"菜单栏常驻 App"的事实。
//     这类 App 的图标随进程存在 —— macOS 没有公共 API 可以让外部 App 隐藏它，
//     OmniKit 也不再提供"退出 App 来隐藏图标"的选项。如需真正隐藏而不退出进程，
//     请使用 `MenuBarFolderController` 提供的 Hidden Bar 风格折叠功能。
//

import AppKit
import Combine
import Foundation

// MARK: - Models

enum ThirdPartyItemControl: Hashable, Sendable {
    /// App 在偏好里存了 `NSStatusItem Visible X`，可以通过 Bool 持久开关控制。
    case persistent(isVisible: Bool)
    /// 没有持久化开关，图标靠进程存在。OmniKit 不再直接控制这类图标，仅作信息展示。
    case runtimeOnly
}

struct ThirdPartyStatusItem: Identifiable, Hashable, Sendable {
    let bundleID: String
    let ownerName: String
    let ownerAppPath: String?
    /// 在 `NSStatusItem Visible X` 里的那个 `X`；runtimeOnly 类型使用空字符串。
    let itemKey: String
    let control: ThirdPartyItemControl

    var id: String { bundleID + "#" + (itemKey.isEmpty ? "__runtime__" : itemKey) }

    var title: String {
        switch control {
        case .persistent:
            return itemKey.isEmpty ? ownerName : Self.prettifiedTitle(for: itemKey)
        case .runtimeOnly:
            return "菜单栏图标（运行时）"
        }
    }

    var summary: String {
        switch control {
        case .persistent:
            return "来自 \(ownerName)（\(bundleID)），可通过 NSStatusItem 偏好开关持久隐藏/显示。"
        case .runtimeOnly:
            return "来自 \(ownerName)（\(bundleID)）。macOS 不允许外部 App 直接隐藏它的菜单栏图标；若需仅隐藏图标而不退出进程，请启用上方的「折叠菜单栏图标」功能。"
        }
    }

    var visibilityDefaultsKey: String {
        "NSStatusItem Visible \(itemKey)"
    }

    var isVisible: Bool {
        switch control {
        case .persistent(let visible):
            return visible
        case .runtimeOnly:
            return true
        }
    }

    var supportsPersistentToggle: Bool {
        if case .persistent = control { return true }
        return false
    }

    nonisolated private static func prettifiedTitle(for key: String) -> String {
        key
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "_", with: " ")
    }
}

struct ThirdPartyStatusOwner: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let appURL: URL?
    let isRunning: Bool
    var items: [ThirdPartyStatusItem]

    var id: String { bundleID }
}

// MARK: - Manager

@MainActor
final class MenuBarIconManager: ObservableObject {
    private static let stashedItemsKey = "omnikit.menubarFolder.stashedItems"

    @Published private(set) var thirdPartyOwners: [ThirdPartyStatusOwner] = []
    @Published private(set) var statusMessage = "正在扫描第三方应用的菜单栏图标..."
    @Published private(set) var isApplying = false
    @Published private(set) var stashedItemIDs: Set<String>

    init() {
        self.stashedItemIDs = Set((OmniKitStore.shared.array(forKey: Self.stashedItemsKey) as? [String]) ?? [])
        refresh()
    }

    // MARK: Public API

    /// 仅对 `.persistent` 类型的图标写偏好并重启 App 让改动生效。
    /// `.runtimeOnly` 不再由本 manager 直接隐藏；调用此方法会给出提示并无副作用。
    func setVisibility(_ isVisible: Bool, for item: ThirdPartyStatusItem) {
        isApplying = true
        defer { isApplying = false }

        switch item.control {
        case .persistent:
            statusMessage = "正在\(isVisible ? "恢复显示" : "隐藏") \(item.ownerName) 的 \(item.title)..."
            let ok = writePersistentVisibility(isVisible, for: item)
            if ok {
                let outcome = restartAppIfSafe(bundleID: item.bundleID)
                refresh()
                switch outcome {
                case .notRunning:
                    statusMessage = "\(item.ownerName) · \(item.title) 已写入偏好设置；下次启动该 App 时生效。"
                case .restarted:
                    statusMessage = "\(item.ownerName) · \(item.title) 已\(isVisible ? "恢复显示" : "隐藏")，已重启该 App 使其立即生效。"
                case .skippedGUIApp:
                    statusMessage = "\(item.ownerName) · \(item.title) 已写入偏好设置；该 App 有前台窗口，请手动退出后再打开让改动生效。"
                }
            } else {
                statusMessage = "应用失败：无法写入 \(item.bundleID) 的偏好设置。"
                refresh()
            }

        case .runtimeOnly:
            statusMessage = "\(item.ownerName) 的图标无法被外部 App 直接控制。请启用「折叠菜单栏图标」功能，再按住 ⌘ 拖动该图标到分隔符左侧即可折叠隐藏。"
        }
    }

    func isStashed(_ item: ThirdPartyStatusItem) -> Bool {
        stashedItemIDs.contains(item.id)
    }

    func setStashed(_ isStashed: Bool, for item: ThirdPartyStatusItem) {
        if isStashed {
            stashedItemIDs.insert(item.id)
        } else {
            stashedItemIDs.remove(item.id)
        }
        persistStashedItems()

        switch item.control {
        case .persistent:
            statusMessage = isStashed
                ? "\(item.ownerName) · \(item.title) 已加入收纳组。该条目支持持久可见性开关，可配合上方隐藏开关一起使用。"
                : "\(item.ownerName) · \(item.title) 已移出收纳组。"
        case .runtimeOnly:
            statusMessage = isStashed
                ? "\(item.ownerName) 已加入收纳组。首次仍需按住 ⌘ 把它摆到分隔符左侧，之后可直接点折叠。"
                : "\(item.ownerName) 已移出收纳组。"
        }
    }

    var stashedItemsCount: Int {
        thirdPartyOwners
            .flatMap(\.items)
            .filter { stashedItemIDs.contains($0.id) }
            .count
    }

    func refresh() {
        updateOwnersOnly()
        let total = thirdPartyOwners.flatMap { $0.items }.count
        let persistentCount = thirdPartyOwners.flatMap { $0.items }.filter { $0.supportsPersistentToggle }.count
        let runtimeCount = total - persistentCount
        let stashedCount = stashedItemsCount
        statusMessage = "扫描到 \(thirdPartyOwners.count) 个第三方 App 的菜单栏条目：\(runtimeCount) 个运行时图标、\(persistentCount) 个持久化偏好项，已标记收纳 \(stashedCount) 个。刷新时间 \(Self.refreshTimeFormatter.string(from: Date()))。"
    }

    /// 只刷新 owners 列表，不改 `statusMessage`。
    private func updateOwnersOnly() {
        thirdPartyOwners = discoverThirdPartyOwners()
    }

    // MARK: - Discovery

    private func discoverThirdPartyOwners() -> [ThirdPartyStatusOwner] {
        var ownerMap: [String: ThirdPartyStatusOwner] = [:]
        let workspace = NSWorkspace.shared

        // 1) 偏好扫描 — AnyHost / ByHost 两个目录
        let persistentOwners = scanPersistentOwners(workspace: workspace)
        for owner in persistentOwners {
            ownerMap[owner.bundleID] = owner
        }

        // 2) 运行时扫描 — 所有当前运行的 .accessory 类（菜单栏常驻）App
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let running = workspace.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
            guard bundleID != ownBundleID else { return false }
            guard Self.shouldConsiderThirdPartyDomain(bundleID) else { return false }
            guard app.activationPolicy == .accessory else { return false }
            return true
        }

        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            let (appURL, displayName) = Self.resolveAppIdentity(bundleID: bundleID, fallbackURL: app.bundleURL, fallbackName: app.localizedName, workspace: workspace)

            if var existing = ownerMap[bundleID] {
                existing = ThirdPartyStatusOwner(
                    bundleID: existing.bundleID,
                    displayName: existing.displayName,
                    appURL: existing.appURL ?? appURL,
                    isRunning: true,
                    items: existing.items
                )
                ownerMap[bundleID] = existing
            } else {
                let runtimeItem = ThirdPartyStatusItem(
                    bundleID: bundleID,
                    ownerName: displayName,
                    ownerAppPath: appURL?.path,
                    itemKey: "",
                    control: .runtimeOnly
                )
                ownerMap[bundleID] = ThirdPartyStatusOwner(
                    bundleID: bundleID,
                    displayName: displayName,
                    appURL: appURL,
                    isRunning: true,
                    items: [runtimeItem]
                )
            }
        }

        return ownerMap.values
            .map { owner -> ThirdPartyStatusOwner in
                var copy = owner
                copy.items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return copy
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func scanPersistentOwners(workspace: NSWorkspace) -> [ThirdPartyStatusOwner] {
        guard let home = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first else {
            return []
        }
        let prefsDirs: [URL] = [
            URL(fileURLWithPath: home).appendingPathComponent("Preferences"),
            URL(fileURLWithPath: home).appendingPathComponent("Preferences/ByHost")
        ]

        var ownerMap: [String: ThirdPartyStatusOwner] = [:]

        for dir in prefsDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "plist" {
                let bundleID = Self.bundleIDFromPreferenceFile(file.lastPathComponent)
                guard Self.shouldConsiderThirdPartyDomain(bundleID) else { continue }

                let plist = Self.loadPlist(at: file)
                guard !plist.isEmpty else { continue }

                let itemKeys = plist.keys.compactMap { key -> String? in
                    guard key.hasPrefix("NSStatusItem Visible ") else { return nil }
                    let suffix = String(key.dropFirst("NSStatusItem Visible ".count))
                    guard !suffix.hasPrefix("Item-") else { return nil }
                    return suffix
                }

                guard !itemKeys.isEmpty else { continue }

                let (appURL, displayName) = Self.resolveAppIdentity(bundleID: bundleID, fallbackURL: nil, fallbackName: nil, workspace: workspace)
                let isRunning = workspace.runningApplications.contains { $0.bundleIdentifier == bundleID }

                let newItems = itemKeys.map { itemKey -> ThirdPartyStatusItem in
                    let visible = Self.boolValue(plist["NSStatusItem Visible \(itemKey)"]) ?? false
                    return ThirdPartyStatusItem(
                        bundleID: bundleID,
                        ownerName: displayName,
                        ownerAppPath: appURL?.path,
                        itemKey: itemKey,
                        control: .persistent(isVisible: visible)
                    )
                }

                if var existing = ownerMap[bundleID] {
                    var seen = Set(existing.items.map { $0.itemKey })
                    for item in newItems where !seen.contains(item.itemKey) {
                        existing.items.append(item)
                        seen.insert(item.itemKey)
                    }
                    ownerMap[bundleID] = existing
                } else {
                    ownerMap[bundleID] = ThirdPartyStatusOwner(
                        bundleID: bundleID,
                        displayName: displayName,
                        appURL: appURL,
                        isRunning: isRunning,
                        items: newItems
                    )
                }
            }
        }

        return Array(ownerMap.values)
    }

    // MARK: - Helpers

    /// 从 `~/Library/Preferences/<bundle>.plist` 或 ByHost 下的 `<bundle>.<UUID>.plist` 里取出 bundle ID。
    private static func bundleIDFromPreferenceFile(_ filename: String) -> String {
        var name = filename
        if name.hasSuffix(".plist") {
            name.removeLast(".plist".count)
        }
        if let range = name.range(of: "\\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    private static func shouldConsiderThirdPartyDomain(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if bundleID.hasPrefix("com.apple.") { return false }
        if bundleID.hasPrefix(".") { return false }
        return true
    }

    private static func loadPlist(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String: Any]) ?? [:]
    }

    private static func resolveAppIdentity(bundleID: String, fallbackURL: URL?, fallbackName: String?, workspace: NSWorkspace) -> (URL?, String) {
        let url = workspace.urlForApplication(withBundleIdentifier: bundleID) ?? fallbackURL
        if let url {
            let name = readDisplayName(at: url) ?? fallbackName ?? url.deletingPathExtension().lastPathComponent
            return (url, name)
        }
        return (nil, fallbackName ?? bundleID)
    }

    private static func readDisplayName(at appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        if let localizedName = info["CFBundleDisplayName"] as? String, !localizedName.isEmpty {
            return localizedName
        }
        if let name = info["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    // MARK: - Persistent prefs write

    private func writePersistentVisibility(_ isVisible: Bool, for item: ThirdPartyStatusItem) -> Bool {
        var ok = writeBool(
            domain: item.bundleID,
            key: item.visibilityDefaultsKey,
            value: isVisible,
            currentHost: false
        )
        ok = writeBool(
            domain: item.bundleID,
            key: item.visibilityDefaultsKey,
            value: isVisible,
            currentHost: true
        ) || ok
        return ok
    }

    @discardableResult
    private func writeBool(domain: String, key: String, value: Bool, currentHost: Bool) -> Bool {
        let host = currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList,
            domain as CFString,
            kCFPreferencesCurrentUser,
            host
        )
        return CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            host
        )
    }

    // MARK: - Restart

    private enum RestartOutcome {
        case notRunning
        case restarted
        case skippedGUIApp
    }

    /// 写完持久化偏好后安全地重启目标 App：
    /// - 未运行：只写 prefs，下次启动生效；
    /// - 纯菜单栏 / 后台 App：自动 terminate 并重新 open；
    /// - 前台 GUI App：不自动重启，提示用户手动退出。
    private func restartAppIfSafe(bundleID: String) -> RestartOutcome {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else { return .notRunning }

        let isAllMenuBarOrBackground = running.allSatisfy {
            $0.activationPolicy == .accessory || $0.activationPolicy == .prohibited
        }
        guard isAllMenuBarOrBackground else { return .skippedGUIApp }

        for app in running { app.terminate() }
        Thread.sleep(forTimeInterval: 0.4)

        let stillAlive = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        if stillAlive {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
                app.forceTerminate()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        return .restarted
    }

    private static let refreshTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func persistStashedItems() {
        OmniKitStore.shared.set(Array(stashedItemIDs).sorted(), forKey: Self.stashedItemsKey)
    }
}
