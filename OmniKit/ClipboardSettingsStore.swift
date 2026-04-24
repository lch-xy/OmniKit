//
//  ClipboardSettingsStore.swift
//  OmniKit
//

import Carbon
import Combine
import Foundation

@MainActor
final class ClipboardSettingsStore: ObservableObject {
    @Published var clipboardShortcut: ShortcutCombination {
        didSet {
            persistShortcut(clipboardShortcut, key: Self.clipboardShortcutDefaultsKey)
        }
    }

    private static let clipboardShortcutDefaultsKey = "clipboard.shortcut.toggle"

    init() {
        clipboardShortcut = Self.loadShortcut(key: Self.clipboardShortcutDefaultsKey) ?? .defaultClipboard
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
    static let defaultClipboard = ShortcutCombination(
        keyCode: 9, // V
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}
