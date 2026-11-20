//
//  AppDimmingManager.swift
//  OmniKit
//

import AppKit
import Combine
import QuartzCore

enum AppDisplayEffect: String, CaseIterable, Identifiable {
    case dimming
    case transparency
    var id: Self { self }
    var title: String { self == .dimming ? "淡化" : "透明" }
}

struct AppDimmingRule: Codable, Identifiable {
    let bundleID: String
    let name: String
    var strength: Int

    var id: String { bundleID }
}

struct AppDimmingColor: Codable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let white = AppDimmingColor(red: 255, green: 255, blue: 255)

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(nsColor: NSColor) {
        guard let color = nsColor.usingColorSpace(.sRGB) else { return nil }
        red = UInt8((min(1, max(0, color.redComponent)) * 255).rounded())
        green = UInt8((min(1, max(0, color.greenComponent)) * 255).rounded())
        blue = UInt8((min(1, max(0, color.blueComponent)) * 255).rounded())
    }
}

@MainActor
final class AppDimmingManager: NSObject, ObservableObject {
    private static let rulesKey = "omnikit.appDimming.rules"
    private static let enabledKey = "omnikit.appDimming.isEnabled"
    private static let effectKey = "omnikit.appDimming.effect"
    private static let maskColorKey = "omnikit.appDimming.maskColor"
    private let store: OmniKitStore

    @Published private(set) var rules: [AppDimmingRule]
    @Published private(set) var needsScreenRecording = false
    @Published private(set) var transparencyStatus = ""
    @Published var maskColor: AppDimmingColor {
        didSet {
            guard oldValue != maskColor else { return }
            if let data = try? JSONEncoder().encode(maskColor) {
                store.set(data, forKey: Self.maskColorKey)
            }
            if effect == .dimming {
                for overlay in overlays.values { overlay.backgroundColor = maskColor.nsColor }
            }
        }
    }
    @Published var effect: AppDisplayEffect {
        didSet {
            guard oldValue != effect else { return }
            store.set(effect.rawValue, forKey: Self.effectKey)
            clearOverlays()
            failedCaptures.removeAll()
            checkScreenRecordingPermission()
        }
    }
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            store.set(isEnabled, forKey: Self.enabledKey)
            updateMonitoring()
        }
    }

    private var timer: Timer?
    private var followTimer: Timer?
    private var overlays: [CGWindowID: DimmingWindow] = [:]
    private var captures: [CGWindowID: AppTransparencyCapture] = [:]
    private var captureTokens: [CGWindowID: UUID] = [:]
    private var captureScreens: [CGWindowID: NSScreen] = [:]
    private var targetFrames: [CGWindowID: NSRect] = [:]
    private var targetStrengths: [CGWindowID: Int] = [:]
    private var capturedFrames: [CGWindowID: CGImage] = [:]
    private var failedCaptures = Set<CGWindowID>()
    private var terminationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(store: OmniKitStore? = nil) {
        let store = store ?? OmniKitStore.shared
        self.store = store
        if let data = store.data(forKey: Self.rulesKey),
           let saved = try? JSONDecoder().decode([AppDimmingRule].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
        isEnabled = store.object(forKey: Self.enabledKey) as? Bool ?? true
        effect = AppDisplayEffect(rawValue: store.string(forKey: Self.effectKey) ?? "") ?? .dimming
        if let data = store.data(forKey: Self.maskColorKey), let color = try? JSONDecoder().decode(AppDimmingColor.self, from: data) {
            maskColor = color
        } else {
            maskColor = .white
        }
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearOverlays() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearOverlays() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearOverlays() }
        }
        checkScreenRecordingPermission()
    }

    deinit {
        timer?.invalidate()
        followTimer?.invalidate()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        MainActor.assumeIsolated { clearOverlays() }
    }

    func addApplication(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !rules.contains(where: { $0.bundleID == bundleID }) else { return false }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        rules.append(AppDimmingRule(bundleID: bundleID, name: name, strength: 50))
        saveRules()
        return true
    }

    func removeApplication(_ bundleID: String) {
        rules.removeAll { $0.bundleID == bundleID }
        saveRules()
    }

    func setStrength(_ strength: Int, for bundleID: String) {
        guard let index = rules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        rules[index].strength = min(100, max(0, strength))
        saveRules()
    }

    func checkScreenRecordingPermission() {
        needsScreenRecording = effect == .transparency && !CGPreflightScreenCaptureAccess()
        if !needsScreenRecording { failedCaptures.removeAll(); transparencyStatus = "" }
        updateMonitoring()
    }

    func requestScreenRecordingPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        checkScreenRecordingPermission()
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            store.set(data, forKey: Self.rulesKey)
        }
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard isEnabled, rules.contains(where: { $0.strength > 0 }) else {
            timer?.invalidate()
            timer = nil
            clearOverlays()
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    private func refresh() {
        if effect == .transparency {
            needsScreenRecording = !CGPreflightScreenCaptureAccess()
            if needsScreenRecording {
                if !captures.isEmpty || !overlays.isEmpty { clearOverlays() }
                return
            }
        }
        let strengthByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.bundleID, $0.strength) })
        let appStrengths = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, Int)? in
            guard !app.isHidden, app.processIdentifier != getpid(), let bundleID = app.bundleIdentifier,
                  let strength = strengthByID[bundleID], strength > 0 else { return nil }
            return (app.processIdentifier, strength)
        })
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainScreen = NSScreen.screens.first else {
            clearOverlays()
            return
        }

        var currentIDs = Set<CGWindowID>()
        let orderedIDs = windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let strength = appStrengths[pid],
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 0, frame.height > 0 else { continue }

            let appKitFrame = NSRect(x: frame.minX, y: mainScreen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            // 独立全屏空间不受支持，避免覆盖全屏软件。
            guard !NSScreen.screens.contains(where: { $0.frame.equalTo(appKitFrame) }) else { continue }
            if effect == .transparency {
                guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitFrame) }),
                      let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                currentIDs.insert(id)
                let frameChanged = targetFrames[id] != appKitFrame
                targetFrames[id] = appKitFrame
                targetStrengths[id] = strength
                if let previous = captureScreens[id], previous != screen {
                    removeOverlay(id)
                    targetFrames[id] = appKitFrame
                    targetStrengths[id] = strength
                }
                if captures[id] == nil && !failedCaptures.contains(id) {
                    startCapture(id: id, displayID: displayID, screen: screen)
                }
                if frameChanged, let image = capturedFrames[id] {
                    renderCapture(id: id, image: image)
                }
                if let overlay = overlays[id] {
                    if overlay.frame != appKitFrame { overlay.setFrame(appKitFrame, display: true) }
                    overlay.alphaValue = CGFloat(strength) / 100
                    let overlayIndex = overlay.windowNumber > 0 ? orderedIDs.firstIndex(of: CGWindowID(overlay.windowNumber)) : nil
                    let targetIndex = orderedIDs.firstIndex(of: id)
                    if overlayIndex == nil || targetIndex == nil || overlayIndex! + 1 != targetIndex! {
                        overlay.order(.above, relativeTo: Int(id))
                    }
                }
                continue
            }
            currentIDs.insert(id)
            let overlay: DimmingWindow
            if let existing = overlays[id] {
                overlay = existing
            } else {
                overlay = DimmingWindow(contentRect: appKitFrame)
                overlay.backgroundColor = maskColor.nsColor
                overlays[id] = overlay
            }
            if overlay.frame != appKitFrame {
                overlay.setFrame(appKitFrame, display: true)
            }
            overlay.alphaValue = CGFloat(strength) / 100
            let overlayIndex = overlay.windowNumber > 0 ? orderedIDs.firstIndex(of: CGWindowID(overlay.windowNumber)) : nil
            let targetIndex = orderedIDs.firstIndex(of: id)
            if !overlay.isVisible || overlayIndex == nil || targetIndex == nil || overlayIndex! + 1 != targetIndex! {
                overlay.order(.above, relativeTo: Int(id))
            }
        }
        let oldIDs = Set(overlays.keys).union(captures.keys).union(failedCaptures)
        for id in oldIDs where !currentIDs.contains(id) {
            removeOverlay(id)
        }
    }

    private func startCapture(id: CGWindowID, displayID: CGDirectDisplayID, screen: NSScreen) {
        let token = UUID()
        captureTokens[id] = token
        captureScreens[id] = screen
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        let capture = AppTransparencyCapture(targetID: id, displayID: displayID, pixelSize: size) { [weak self] image in
            guard let self, self.captureTokens[id] == token else { return }
            self.capturedFrames[id] = image
            self.renderCapture(id: id, image: image)
        } onFailure: { [weak self] in
            guard let self, self.captureTokens[id] == token else { return }
            self.removeOverlay(id)
            self.failedCaptures.insert(id)
            self.transparencyStatus = "捕获失败，请重新检查屏幕录制权限后重试。"
        }
        captures[id] = capture
        if followTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followTransparentWindows() }
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
        capture.start()
    }

    private func followTransparentWindows() {
        guard effect == .transparency, !overlays.isEmpty, let mainScreen = NSScreen.screens.first else { return }
        // 该接口的 CFArray 元素是窗口 ID 原始值，而不是 NSNumber 对象。
        var ids = overlays.keys.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let windowIDs = ids.withUnsafeMutableBufferPointer({ buffer in
            CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil)
        }), let windows = CGWindowListCreateDescriptionFromArray(windowIDs) as? [[String: Any]] else { return }
        let orderedWindows = NSWindow.windowNumbers(options: .allApplications)?.map(\.intValue) ?? []
        for info in windows {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let screen = captureScreens[id], let oldFrame = targetFrames[id],
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            let newFrame = NSRect(x: frame.minX, y: mainScreen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            if newFrame != oldFrame {
                guard screen.frame.contains(newFrame),
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      (info[kCGWindowIsOnscreen as String] as? Bool ?? true) else {
                    removeOverlay(id)
                    continue
                }
                targetFrames[id] = newFrame
                if let image = capturedFrames[id] { renderCapture(id: id, image: image) }
            }
            if let overlay = overlays[id],
               let targetIndex = orderedWindows.firstIndex(of: Int(id)),
               let overlayIndex = orderedWindows.firstIndex(of: overlay.windowNumber),
               overlayIndex + 1 != targetIndex {
                overlay.order(.above, relativeTo: Int(id))
            }
        }
    }

    private func renderCapture(id: CGWindowID, image: CGImage) {
        guard let frame = targetFrames[id], let screen = captureScreens[id], let strength = targetStrengths[id] else { return }
        let screenFrame = screen.frame
        let rect = CGRect(x: (frame.minX - screenFrame.minX) / screenFrame.width * CGFloat(image.width),
                          y: (screenFrame.maxY - frame.maxY) / screenFrame.height * CGFloat(image.height),
                          width: frame.width / screenFrame.width * CGFloat(image.width),
                          height: frame.height / screenFrame.height * CGFloat(image.height)).integral
        guard let cropped = image.cropping(to: rect) else { return }
        let overlay = overlays[id] ?? DimmingWindow(contentRect: frame)
        overlays[id] = overlay
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if overlay.frame != frame { overlay.setFrame(frame, display: false) }
            overlay.setImage(cropped)
            overlay.alphaValue = CGFloat(strength) / 100
            CATransaction.commit()
        }
        if !overlay.isVisible { overlay.order(.above, relativeTo: Int(id)) }
    }

    private func removeOverlay(_ id: CGWindowID) {
        captureTokens.removeValue(forKey: id)
        captures.removeValue(forKey: id)?.stop()
        if captures.isEmpty {
            followTimer?.invalidate()
            followTimer = nil
        }
        captureScreens.removeValue(forKey: id)
        targetFrames.removeValue(forKey: id)
        targetStrengths.removeValue(forKey: id)
        capturedFrames.removeValue(forKey: id)
        failedCaptures.remove(id)
        overlays.removeValue(forKey: id)?.orderOut(nil)
    }

    private func clearOverlays() {
        followTimer?.invalidate()
        followTimer = nil
        for capture in captures.values { capture.stop() }
        captures.removeAll()
        captureTokens.removeAll()
        captureScreens.removeAll()
        targetFrames.removeAll()
        targetStrengths.removeAll()
        capturedFrames.removeAll()
        failedCaptures.removeAll()
        for overlay in overlays.values { overlay.orderOut(nil) }
        overlays.removeAll()
    }
}

private final class DimmingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .white
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
    }

    func setImage(_ image: CGImage) {
        let imageView: NSImageView
        if let existing = contentView as? NSImageView {
            imageView = existing
        } else {
            imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
            imageView.imageScaling = .scaleAxesIndependently
            contentView = imageView
            backgroundColor = .clear
        }
        imageView.image = NSImage(cgImage: image, size: frame.size)
    }
}
