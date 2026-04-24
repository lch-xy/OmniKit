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

    private static let ocrShortcutDefaultsKey = "ocr.shortcut.capture"

    init() {
        ocrShortcut = Self.loadShortcut(key: Self.ocrShortcutDefaultsKey) ?? .defaultOCR
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
