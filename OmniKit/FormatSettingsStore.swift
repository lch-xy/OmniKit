//
//  FormatSettingsStore.swift
//  OmniKit
//

import Carbon
import Combine
import Foundation

@MainActor
final class FormatSettingsStore: ObservableObject {
    @Published var formatShortcut: ShortcutCombination {
        didSet {
            persistShortcut(formatShortcut, key: Self.formatShortcutDefaultsKey)
        }
    }

    private static let formatShortcutDefaultsKey = "format.shortcut.toggle"

    init() {
        formatShortcut = Self.loadShortcut(key: Self.formatShortcutDefaultsKey) ?? .defaultFormat
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
    static let defaultFormat = ShortcutCombination(
        keyCode: 38, // J
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )
}
