//
//  ImageSettingsStore.swift
//  OmniKit
//

import Carbon
import Combine
import Foundation

@MainActor
final class ImageSettingsStore: ObservableObject {
    @Published var imageShortcut: ShortcutCombination {
        didSet {
            persistShortcut(imageShortcut, key: Self.imageShortcutDefaultsKey)
        }
    }

    private static let imageShortcutDefaultsKey = "image.shortcut.toggle"

    init() {
        imageShortcut = Self.loadShortcut(key: Self.imageShortcutDefaultsKey) ?? .defaultImage
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
    static let defaultImage = ShortcutCombination(
        keyCode: 34, // I
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}
