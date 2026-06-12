//
//  TextDiffSettingsStore.swift
//  OmniKit
//

import Carbon
import Combine
import Foundation

@MainActor
final class TextDiffSettingsStore: ObservableObject {
    @Published var textDiffShortcut: ShortcutCombination {
        didSet {
            persistShortcut(textDiffShortcut, key: Self.textDiffShortcutDefaultsKey)
        }
    }

    private static let textDiffShortcutDefaultsKey = "textDiff.shortcut.toggle"

    init() {
        textDiffShortcut = Self.loadShortcut(key: Self.textDiffShortcutDefaultsKey) ?? .defaultTextDiff
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
    static let defaultTextDiff = ShortcutCombination(
        keyCode: 2, // D
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}
