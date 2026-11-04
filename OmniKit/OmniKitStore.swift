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
import AppKit

final class OmniKitStore: @unchecked Sendable {

    static let shared = OmniKitStore()

    private let queue = DispatchQueue(label: "com.lch.OmniKit.Store", qos: .userInitiated)
    private let fileURL: URL
    private var storage: [String: Any]
    private var loadError: Error?
    private var terminationObserver: NSObjectProtocol?
    /// 防抖写盘任务，避免连续写入频繁落盘。
    private var pendingSaveWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(fileURL: URL = OmniKitDataLocation.configFileURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.storage = [:]
        do {
            self.storage = try Self.loadInitialStorage(from: fileURL)
        } catch {
            loadError = error
            NSLog("[OmniKit] OmniKitStore load failed: \(error.localizedDescription)")
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            do {
                try self?.synchronize()
            } catch {
                NSLog("[OmniKit] OmniKitStore final save failed: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    private static func loadInitialStorage(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
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
    func synchronize() throws {
        try queue.sync { [self] in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            try saveLocked()
            let saved = try Self.loadInitialStorage(from: fileURL)
            guard NSDictionary(dictionary: storage).isEqual(to: saved) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    /// 批量导入 —— 迁移场景使用。不存在的键才写，不覆盖已有值。
    func importIfAbsent(_ values: [String: Any]) throws {
        try queue.sync { [self] in
            let previousStorage = storage
            var changed = false
            for (k, v) in values where storage[k] == nil {
                storage[k] = v
                changed = true
            }
            if changed {
                do {
                    try saveLocked()
                } catch {
                    storage = previousStorage
                    throw error
                }
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
            do {
                try self.saveLocked()
            } catch {
                NSLog("[OmniKit] OmniKitStore save failed: \(error.localizedDescription)")
            }
        }
        pendingSaveWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 调用者必须持有 `queue`。
    private func saveLocked() throws {
        if let loadError { throw loadError }
        let data = try PropertyListSerialization.data(fromPropertyList: storage, format: .binary, options: 0)
        try data.write(to: fileURL, options: .atomic)
    }
}
