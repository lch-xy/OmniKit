import AppKit
import Testing
@testable import OmniKit

@MainActor
@Suite(.serialized)
struct AppTransparencyTests {
    @Test func legacyRulesLoadWithDimmingDefaultAndRemainUnchangedWhenEffectChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OmniKitStore(fileURL: root.appendingPathComponent("config.plist"))
        let legacyRules = [
            AppDimmingRule(bundleID: "test.omnikit.legacy.one", name: "Legacy One", strength: 35),
            AppDimmingRule(bundleID: "test.omnikit.legacy.two", name: "Legacy Two", strength: 80)
        ]
        store.set(try JSONEncoder().encode(legacyRules), forKey: "omnikit.appDimming.rules")
        store.set(false, forKey: "omnikit.appDimming.isEnabled")
        try store.synchronize()

        let manager = AppDimmingManager(store: store)
        #expect(manager.effect == .dimming)
        #expect(manager.rules.count == legacyRules.count)
        #expect(manager.rules[0].bundleID == legacyRules[0].bundleID)
        #expect(manager.rules[0].strength == legacyRules[0].strength)
        #expect(manager.rules[1].bundleID == legacyRules[1].bundleID)
        #expect(manager.rules[1].strength == legacyRules[1].strength)

        manager.effect = .transparency
        try store.synchronize()
        #expect(store.string(forKey: "omnikit.appDimming.effect") == "transparency")
        let restored = AppDimmingManager(store: OmniKitStore(fileURL: root.appendingPathComponent("config.plist")))
        #expect(restored.effect == .transparency)
        #expect(restored.rules.count == legacyRules.count)
        #expect(restored.rules[0].strength == legacyRules[0].strength)
        #expect(restored.rules[1].strength == legacyRules[1].strength)
        restored.isEnabled = false
    }

    @Test func invalidEffectFallsBackToDimming() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OmniKitStore(fileURL: root.appendingPathComponent("config.plist"))
        store.set("unknown-effect", forKey: "omnikit.appDimming.effect")
        store.set(false, forKey: "omnikit.appDimming.isEnabled")
        try store.synchronize()

        let manager = AppDimmingManager(store: store)
        #expect(manager.effect == .dimming)
        #expect(!manager.needsScreenRecording)
    }

    @Test func transparencyReportsCurrentPermissionWithoutRequestingIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OmniKitStore(fileURL: root.appendingPathComponent("config.plist"))
        store.set("transparency", forKey: "omnikit.appDimming.effect")
        store.set(try JSONEncoder().encode([
            AppDimmingRule(bundleID: "test.omnikit.not-running", name: "Not Running", strength: 50)
        ]), forKey: "omnikit.appDimming.rules")
        try store.synchronize()

        let permissionBefore = CGPreflightScreenCaptureAccess()
        let windowsBefore = visibleWindowCountOwnedByTestProcess()
        let manager = AppDimmingManager(store: store)
        #expect(manager.needsScreenRecording == !permissionBefore)
        #expect(manager.transparencyStatus.isEmpty)
        manager.checkScreenRecordingPermission()
        try await Task.sleep(for: .milliseconds(400))
        #expect(manager.needsScreenRecording == !permissionBefore)
        #expect(manager.transparencyStatus.isEmpty)
        #expect(CGPreflightScreenCaptureAccess() == permissionBefore)
        if !permissionBefore {
            #expect(visibleWindowCountOwnedByTestProcess() == windowsBefore)
        }
        manager.isEnabled = false
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OmniKit-AppTransparency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func visibleWindowCountOwnedByTestProcess() -> Int {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return windows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }.count
    }
}
