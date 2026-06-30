//
//  OCRSettingsStore.swift
//  OmniKit
//
//  Created by Codex on 2026/4/14.
//

import Combine
import Carbon
import Foundation

@MainActor
final class OCRSettingsStore: ObservableObject {
    @Published var ocrShortcut: ShortcutCombination {
        didSet {
            persistShortcut(ocrShortcut, key: Self.ocrShortcutDefaultsKey)
        }
    }

    @Published var shouldPreviewResult: Bool {
        didSet {
            OmniKitStore.shared.set(shouldPreviewResult, forKey: Self.previewResultDefaultsKey)
        }
    }

    private static let ocrShortcutDefaultsKey = "ocr.shortcut.capture"
    private static let previewResultDefaultsKey = "ocr.result.preview"

    init() {
        ocrShortcut = Self.loadShortcut(key: Self.ocrShortcutDefaultsKey) ?? .defaultOCR
        shouldPreviewResult = OmniKitStore.shared.object(forKey: Self.previewResultDefaultsKey) as? Bool ?? true
    }

    private static func loadShortcut(key: String) -> ShortcutCombination? {
        guard let data = OmniKitStore.shared.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShortcutCombination.self, from: data)
    }

    private func persistShortcut(_ shortcut: ShortcutCombination, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            OmniKitStore.shared.set(data, forKey: key)
        }
    }
}

private extension ShortcutCombination {
    static let defaultOCR = ShortcutCombination(
        keyCode: 15, // R
        carbonModifiers: UInt32(cmdKey | optionKey)
    )
}
