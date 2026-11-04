//
//  OmniKitTests.swift
//  OmniKitTests
//
//  Created by lincunhao on 2026/4/14.
//

import Testing
import AppKit
import AVFoundation
import ImageIO
import Speech
import Security
@testable import OmniKit

@MainActor
@Suite(.serialized)
struct OmniKitTests {

    @Test func storePersistsUpdatesAndReportsCorruption() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.plist")
        let store = OmniKitStore(fileURL: url)
        store.set("first", forKey: "value")
        try store.synchronize()
        store.set("second", forKey: "value")
        try store.synchronize()
        #expect(OmniKitStore(fileURL: url).string(forKey: "value") == "second")

        let corruptURL = root.appendingPathComponent("corrupt.plist")
        let original = Data("invalid plist".utf8)
        try original.write(to: corruptURL)
        let corrupt = OmniKitStore(fileURL: corruptURL)
        corrupt.set("replacement", forKey: "value")
        #expect(throws: (any Error).self) { try corrupt.synchronize() }
        #expect(try Data(contentsOf: corruptURL) == original)
    }

    @Test func migrationPreservesUnrelatedFilesAndExistingValues() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OmniKit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy", forKey: "format.conflict")
        defaults.set("imported", forKey: "ocr.test")
        let legacyURL = root.appendingPathComponent("Containers/\(suite)/Data/Library/Preferences/\(suite).plist")
        try writePlist(["translation.test": "legacy-key", "unrelated": "keep"], to: legacyURL)
        let audioURL = legacyURL.deletingLastPathComponent().appendingPathComponent("recording.caf")
        try Data("audio".utf8).write(to: audioURL)
        let store = OmniKitStore(fileURL: root.appendingPathComponent("new/config.plist"))
        store.set("current", forKey: "format.conflict")
        try store.synchronize()

        #expect(PreferencesMigrator.migrateIfNeeded(bundleID: suite, store: store, defaults: defaults, libraryURL: root))
        #expect(store.string(forKey: "format.conflict") == "current")
        #expect(store.string(forKey: "translation.test") == "legacy-key")
        #expect(store.string(forKey: "ocr.test") == "imported")
        #expect(defaults.string(forKey: "ocr.test") == nil)
        #expect(defaults.string(forKey: "format.conflict") == "legacy")
        let remaining = try PropertyListSerialization.propertyList(from: Data(contentsOf: legacyURL), format: nil) as? [String: String]
        #expect(remaining == ["unrelated": "keep"])
        #expect(try Data(contentsOf: audioURL) == Data("audio".utf8))
    }

    @Test func migrationFailureKeepsLegacyData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OmniKit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "ocr.test")
        let legacyURL = root.appendingPathComponent("Containers/\(suite)/Data/Library/Preferences/\(suite).plist")
        try writePlist(["translation.test": "keep"], to: legacyURL)
        let original = try Data(contentsOf: legacyURL)
        let blockedURL = root.appendingPathComponent("blocked.plist")
        let store = OmniKitStore(fileURL: blockedURL)
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)

        #expect(!PreferencesMigrator.migrateIfNeeded(bundleID: suite, store: store, defaults: defaults, libraryURL: root))
        #expect(defaults.string(forKey: "ocr.test") == "keep")
        #expect(try Data(contentsOf: legacyURL) == original)
        #expect(!store.bool(forKey: "omnikit.migration.unifiedDataDir.v2"))
    }

    @Test func encodingPreservesWhitespace() {
        let model = FormatPanelViewModel()
        for original in ["  hello\n", "\t \n", "  你好😀\t\n"] {
            model.selectedType = .encrypt
            model.selectedCryptoAlgorithm = .base64
            model.inputText = original
            model.runConversion()
            #expect(model.outputText == Data(original.utf8).base64EncodedString())
            model.inputText = " \n" + model.outputText + "\n "
            model.selectedType = .decrypt
            model.runConversion()
            #expect(model.outputText == original)
        }
    }

    @Test func credentialsMigrateBeforeRemovingLegacyValue() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "omnikit.test.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.lch.OmniKit",
            kSecAttrAccount as String: key
        ]
        defer { SecItemDelete(query as CFDictionary) }
        let url = root.appendingPathComponent("config.plist")
        let store = OmniKitStore(fileURL: url)
        store.set("test-secret", forKey: key)
        try store.synchronize()
        let migrated = CredentialStore.load(forKey: key, store: store)
        #expect(migrated.error == nil)
        #expect(migrated.value == "test-secret")
        #expect(OmniKitStore(fileURL: url).string(forKey: key) == nil)
        #expect(CredentialStore.load(forKey: key, store: store).value == "test-secret")
        try CredentialStore.save("updated-test-secret", forKey: key, store: store)
        #expect(CredentialStore.load(forKey: key, store: store).value == "updated-test-secret")
        try CredentialStore.save("", forKey: key, store: store)
        #expect(CredentialStore.load(forKey: key, store: store).value.isEmpty)
    }

    @Test func pasteboardSnapshotPreservesAllItemsAndTypes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("file:///tmp/omnikit-test.txt", forType: .fileURL)
        #expect(pasteboard.writeObjects([first, second]))
        let snapshot = try #require(TranslatorPanelManager.snapshotItems(from: pasteboard))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(snapshot))
        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "original")
        #expect(items[0].data(forType: .rtf) == Data([1, 2, 3]))
        #expect(items[1].string(forType: .fileURL) == "file:///tmp/omnikit-test.txt")
    }

    @Test func diffPreservesResultsAndNormalizesOnlyWhenRequested() async throws {
        let rows = try await TextDiffPanelViewModel.calculateDiff(left: "alpha\nold\nomega", right: "alpha\nnew\nomega", ignoreWhitespace: false, ignoreCase: false)
        #expect(rows.map(\.kind) == [.equal, .modified, .equal])
        #expect(rows[1].leftText == "old")
        #expect(rows[1].rightText == "new")
        let normalized = try await TextDiffPanelViewModel.calculateDiff(left: "  Hello   WORLD \n", right: "hello world\n", ignoreWhitespace: true, ignoreCase: true)
        #expect(normalized.allSatisfy { $0.kind == .equal })
        let added = try await TextDiffPanelViewModel.calculateDiff(left: "", right: "new", ignoreWhitespace: false, ignoreCase: false)
        #expect(added.map(\.kind) == [.added])
    }

    @Test func diffRejectsOversizedInputsAndHonorsCancellation() async throws {
        let large = String(repeating: "line\n", count: 2000)
        await #expect(throws: (any Error).self) {
            try await TextDiffPanelViewModel.calculateDiff(left: large, right: large, ignoreWhitespace: false, ignoreCase: false)
        }
        let task = Task {
            try await TextDiffPanelViewModel.calculateDiff(left: "a", right: "b", ignoreWhitespace: false, ignoreCase: false)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func clipboardPreservesOriginalTextAndBuildsSearchIndex() async throws {
        let original = "  中国 hello\t\n"
        let entry = try #require(await ClipboardPanelManager.makeHistoryEntry(from: .text(original), copiedAt: Date()))
        #expect(entry.fullText == original)
        #expect(entry.transliteratedBlob.contains("zhongguo"))
        #expect(entry.byteCount > original.utf8.count)
    }

    @Test func clipboardEvictsOldUnpinnedEntriesWithinBudget() async throws {
        let model = ClipboardPanelViewModel()
        var ids: [UUID] = []
        for index in 0..<10 {
            var entry = try #require(await ClipboardPanelManager.makeHistoryEntry(from: .text("entry \(index)"), copiedAt: Date()))
            entry.byteCount = ClipboardPanelViewModel.maximumEntryBytes
            ids.append(entry.id)
            model.ingest(entry)
            if index == 0 { model.togglePinned(entry.id) }
        }
        var incoming = try #require(await ClipboardPanelManager.makeHistoryEntry(from: .text("new"), copiedAt: Date()))
        incoming.byteCount = ClipboardPanelViewModel.maximumEntryBytes
        model.ingest(incoming)
        #expect(model.entries.count == 10)
        #expect(model.entries.contains { $0.id == ids[0] && $0.isPinned })
        #expect(!model.entries.contains { $0.id == ids[1] })
        #expect(model.entries.contains { $0.id == incoming.id })
        #expect(model.entries.reduce(0) { $0 + $1.byteCount } <= ClipboardPanelViewModel.maximumHistoryBytes)
    }

    @Test func clipboardRejectsNewEntryWhenPinnedBudgetIsFull() async throws {
        let model = ClipboardPanelViewModel()
        for index in 0..<10 {
            var entry = try #require(await ClipboardPanelManager.makeHistoryEntry(from: .text("pinned \(index)"), copiedAt: Date()))
            entry.byteCount = ClipboardPanelViewModel.maximumEntryBytes
            entry.isPinned = true
            model.ingest(entry)
        }
        let original = model.entries
        var incoming = try #require(await ClipboardPanelManager.makeHistoryEntry(from: .text("new"), copiedAt: Date()))
        model.ingest(incoming)
        #expect(model.entries == original)
        #expect(model.statusMessage.contains("固定内容"))
        incoming.byteCount = ClipboardPanelViewModel.maximumEntryBytes + 1
        model.ingest(incoming)
        #expect(model.entries == original)
        #expect(model.statusMessage.contains("10 MiB"))
    }

    @Test func imageProcessingPreservesDimensionsAndFlipsPixels() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 1, y: 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let flipped = try await ImagePanelViewModel.processImage(data: data, tool: .flip, sourceFormat: .png, quality: 0.72, outputFormat: .png, direction: .horizontal)
        let result = try #require(NSBitmapImageRep(data: flipped.data))
        #expect(result.pixelsWide == 2 && result.pixelsHigh == 1)
        #expect(try #require(result.colorAt(x: 0, y: 0)).blueComponent > 0.9)
        #expect(try #require(result.colorAt(x: 1, y: 0)).redComponent > 0.9)
        let converted = try await ImagePanelViewModel.processImage(data: data, tool: .formatConvert, sourceFormat: .png, quality: 0.72, outputFormat: .jpeg, direction: .horizontal)
        let source = try #require(CGImageSourceCreateWithData(converted.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    @Test func audioSessionStopsFeedingEndedRequests() throws {
        let session = RecognitionAudioSession()
        let request = SpeechRequestSpy()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        session.add(request, for: "zh")
        session.append(buffer)
        session.endAudio()
        session.append(buffer)
        session.endAudio()
        #expect(request.appendCount == 1)
        #expect(request.endCount == 1)
    }

    @Test func menuBarFoldingUsesExactSelections() {
        let separator = menuBarItem(10, bundleID: "omnikit", title: "separator", x: 300)
        let marked = menuBarItem(1, bundleID: "app.one", title: "Item-0", x: 250)
        let newApp = menuBarItem(2, bundleID: "app.new", title: "Item-0", x: 220)
        let secondIcon = menuBarItem(3, bundleID: "app.one", title: "Item-1", x: 190)
        let selections: Set<String> = ["app.one#Item-0"]
        #expect(marked.isCorrectlyPlaced(relativeTo: separator, selections: selections))
        #expect(!newApp.isStashed(in: selections))
        #expect(!newApp.isCorrectlyPlaced(relativeTo: separator, selections: selections))
        #expect(!secondIcon.isStashed(in: selections))
        #expect(!secondIcon.isCorrectlyPlaced(relativeTo: separator, selections: selections))
        // 取消标记后，即使位置仍在左侧，也必须先移回可见区。
        #expect(!marked.isCorrectlyPlaced(relativeTo: separator, selections: []))
        let visible = menuBarItem(2, bundleID: "app.new", title: "Item-0", x: 330)
        #expect(visible.isCorrectlyPlaced(relativeTo: separator, selections: selections))
    }

    @Test func menuBarLegacySelectionDoesNotIncludeAdditionalIcons() {
        let first = menuBarItem(1, bundleID: "app.one", title: "Item-0", x: 100)
        let second = menuBarItem(2, bundleID: "app.one", title: "Item-1", x: 130)
        let old: Set<String> = ["app.one#__runtime__", "app.offline#__runtime__"]
        let migrated = MenuBarStatusItem.migrateLegacySelections(old, items: [first])
        #expect(migrated == ["app.one#Item-0", "app.offline#__runtime__"])
        #expect(first.isStashed(in: migrated))
        #expect(!second.isStashed(in: migrated))
        let ambiguous = MenuBarStatusItem.migrateLegacySelections(old, items: [first, second])
        #expect(ambiguous == old)
        #expect(!first.isStashed(in: ambiguous))
        #expect(!second.isStashed(in: ambiguous))
    }

    @Test func menuBarUnknownAndOverlappingItemsPreventCollapse() {
        let separator = menuBarItem(10, bundleID: "omnikit", title: "separator", x: 300)
        let unknown = menuBarItem(1, bundleID: nil, title: "", x: 250)
        #expect(!unknown.isStashed(in: ["app.one#__runtime__"]))
        #expect(!unknown.isCorrectlyPlaced(relativeTo: separator, selections: []))
        let overlapping = menuBarItem(2, bundleID: "app.one", title: "Item-0", x: 290)
        #expect(!overlapping.isCorrectlyPlaced(relativeTo: separator, selections: []))
        #expect(!overlapping.isCorrectlyPlaced(relativeTo: separator, selections: ["app.one#Item-0"]))
        let duplicate = menuBarItem(3, bundleID: "app.one", title: "Item-0", x: 200)
        #expect(MenuBarStatusItem.unambiguousSelections(["app.one#Item-0"], items: [overlapping, duplicate]).isEmpty)
        #expect(MenuBarStatusItem.unambiguousSelections(["app.one#Item-0"], items: [overlapping]) == ["app.one#Item-0"])
    }

    private func menuBarItem(_ id: CGWindowID, bundleID: String?, title: String, x: CGFloat) -> MenuBarStatusItem {
        MenuBarStatusItem(windowID: id, ownerPID: 1, bundleID: bundleID, title: title, frame: CGRect(x: x, y: 0, width: 24, height: 24), isOnScreen: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OmniKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: url)
    }

}

private nonisolated final class SpeechRequestSpy: SFSpeechAudioBufferRecognitionRequest {
    var appendCount = 0
    var endCount = 0

    override func append(_ audioPCMBuffer: AVAudioPCMBuffer) { appendCount += 1 }
    override func endAudio() { endCount += 1 }
}
