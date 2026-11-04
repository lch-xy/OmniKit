//
//  MenuBarFolderController.swift
//  OmniKit
//
//  先按收纳名单排列并核验，再加长分隔符折叠左侧图标。
//  NSStatusItem 的安装仍放到下一轮 runloop，避免阻塞 SwiftUI 状态更新。
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import os.log

@MainActor
final class MenuBarFolderController: NSObject, ObservableObject {
    private static let enabledKey = "omnikit.menubarFolder.isEnabled"
    private static let collapsedKey = "omnikit.menubarFolder.isCollapsed"
    private static let separatorName = "omnikit.menubarFolder.separator"
    private static let expandedSeparatorLength: CGFloat = 1
    private static let logger = Logger(subsystem: "com.lch.OmniKit", category: "MenuBarFolder")

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            OmniKitStore.shared.set(isEnabled, forKey: Self.enabledKey)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isEnabled {
                    self.installStatusItems()
                } else {
                    self.uninstallStatusItems()
                }
            }
        }
    }

    /// 实际显示状态；排列期间保持展开，不把“正在准备折叠”显示为已折叠。
    @Published private(set) var isCollapsed = false
    @Published private(set) var isArranging = false
    @Published private(set) var statusMessage = "已展开：仅折叠标记收纳的图标。"
    @Published private(set) var needsAccessibility = !AXIsProcessTrusted()
    @Published private(set) var needsScreenRecording = !CGPreflightScreenCaptureAccess()

    private let iconManager: MenuBarIconManager
    private var chevronItem: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var collapseRequested: Bool
    private var arrangementTask: Task<Void, Never>?
    private var arrangementID = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var monitoring = Set<AnyCancellable>()

    init(iconManager: MenuBarIconManager) {
        self.iconManager = iconManager
        self.isEnabled = OmniKitStore.shared.bool(forKey: Self.enabledKey)
        self.collapseRequested = OmniKitStore.shared.bool(forKey: Self.collapsedKey)
        super.init()
        iconManager.$stashedItemIDs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleArrangement() }
            .store(in: &subscriptions)
        if isEnabled {
            DispatchQueue.main.async { [weak self] in self?.installStatusItems() }
        }
    }

    // MARK: - Public API

    func toggleCollapsed() {
        setCollapsed(!(isCollapsed || isArranging))
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isEnabled else { return }
        collapseRequested = collapsed
        OmniKitStore.shared.set(collapsed, forKey: Self.collapsedKey)
        if collapsed {
            scheduleArrangement()
        } else {
            cancelArrangement()
            applyCollapsedState(false)
            statusMessage = "已展开：收纳区域已恢复显示。"
        }
    }

    func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 安装 / 卸载

    private func installStatusItems() {
        guard isEnabled, separatorItem == nil, chevronItem == nil else { return }
        let separator = NSStatusBar.system.statusItem(withLength: Self.expandedSeparatorLength)
        if let button = separator.button {
            button.image = Self.makeTransparentImage()
            button.title = ""
            button.toolTip = "OmniKit 收纳分隔符：按标记自动分组"
            button.target = self
            button.action = #selector(chevronClicked)
        }
        separator.autosaveName = Self.separatorName
        separatorItem = separator

        let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = chevron.button {
            button.target = self
            button.action = #selector(chevronClicked)
            button.toolTip = "折叠 / 展开已标记收纳的图标"
        }
        chevron.autosaveName = "omnikit.menubarFolder.chevron"
        chevronItem = chevron
        applyCollapsedState(false)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkForChanges() }
            .store(in: &monitoring)
        // 通知只触发核验；图标位置正确时保持折叠，延迟创建的图标由定时检查兜底。
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.checkForChanges()
                    self?.iconManager.refresh()
                }
                .store(in: &monitoring)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkForChanges() }
            .store(in: &monitoring)
        scheduleArrangement()
    }

    private func uninstallStatusItems() {
        cancelArrangement()
        monitoring.removeAll()
        applyCollapsedState(false)
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        if let chevronItem { NSStatusBar.system.removeStatusItem(chevronItem) }
        separatorItem = nil
        chevronItem = nil
        statusMessage = "折叠功能未启用。"
    }

    private func cancelArrangement() {
        arrangementID = UUID()
        arrangementTask?.cancel()
        arrangementTask = nil
        isArranging = false
    }

    // MARK: - 按名单排列和核验

    private func checkPermissions() -> Bool {
        let previouslyMissing = needsAccessibility || needsScreenRecording
        needsAccessibility = !AXIsProcessTrusted()
        needsScreenRecording = !CGPreflightScreenCaptureAccess()
        if needsAccessibility || needsScreenRecording {
            applyCollapsedState(false)
            statusMessage = "请授予辅助功能和屏幕录制权限后折叠；当前保持展开。授权后如系统提示，请重新打开 OmniKit。"
            return false
        }
        if previouslyMissing { iconManager.refresh() }
        return true
    }

    private func checkForChanges() {
        guard isEnabled, checkPermissions(), collapseRequested, arrangementTask == nil else { return }
        guard let layout = currentLayout() else {
            applyCollapsedState(false)
            statusMessage = "暂时无法读取菜单栏，保持展开。"
            return
        }
        guard layout.items.contains(where: { $0.isStashed(in: layout.selections) }) else {
            applyCollapsedState(false)
            statusMessage = "当前没有可折叠的已标记图标；未识别或标记有歧义的图标保持显示。"
            return
        }
        let misplaced = layout.items.contains { !$0.isCorrectlyPlaced(relativeTo: layout.separator, selections: layout.selections) }
        if !isCollapsed || misplaced {
            scheduleArrangement()
        }
    }

    private func currentLayout() -> (separator: MenuBarStatusItem, items: [MenuBarStatusItem], selections: Set<String>)? {
        guard let windows = MenuBarStatusItem.current(),
              let separator = windows.first(where: { $0.ownerPID == getpid() && $0.title == Self.separatorName }) else { return nil }
        let items = windows.filter {
            $0.windowID != separator.windowID &&
            abs($0.frame.minY - separator.frame.minY) < 1 &&
            abs($0.frame.height - separator.frame.height) < 1
        }
        return (separator, items, MenuBarStatusItem.unambiguousSelections(iconManager.stashedItemIDs, items: items))
    }

    private func scheduleArrangement() {
        guard isEnabled, collapseRequested, separatorItem != nil else { return }
        cancelArrangement()
        applyCollapsedState(false)
        guard checkPermissions() else { return }
        isArranging = true
        statusMessage = "正在按收纳标记排列图标…"
        let id = arrangementID
        arrangementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.arrangementID == id {
                    self.arrangementTask = nil
                    self.isArranging = false
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await self.arrangeMarkedItems()
                try Task.checkCancellation()
                guard self.arrangementID == id, self.isEnabled, self.collapseRequested, self.checkPermissions() else { return }
                guard let layout = self.currentLayout() else { throw ArrangementError.unavailable }
                let hasMarkedItems = layout.items.contains { $0.isStashed(in: layout.selections) }
                guard !hasMarkedItems || layout.items.allSatisfy({ $0.isCorrectlyPlaced(relativeTo: layout.separator, selections: layout.selections) }) else {
                    throw ArrangementError.unstable
                }
                self.applyCollapsedState(hasMarkedItems)
                self.statusMessage = hasMarkedItems
                    ? "已折叠：仅隐藏已标记图标，未标记和新出现的图标保持显示。"
                    : "当前没有可折叠的已标记图标；未识别或标记有歧义的图标保持显示。"
            } catch is CancellationError {
                // 新的排列请求或用户展开已接管状态。
            } catch {
                guard self.arrangementID == id else { return }
                self.applyCollapsedState(false)
                self.collapseRequested = false
                self.statusMessage = "排列未完成，保持展开：\(error.localizedDescription)"
                Self.logger.error("Menu bar arrangement failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func arrangeMarkedItems() async throws {
        // 每次移动后重新读取坐标，避免使用其他图标移动前的位置。
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard let layout = currentLayout() else { throw ArrangementError.unavailable }
            iconManager.resolveLegacyStashedItems(using: layout.items)
            let selections = MenuBarStatusItem.unambiguousSelections(iconManager.stashedItemIDs, items: layout.items)
            guard layout.items.contains(where: { $0.isStashed(in: selections) }) else { return }
            let misplaced = layout.items
                .filter { !$0.isCorrectlyPlaced(relativeTo: layout.separator, selections: selections) }
                .sorted { !$0.isStashed(in: selections) && $1.isStashed(in: selections) }
            if misplaced.isEmpty {
                try await Task.sleep(for: .milliseconds(150))
                guard let verified = currentLayout() else { throw ArrangementError.unavailable }
                if Set(verified.items.map(\.windowID)) == Set(layout.items.map(\.windowID)),
                   verified.items.allSatisfy({ $0.isCorrectlyPlaced(relativeTo: verified.separator, selections: selections) }) { return }
                continue
            }
            for item in misplaced {
                for attempt in 0..<2 {
                    try Task.checkCancellation()
                    try await waitForMouseIdle()
                    guard let latest = currentLayout() else { throw ArrangementError.unavailable }
                    guard let current = latest.items.first(where: { $0.windowID == item.windowID }) else { break }
                    if current.isCorrectlyPlaced(relativeTo: latest.separator, selections: latest.selections) { break }
                    try await move(current, beside: latest.separator, toLeft: current.isStashed(in: latest.selections))
                    guard let updated = currentLayout() else { throw ArrangementError.unavailable }
                    guard let moved = updated.items.first(where: { $0.windowID == item.windowID }) else { break }
                    if moved.isCorrectlyPlaced(relativeTo: updated.separator, selections: updated.selections) { break }
                    if attempt == 1 { throw ArrangementError.moveFailed(current.title) }
                }
            }
        }
        throw ArrangementError.unstable
    }

    private func waitForMouseIdle() async throws {
        for _ in 0..<30 {
            try Task.checkCancellation()
            let buttonsDown = NSEvent.pressedMouseButtons != 0
            let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            if !buttonsDown, modifiers.isEmpty,
               CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) >= 0.25 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ArrangementError.mouseBusy
    }

    private func move(_ item: MenuBarStatusItem, beside separator: MenuBarStatusItem, toLeft: Bool) async throws {
        // 被刘海或拥挤菜单栏遮住的图标仍可按窗口 ID 移动，不能依赖屏幕命中测试。
        let start = CGPoint(x: 20000, y: 20000)
        let end = CGPoint(x: toLeft ? separator.frame.minX : separator.frame.maxX, y: separator.frame.midY)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let cursor = CGEvent(source: nil)?.location,
              let down = mouseEvent(.leftMouseDown, at: start, windowID: item.windowID, ownerPID: item.ownerPID, source: source),
              let up = mouseEvent(.leftMouseUp, at: end, windowID: separator.windowID, ownerPID: item.ownerPID, source: source),
              let cancel = mouseEvent(.leftMouseUp, at: item.frame.origin, windowID: item.windowID, ownerPID: item.ownerPID, source: source) else { throw ArrangementError.unavailable }
        var released = false
        defer {
            if !released {
                cancel.post(tap: .cgSessionEventTap)
                cancel.postToPid(item.ownerPID)
            }
            CGWarpMouseCursorPosition(cursor)
        }
        // 会话先更新拖动状态，再把事件交给源图标进程；松开事件使用目标窗口。
        down.post(tap: .cgSessionEventTap)
        try await Task.sleep(for: .milliseconds(30))
        down.postToPid(item.ownerPID)
        try await Task.sleep(for: .milliseconds(150))
        up.post(tap: .cgSessionEventTap)
        try await Task.sleep(for: .milliseconds(30))
        up.postToPid(item.ownerPID)
        released = true
        try await Task.sleep(for: .milliseconds(200))
    }

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, windowID: CGWindowID, ownerPID: pid_t, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = type == .leftMouseUp ? [] : .maskCommand
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        // NSEvent.windowNumber 的底层字段，用于将按下事件投递给具体状态栏窗口。
        if let field = CGEventField(rawValue: 0x33) { event.setIntegerValueField(field, value: Int64(windowID)) }
        return event
    }

    private enum ArrangementError: LocalizedError {
        case unavailable, unstable, mouseBusy
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法读取菜单栏图标，请确认权限后重试。"
            case .unstable: return "菜单栏仍在变化，请稍后重试。"
            case .mouseBusy: return "鼠标或修饰键正在使用，请松开后重试。"
            case .moveFailed(let name): return "未能移动图标 \(name)，请稍后重试。"
            }
        }
    }

    // MARK: - 状态应用

    private func applyCollapsedState(_ collapsed: Bool) {
        guard let separatorItem, let chevronItem else { return }
        isCollapsed = collapsed
        let screenWidth = separatorItem.button?.window?.screen?.frame.width ?? NSScreen.main?.frame.width ?? 1600
        separatorItem.length = collapsed ? max(screenWidth + 200, 1600) : Self.expandedSeparatorLength
        updateChevronAppearance(on: chevronItem)
    }

    private func updateChevronAppearance(on item: NSStatusItem) {
        guard let button = item.button else { return }
        // 折叠时箭头指右：点一下"把它们从右侧放回来（展开）"；
        // 展开时箭头指左：点一下"把它们推到左边藏起来（折叠）"。
        // 换成单箭头（chevron.right/left），视觉上更轻盈精致
        let primary = isCollapsed ? "chevron.right" : "chevron.left"
        let fallback = isCollapsed ? "arrowtriangle.right" : "arrowtriangle.left"
        let accessibilityText = isCollapsed ? "展开菜单栏图标" : "折叠菜单栏图标"
        
        // 增加一点 font weight 让它在菜单栏里更清晰但不过分粗重
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let symbolImage = NSImage(systemSymbolName: primary, accessibilityDescription: accessibilityText)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: accessibilityText)?.withSymbolConfiguration(config)
        
        symbolImage?.isTemplate = true

        if let symbolImage {
            button.image = symbolImage
            button.title = ""
        } else {
            // 完全降级：用文字，保证按钮有命中区。
            button.image = nil
            button.title = isCollapsed ? "»" : "«"
        }
    }

    // MARK: - 动作

    @objc private func chevronClicked() {
        Self.logger.log("chevronClicked (current collapsed=\(self.isCollapsed, privacy: .public))")
        toggleCollapsed()
    }

    // MARK: - Helpers

    private static func makeTransparentImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = true
        return image
    }
}
