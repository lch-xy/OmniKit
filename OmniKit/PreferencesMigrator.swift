//
//  PreferencesMigrator.swift
//  OmniKit
//
//  把历史版本散落在各处的数据全部收拢到 ~/Library/Application Support/OmniKit/ 下。
//  历史来源：
//    • App Sandbox 时期的   ~/Library/Containers/<bundleID>/.../Preferences/<bundleID>.plist
//    • 非沙盒 UserDefaults: ~/Library/Preferences/<bundleID>.plist
//    • 早期会议录音目录：    ~/Library/Application Support/OmniKit/Meetings/（路径和现在一致，无需搬）
//  新配置保存并校验成功后，只清理已迁移的配置键，保留容器和其他数据。
//

import AppKit
import Foundation

enum PreferencesMigrator {

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
    @discardableResult
    static func migrateIfNeeded(
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.lch.OmniKit",
        store: OmniKitStore = .shared,
        defaults: UserDefaults = .standard,
        libraryURL: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    ) -> Bool {
        if store.bool(forKey: v2DoneKey) { return true }
        guard let libraryURL else { return false }
        let candidatePaths = [
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
        ] + listByHostPlists(in: libraryURL, bundleID: bundleID)

        do {
            var payload = defaults.dictionaryRepresentation().filter { shouldMigrate(key: $0.key) }
            payload.removeValue(forKey: v2DoneKey)
            for url in candidatePaths where FileManager.default.fileExists(atPath: url.path) {
                let plist = try readPreferences(at: url)
                for (key, value) in plist where shouldMigrate(key: key) && key != v2DoneKey && payload[key] == nil {
                    payload[key] = value
                }
            }
            try store.importIfAbsent(payload)
            try store.synchronize()
            cleanupLegacyLocations(defaults: defaults, preferenceURLs: candidatePaths, saved: store.snapshot())
            try store.importIfAbsent([v2DoneKey: true])
            return true
        } catch {
            NSLog("[OmniKit] Preferences migration failed; legacy data retained: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 清理

    private static func cleanupLegacyLocations(defaults: UserDefaults, preferenceURLs: [URL], saved: [String: Any]) {
        let all = defaults.dictionaryRepresentation()
        for (key, value) in all where isSaved(key: key, value: value, saved: saved) {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        for url in preferenceURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                let current = try readPreferences(at: url)
                let remaining = current.filter { !isSaved(key: $0.key, value: $0.value, saved: saved) }
                guard remaining.count != current.count else { continue }
                let data = try PropertyListSerialization.data(fromPropertyList: remaining, format: .binary, options: 0)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[OmniKit] Legacy preferences retained: \(error.localizedDescription)")
            }
        }
    }

    private static func readPreferences(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return plist
    }

    private static func isSaved(key: String, value: Any, saved: [String: Any]) -> Bool {
        guard shouldMigrate(key: key), let savedValue = saved[key] else { return false }
        return NSDictionary(dictionary: [key: value]).isEqual(to: [key: savedValue])
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
