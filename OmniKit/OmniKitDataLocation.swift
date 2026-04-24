//
//  OmniKitDataLocation.swift
//  OmniKit
//
//  所有 OmniKit 自己落盘的数据，统一放在 ~/Library/Application Support/OmniKit/ 下。
//  任何需要读写文件的模块，应只通过这里暴露的 URL 访问，禁止再自己拼路径。
//

import Foundation

enum OmniKitDataLocation {
    /// 统一的数据根目录：~/Library/Application Support/OmniKit/
    static var rootDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OmniKit", isDirectory: true)
    }

    /// 所有 KV 配置落盘文件：<root>/config.plist
    static var configFileURL: URL {
        rootDirectory.appendingPathComponent("config.plist", isDirectory: false)
    }

    /// 会议录音目录：<root>/Meetings/
    static var meetingsDirectory: URL {
        rootDirectory.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// 会议记录索引：<root>/Meetings/records.json
    static var meetingRecordsURL: URL {
        meetingsDirectory.appendingPathComponent("records.json", isDirectory: false)
    }

    /// SwiftData 默认 store 位置：<root>/SwiftData/default.store
    static var swiftDataStoreURL: URL {
        rootDirectory
            .appendingPathComponent("SwiftData", isDirectory: true)
            .appendingPathComponent("default.store", isDirectory: false)
    }

    /// 数据目录用户说明文件：<root>/README.txt
    static var readmeFileURL: URL {
        rootDirectory.appendingPathComponent("README.txt", isDirectory: false)
    }

    /// 确保数据根目录及必要子目录存在。
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        let dirs = [
            rootDirectory,
            meetingsDirectory,
            swiftDataStoreURL.deletingLastPathComponent()
        ]
        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        writeReadmeIfNeeded()
    }

    private static func writeReadmeIfNeeded() {
        let url = readmeFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let content = """
        OmniKit 数据目录
        ================

        这里存放 OmniKit 运行时生成的全部数据，可以直接 zip 整个文件夹做备份。

        文件说明：
          • config.plist              所有用户配置（API Key、快捷键、识别语言、电池上限等）
          • Meetings/                 会议录音目录
              • records.json           录音索引
              • meeting_*.caf          单次录音文件
          • SwiftData/default.store   SwiftData 默认存储（当前未使用，保留）

        卸载 OmniKit 时直接删除此目录即可。
        """
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
