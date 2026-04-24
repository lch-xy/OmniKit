//
//  OmniKitStore.swift
//  OmniKit
//
//  统一的 KV 配置存储，取代 UserDefaults.standard。
//  底层后端是 OmniKitDataLocation.configFileURL 指向的 plist 文件，
//  这样配置会和其他数据一起躺在 ~/Library/Application Support/OmniKit/ 下。
//
//  API 刻意与 UserDefaults 对齐，以便大规模替换时改动最小。
//

import Foundation

final class OmniKitStore: @unchecked Sendable {

    static let shared = OmniKitStore()

    private let queue = DispatchQueue(label: "com.lch.OmniKit.Store", qos: .userInitiated)
    private let fileURL: URL
    private var storage: [String: Any]
    /// 防抖写盘任务，避免连续写入频繁落盘。
    private var pendingSaveWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(fileURL: URL = OmniKitDataLocation.configFileURL) {
        self.fileURL = fileURL
        OmniKitDataLocation.ensureDirectoriesExist()
        self.storage = Self.loadInitialStorage(from: fileURL)
    }

    private static func loadInitialStorage(from url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    // MARK: - 读取

    func object(forKey key: String) -> Any? {
        queue.sync { storage[key] }
    }

    func string(forKey key: String) -> String? {
        queue.sync { storage[key] as? String }
    }

    func bool(forKey key: String) -> Bool {
        queue.sync { (storage[key] as? Bool) ?? false }
    }

    func integer(forKey key: String) -> Int {
        queue.sync {
            if let i = storage[key] as? Int { return i }
            if let d = storage[key] as? Double { return Int(d) }
            if let n = storage[key] as? NSNumber { return n.intValue }
            return 0
        }
    }

    func double(forKey key: String) -> Double {
        queue.sync {
            if let d = storage[key] as? Double { return d }
            if let i = storage[key] as? Int { return Double(i) }
            if let n = storage[key] as? NSNumber { return n.doubleValue }
            return 0
        }
    }

    func data(forKey key: String) -> Data? {
        queue.sync { storage[key] as? Data }
    }

    func array(forKey key: String) -> [Any]? {
        queue.sync { storage[key] as? [Any] }
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        queue.sync { storage[key] as? [String: Any] }
    }

    // MARK: - 写入

    func set(_ value: Any?, forKey key: String) {
        queue.async { [self] in
            if let value = value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            scheduleSaveLocked()
        }
    }

    func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }

    /// 立即落盘，不等防抖。
    func synchronize() {
        queue.sync { [self] in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            saveLocked()
        }
    }

    /// 批量导入 —— 迁移场景使用。不存在的键才写，不覆盖已有值。
    func importIfAbsent(_ values: [String: Any]) {
        queue.sync { [self] in
            var changed = false
            for (k, v) in values where storage[k] == nil {
                storage[k] = v
                changed = true
            }
            if changed {
                saveLocked()
            }
        }
    }

    /// 供迁移流程直接读 storage 快照。
    func snapshot() -> [String: Any] {
        queue.sync { storage }
    }

    // MARK: - 内部

    private func scheduleSaveLocked() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // `work` 已经通过 `queue.asyncAfter` 投递到同一条串行队列，
            // 这里再 `queue.sync` 会发生自锁。
            self.saveLocked()
        }
        pendingSaveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 调用者必须持有 `queue`。
    private func saveLocked() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: storage, format: .binary, options: 0)
            // 原子写：先写 tmp 再 rename，避免断电半截文件
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            NSLog("[OmniKit] OmniKitStore save failed: \(error.localizedDescription)")
        }
    }
}
