//
//  MenuBarFolderController.swift
//  OmniKit
//
//  "真·隐藏图标但不退出 App" 的实现。
//
//  背景：
//  macOS 公共 API 不允许一个 App 去隐藏/移动另一个 App 的 NSStatusItem，
//  因此 Bartender / Ice / Hidden Bar 这一类工具全部走同一条路：
//    1) 自己在菜单栏里放一个"分隔符"状态栏项；
//    2) 用户手动按住 ⌘ 拖动其他 App 的图标到分隔符的某一侧；
//    3) 通过把分隔符自身的 `length` 拉得非常大，
//       把分隔符左侧的图标挤出屏幕可视区域，从视觉上实现"折叠"。
//
//  OmniKit 的做法与 Hidden Bar 接近，但保留主 MenuBarExtra 不动，
//  额外注入两个 NSStatusItem：
//    - chevronItem：始终可见的折叠/展开按钮；
//    - separatorItem：视觉上不可见的占位分隔符，折叠时通过超长 `length`
//      把左侧图标推出可视区。
//
//  继承 NSObject 是**必须的**：NSStatusBarButton 通过 target/action 机制派发点击，
//  需要 ObjC 运行时能在实例上调用到 `chevronClicked`。
//
//  关于"点击开关就卡死"的防御：
//    SwiftUI Binding.set → @Published didSet → 同步创建 NSStatusItem，
//    会让 AppKit 在 SwiftUI 的状态更新事务里做菜单栏 I/O，
//    观察到会出现主线程卡住/事件循环死锁。
//    这里改成用 DispatchQueue.main.async 把实际 install/uninstall 推到
//    下一个 runloop 周期，让 SwiftUI 先把本次状态更新走完，再做 AppKit 重活。
//
//  持久化：
//    - 是否启用折叠功能：OmniKitStore["omnikit.menubarFolder.isEnabled"]
//    - 当前是否处于折叠态：OmniKitStore["omnikit.menubarFolder.isCollapsed"]
//

import AppKit
import Combine
import Foundation
import os.log

@MainActor
final class MenuBarFolderController: NSObject, ObservableObject {

    // MARK: - 持久化 key

    private static let enabledKey = "omnikit.menubarFolder.isEnabled"
    private static let collapsedKey = "omnikit.menubarFolder.isCollapsed"

    /// 展开时 separator 的长度 —— 用 1pt 的极小宽度，几乎等同于不可见。
    private static let expandedSeparatorLength: CGFloat = 1

    /// 折叠时 separator 的长度：按当前主屏宽度 + 余量动态算，
    /// 避免硬编码过大的值让 AppKit 在重布局时卡住。
    private static func collapsedSeparatorLength() -> CGFloat {
        let screenWidth = NSScreen.main?.frame.width ?? 1600
        return max(screenWidth + 200, 1600)
    }

    private static let logger = Logger(subsystem: "com.lch.OmniKit", category: "MenuBarFolder")

    // MARK: - Published 状态

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            OmniKitStore.shared.set(isEnabled, forKey: Self.enabledKey)
            let targetEnabled = isEnabled
            // 从 SwiftUI 的状态更新事务里抽出来，下一轮 runloop 再动菜单栏。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if targetEnabled {
                    self.installStatusItems()
                } else {
                    self.uninstallStatusItems()
                }
            }
        }
    }

    @Published private(set) var isCollapsed: Bool {
        didSet {
            guard oldValue != isCollapsed else { return }
            OmniKitStore.shared.set(isCollapsed, forKey: Self.collapsedKey)
            DispatchQueue.main.async { [weak self] in
                self?.applyCollapsedState()
            }
        }
    }

    // MARK: - 私有状态

    private var chevronItem: NSStatusItem?
    private var separatorItem: NSStatusItem?

    // MARK: - Init

    override init() {
        self.isEnabled = OmniKitStore.shared.bool(forKey: Self.enabledKey)
        self.isCollapsed = OmniKitStore.shared.bool(forKey: Self.collapsedKey)
        super.init()
        // 同样推到下一轮 runloop，避免在 App 启动的 scene 构建期间占主线程。
        if isEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.installStatusItems()
            }
        }
        Self.logger.log("init (enabled=\(self.isEnabled, privacy: .public), collapsed=\(self.isCollapsed, privacy: .public))")
    }

    // MARK: - Public API

    func toggleCollapsed() {
        guard isEnabled else { return }
        isCollapsed.toggle()
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isEnabled else { return }
        if isCollapsed != collapsed {
            isCollapsed = collapsed
        }
    }

    // MARK: - 安装 / 卸载 NSStatusItem

    private func installStatusItems() {
        guard separatorItem == nil, chevronItem == nil else {
            Self.logger.log("install skipped: already installed")
            return
        }
        Self.logger.log("install begin")

        // 先创建 separator 再创建 chevron：macOS 按创建顺序从右向左排列，
        // 最终视觉（自右向左）= [chevron] [separator] [用户⌘拖过来的图标]
        let separator = NSStatusBar.system.statusItem(withLength: Self.expandedSeparatorLength)
        Self.logger.log("install step 1: separator item created")
        if let button = separator.button {
            // 用一张 1x1 透明图占位，避免 button 被视作"无内容 item"而被 AppKit 忽略布局。
            button.image = Self.makeTransparentImage()
            button.title = ""
            button.toolTip = "OmniKit 折叠分隔符：把想隐藏的图标按住 ⌘ 拖到这条分隔符的左侧"
            button.target = self
            button.action = #selector(chevronClicked)
        }
        // autosaveName 放在最后设，避免 AppKit 读取历史位置时触发 pref IO
        // 把 target/action 之前的 button 改动吞掉。
        separator.autosaveName = "omnikit.menubarFolder.separator"
        self.separatorItem = separator
        Self.logger.log("install step 2: separator configured")

        let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        Self.logger.log("install step 3: chevron item created")
        if let button = chevron.button {
            button.target = self
            button.action = #selector(chevronClicked)
            button.toolTip = "点击折叠 / 展开 OmniKit 菜单栏分隔符左侧的图标"
        }
        chevron.autosaveName = "omnikit.menubarFolder.chevron"
        self.chevronItem = chevron
        Self.logger.log("install step 4: chevron configured")

        applyCollapsedState()
        Self.logger.log("install done")
    }

    private func uninstallStatusItems() {
        Self.logger.log("uninstall begin")
        if let separatorItem {
            NSStatusBar.system.removeStatusItem(separatorItem)
        }
        if let chevronItem {
            NSStatusBar.system.removeStatusItem(chevronItem)
        }
        separatorItem = nil
        chevronItem = nil
        Self.logger.log("uninstall done")
    }

    // MARK: - 状态应用

    private func applyCollapsedState() {
        Self.logger.log("applyCollapsedState begin (collapsed=\(self.isCollapsed, privacy: .public))")
        guard let separatorItem, let chevronItem else {
            Self.logger.log("applyCollapsedState skipped: items not installed")
            return
        }
        let targetLength: CGFloat = isCollapsed ? Self.collapsedSeparatorLength() : Self.expandedSeparatorLength
        Self.logger.log("applyCollapsedState: setting separator.length = \(targetLength, privacy: .public)")
        separatorItem.length = targetLength
        Self.logger.log("applyCollapsedState: separator.length set OK")
        updateChevronAppearance(on: chevronItem)
        Self.logger.log("applyCollapsedState done")
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
