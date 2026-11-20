import AppKit
import Testing
@testable import OmniKit

@MainActor
@Suite(.serialized)
struct AppDimmingTests {
    @Test func addingApplicationUsesBundleIdentityAndPersistsDefaultStrength() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OmniKitStore(fileURL: root.appendingPathComponent("config.plist"))
        let manager = AppDimmingManager(store: store)
        manager.isEnabled = false
        let appURL = try makeApplication(in: root, bundleID: "test.omnikit.dimming", name: "Dimming Test App")

        #expect(manager.addApplication(at: appURL))
        #expect(manager.rules.count == 1)
        #expect(manager.rules[0].bundleID == "test.omnikit.dimming")
        #expect(manager.rules[0].name == "Dimming Test App")
        #expect(manager.rules[0].strength == 50)
        #expect(!manager.addApplication(at: appURL))

        try store.synchronize()
        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: storeURL(in: root)))
        #expect(reloaded.rules.count == 1)
        #expect(reloaded.rules[0].bundleID == manager.rules[0].bundleID)
        #expect(reloaded.rules[0].name == manager.rules[0].name)
        #expect(reloaded.rules[0].strength == manager.rules[0].strength)
        #expect(!reloaded.isEnabled)
        reloaded.isEnabled = false
    }

    @Test func strengthIsClampedAndPersisted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OmniKitStore(fileURL: root.appendingPathComponent("config.plist"))
        let manager = AppDimmingManager(store: store)
        manager.isEnabled = false
        let appURL = try makeApplication(in: root, bundleID: "test.omnikit.range", name: "Range Test App")
        #expect(manager.addApplication(at: appURL))

        manager.setStrength(-1, for: "test.omnikit.range")
        #expect(manager.rules[0].strength == 0)
        manager.setStrength(101, for: "test.omnikit.range")
        #expect(manager.rules[0].strength == 100)
        manager.setStrength(37, for: "test.omnikit.range")
        manager.setStrength(80, for: "test.omnikit.missing")
        #expect(manager.rules[0].strength == 37)

        try store.synchronize()
        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: storeURL(in: root)))
        #expect(reloaded.rules[0].strength == 37)
        reloaded.isEnabled = false
    }

    @Test func removingApplicationPersistsAndGlobalSwitchPersists() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = storeURL(in: root)
        let store = OmniKitStore(fileURL: configURL)
        let manager = AppDimmingManager(store: store)
        manager.isEnabled = false
        let appURL = try makeApplication(in: root, bundleID: "test.omnikit.remove", name: "Remove Test App")
        #expect(manager.addApplication(at: appURL))
        manager.removeApplication("test.omnikit.remove")
        #expect(manager.rules.isEmpty)
        manager.isEnabled = true
        try store.synchronize()

        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: configURL))
        #expect(reloaded.rules.isEmpty)
        #expect(reloaded.isEnabled)
        reloaded.isEnabled = false
    }

    @Test func legacyConfigurationDefaultsMaskToWhiteAndPreservesRulesAndEffect() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = storeURL(in: root)
        let store = OmniKitStore(fileURL: configURL)
        let legacyRule = AppDimmingRule(bundleID: "test.omnikit.legacy-color", name: "Legacy Color App", strength: 37)
        store.set(try JSONEncoder().encode([legacyRule]), forKey: "omnikit.appDimming.rules")
        store.set(AppDisplayEffect.transparency.rawValue, forKey: "omnikit.appDimming.effect")
        store.set(false, forKey: "omnikit.appDimming.isEnabled")
        try store.synchronize()

        let manager = AppDimmingManager(store: store)
        #expect(manager.maskColor == .white)
        #expect(manager.rules.count == 1)
        #expect(manager.rules[0].bundleID == legacyRule.bundleID)
        #expect(manager.rules[0].strength == 37)
        #expect(manager.effect == .transparency)
        manager.maskColor = AppDimmingColor(red: 23, green: 117, blue: 209)
        #expect(manager.rules[0].strength == 37)
        #expect(manager.effect == .transparency)

        try store.synchronize()
        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: configURL))
        #expect(reloaded.maskColor == AppDimmingColor(red: 23, green: 117, blue: 209))
        #expect(reloaded.rules[0].strength == 37)
        #expect(reloaded.effect == .transparency)
        manager.isEnabled = false
        reloaded.isEnabled = false
    }

    @Test func customSRGBColorRoundTripsThroughManagerAndStore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = storeURL(in: root)
        let store = OmniKitStore(fileURL: configURL)
        let manager = AppDimmingManager(store: store)
        manager.isEnabled = false
        let appURL = try makeApplication(in: root, bundleID: "test.omnikit.color", name: "Color Test App")
        #expect(manager.addApplication(at: appURL))

        let rgb = AppDimmingColor(red: 23, green: 117, blue: 209)
        let bridged = try #require(AppDimmingColor(nsColor: rgb.nsColor))
        #expect(bridged == rgb)
        let srgb = try #require(rgb.nsColor.usingColorSpace(.sRGB))
        #expect(Int((srgb.redComponent * 255).rounded()) == 23)
        #expect(Int((srgb.greenComponent * 255).rounded()) == 117)
        #expect(Int((srgb.blueComponent * 255).rounded()) == 209)

        let originalRules = manager.rules
        let originalEffect = manager.effect
        manager.maskColor = rgb
        #expect(manager.rules.count == originalRules.count)
        #expect(manager.rules[0].bundleID == originalRules[0].bundleID)
        #expect(manager.rules[0].strength == originalRules[0].strength)
        #expect(manager.effect == originalEffect)
        try store.synchronize()

        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: configURL))
        #expect(reloaded.maskColor == rgb)
        #expect(reloaded.rules.count == originalRules.count)
        #expect(reloaded.rules[0].bundleID == originalRules[0].bundleID)
        #expect(reloaded.rules[0].strength == originalRules[0].strength)
        #expect(reloaded.effect == originalEffect)
        reloaded.isEnabled = false
    }

    @Test func maskColorPersistsAcrossTransparencyModeChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = storeURL(in: root)
        let store = OmniKitStore(fileURL: configURL)
        let manager = AppDimmingManager(store: store)
        manager.isEnabled = false
        let color = AppDimmingColor(red: 23, green: 117, blue: 209)

        manager.maskColor = color
        manager.effect = .transparency
        #expect(manager.maskColor == color)
        manager.effect = .dimming
        #expect(manager.maskColor == color)
        try store.synchronize()

        let reloaded = AppDimmingManager(store: OmniKitStore(fileURL: configURL))
        #expect(reloaded.maskColor == color)
        #expect(reloaded.effect == .dimming)
        reloaded.isEnabled = false
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OmniKit-AppDimming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplication(in root: URL, bundleID: String, name: String) throws -> URL {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func storeURL(in root: URL) -> URL {
        root.appendingPathComponent("config.plist")
    }
}
