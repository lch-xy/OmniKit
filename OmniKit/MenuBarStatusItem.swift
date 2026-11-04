//
//  MenuBarStatusItem.swift
//  OmniKit
//

import AppKit

/// 实际的状态栏窗口；用应用标识和窗口名称区分同一应用的多个图标。
nonisolated struct MenuBarStatusItem: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String?
    let title: String
    let frame: CGRect
    let isOnScreen: Bool

    var selectionID: String? {
        guard let bundleID, !title.isEmpty else { return nil }
        return bundleID + "#" + title
    }

    static func current() -> [Self]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var bundleIDs: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            bundleIDs[app.processIdentifier] = app.bundleIdentifier
        }
        return windows.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 0, frame.height > 0, frame.height <= 64 else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            // 其他屏幕/Space 的镜像没有名称；未显示的状态项会停放在原点。
            // 已被分隔符挤到屏幕左边的具名窗口仍必须保留。
            guard isOnScreen || (!title.isEmpty && frame.origin != .zero) else { return nil }
            return Self(windowID: windowID, ownerPID: pid, bundleID: bundleIDs[pid], title: title, frame: frame, isOnScreen: isOnScreen)
        }
    }

    static func migrateLegacySelections(_ selections: Set<String>, items: [Self]) -> Set<String> {
        var result = selections
        for selection in selections where selection.hasSuffix("#__runtime__") {
            let bundleID = String(selection.dropLast("#__runtime__".count))
            let candidates = items.filter { $0.bundleID == bundleID }
            // 不把旧的应用级标记扩展到该应用后来新增的图标。
            guard candidates.count == 1, let id = candidates.first?.selectionID else { continue }
            result.remove(selection)
            result.insert(id)
        }
        return result
    }

    func isStashed(in selections: Set<String>) -> Bool {
        selectionID.map { selections.contains($0) } ?? false
    }

    static func unambiguousSelections(_ selections: Set<String>, items: [Self]) -> Set<String> {
        let counts = Dictionary(grouping: items.compactMap(\.selectionID), by: { $0 })
        return selections.filter { counts[$0]?.count == 1 }
    }

    func isCorrectlyPlaced(relativeTo separator: Self, selections: Set<String>) -> Bool {
        if isStashed(in: selections) {
            return frame.maxX <= separator.frame.minX + 0.5
        }
        return frame.minX >= separator.frame.maxX - 0.5
    }
}
