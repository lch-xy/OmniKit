//
//  PreferencesMigrator.swift
//  OmniKit
//
//  把历史版本散落在各处的数据全部收拢到 ~/Library/Application Support/OmniKit/ 下。
//  历史来源：
//    • App Sandbox 时期的   ~/Library/Containers/<bundleID>/.../Preferences/<bundleID>.plist
//    • 非沙盒 UserDefaults: ~/Library/Preferences/<bundleID>.plist
//    • 早期会议录音目录：    ~/Library/Application Support/OmniKit/Meetings/（路径和现在一致，无需搬）
//  迁移成功后会**删除**旧的 ~/Library/Preferences/<bundleID>.plist，以及旧的沙盒容器。
//

import AppKit
import Foundation

enum PreferencesMigrator {

    /// v1：sandbox → UserDefaults；这个阶段完成后旧数据还在 UserDefaults（~/Library/Preferences/）。
    private static let v1DoneKey = "omnikit.migration.sandboxToUser.v1"
    /// v2：UserDefaults → OmniKitStore（~/Library/Application Support/OmniKit/config.plist）。
    private static let v2DoneKey = "omnikit.migration.unifiedDataDir.v2"

    /// 只迁移业务自己写入的、带明确前缀的键。
    private static let businessKeyPrefixes: [String] = [
        "translation.",
        "ocr.",
        "format.",
        "image.",
        "clipboard.",
        "meeting.",
        "battery.",
        "omnikit.",
        "notch."
    ]

    /// 在任何 SettingsStore / Manager 初始化之前调用。幂等。
    static func migrateIfNeeded(bundleID: String = Bundle.main.bundleIdentifier ?? "com.lch.OmniKit") {
        OmniKitDataLocation.ensureDirectoriesExist()

        // 如果 v2 已经做过，什么都不用再动
        if OmniKitStore.shared.bool(forKey: v2DoneKey) {
            return
        }

        // Step 1: 先把沙盒容器里的旧偏好搬到非沙盒 UserDefaults（兼容历史 v1 迁移逻辑）。
        performSandboxContainerMigration(bundleID: bundleID)

        // Step 2: 把 UserDefaults 里所有业务键全部拷贝到 OmniKitStore。
        let migratedFromDefaults = performUserDefaultsToStoreMigration()

        // Step 3: 完成统一迁移后，清理旧的 UserDefaults plist 与沙盒容器遗留。
        OmniKitStore.shared.set(true, forKey: v2DoneKey)
        OmniKitStore.shared.synchronize()
        cleanupLegacyLocations(bundleID: bundleID)

        if migratedFromDefaults > 0 {
            NSLog("[OmniKit] PreferencesMigrator v2: migrated \(migratedFromDefaults) keys into unified data dir at \(OmniKitDataLocation.rootDirectory.path).")
        }
    }

    // MARK: - v1：沙盒容器 → UserDefaults（保留老逻辑）

    private static func performSandboxContainerMigration(bundleID: String) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: v1DoneKey) {
            return
        }
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            defaults.set(true, forKey: v1DoneKey)
            return
        }

        let candidatePaths: [URL] = [
            libraryURL
                .appendingPathComponent("Containers")
                .appendingPathComponent(bundleID)
                .appendingPathComponent("Data/Library/Preferences")
                .appendingPathComponent("\(bundleID).plist"),
            libraryURL
                .appendingPathComponent("Group Containers")
                .appendingPathComponent(bundleID)
                .appendingPathComponent("Library/Preferences")
                .appendingPathComponent("\(bundleID).plist")
        ]

        for url in candidatePaths {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }
            for (key, value) in plist where shouldMigrate(key: key) {
                if defaults.object(forKey: key) != nil { continue }
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: v1DoneKey)
        defaults.synchronize()
    }

    // MARK: - v2：UserDefaults → OmniKitStore

    private static func performUserDefaultsToStoreMigration() -> Int {
        let defaults = UserDefaults.standard
        let all = defaults.dictionaryRepresentation()
        var payload: [String: Any] = [:]
        for (key, value) in all where shouldMigrate(key: key) {
            payload[key] = value
        }
        if payload.isEmpty { return 0 }
        OmniKitStore.shared.importIfAbsent(payload)
        return payload.count
    }

    // MARK: - 清理

    private static func cleanupLegacyLocations(bundleID: String) {
        let defaults = UserDefaults.standard

        // 1) 把业务键从 UserDefaults 中移除（完成状态标记可以连带一起清掉）
        let all = defaults.dictionaryRepresentation()
        for key in all.keys where shouldMigrate(key: key) {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        // 2) 彻底删除 ~/Library/Preferences/<bundleID>.plist / ByHost 变体
        //    注意：UserDefaults 的 plist 由 cfprefsd 管控，直接删有可能被进程重建；
        //    所以先把文件清空（上面 removeObject 已搞定内容），再强制从磁盘删一次。
        let fm = FileManager.default
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }

        let plistCandidates: [URL] = [
            libraryURL.appendingPathComponent("Preferences/\(bundleID).plist"),
        ] + listByHostPlists(in: libraryURL, bundleID: bundleID)

        for url in plistCandidates where fm.fileExists(atPath: url.path) {
            _ = try? fm.removeItem(at: url)
        }

        // 3) 沙盒容器
        let containerDirs: [URL] = [
            libraryURL.appendingPathComponent("Containers").appendingPathComponent(bundleID),
            libraryURL.appendingPathComponent("Group Containers").appendingPathComponent(bundleID)
        ]
        for dir in containerDirs where fm.fileExists(atPath: dir.path) {
            _ = try? fm.removeItem(at: dir)
        }
    }

    private static func listByHostPlists(in libraryURL: URL, bundleID: String) -> [URL] {
        let byHost = libraryURL.appendingPathComponent("Preferences/ByHost", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = "\(bundleID)."
        return entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".plist")
        }
    }

    private static func shouldMigrate(key: String) -> Bool {
        for prefix in businessKeyPrefixes where key.hasPrefix(prefix) {
            return true
        }
        return false
    }
}
