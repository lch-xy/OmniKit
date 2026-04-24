//
//  TranslationSettingsStore.swift
//  OmniKit
//
//  Created by lincunhao on 2026/4/14.
//

import Carbon
import Combine
import AppKit
import Foundation

struct ShortcutCombination: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    var displayName: String {
        let symbols = keySymbol(for: keyCode)
        return "\(modifierSymbols(carbonModifiers))\(symbols)"
    }

    static let defaultInput = ShortcutCombination(
        keyCode: 17, // T
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    static let defaultSelection = ShortcutCombination(
        keyCode: 17, // T
        carbonModifiers: UInt32(controlKey | optionKey | shiftKey)
    )

    static let legacyDefaultInput = ShortcutCombination(
        keyCode: 17, // T
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let legacyDefaultSelection = ShortcutCombination(
        keyCode: 8, // C
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    static func from(event: NSEvent) -> ShortcutCombination? {
        guard event.type == .keyDown else { return nil }
        let mapped = carbonModifiers(from: event.modifierFlags)
        guard mapped != 0 else { return nil }
        return ShortcutCombination(keyCode: UInt32(event.keyCode), carbonModifiers: mapped)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func modifierSymbols(_ modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "^" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    private func keySymbol(for code: UInt32) -> String {
        switch code {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        default:
            if let scalar = keyCodeToCharacter(code) {
                return scalar.uppercased()
            }
            return "Key\(code)"
        }
    }

    private func keyCodeToCharacter(_ code: UInt32) -> String? {
        let map: [UInt32: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
            38: "j", 40: "k", 45: "n", 46: "m"
        ]
        return map[code]
    }
}

enum TranslationAPIVersion: String, CaseIterable, Identifiable {
    case v20181012 = "2018-10-12"

    var id: String { rawValue }
    var title: String { rawValue }
}

enum TranslationFormatType: String, CaseIterable, Identifiable {
    case text
    case html

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

@MainActor
final class TranslationSettingsStore: ObservableObject {
    @Published var accessKeyId: String {
        didSet {
            OmniKitStore.shared.set(accessKeyId, forKey: Self.accessKeyIdDefaultsKey)
        }
    }

    @Published var accessKeySecret: String {
        didSet {
            OmniKitStore.shared.set(accessKeySecret, forKey: Self.accessKeySecretDefaultsKey)
        }
    }

    @Published var inputTranslationShortcut: ShortcutCombination {
        didSet {
            persistShortcut(inputTranslationShortcut, key: Self.inputShortcutDefaultsKey)
        }
    }

    @Published var selectionTranslationShortcut: ShortcutCombination {
        didSet {
            persistShortcut(selectionTranslationShortcut, key: Self.selectionShortcutDefaultsKey)
        }
    }

    @Published var apiVersion: TranslationAPIVersion {
        didSet {
            OmniKitStore.shared.set(apiVersion.rawValue, forKey: Self.apiVersionDefaultsKey)
        }
    }

    @Published var formatType: TranslationFormatType {
        didSet {
            OmniKitStore.shared.set(formatType.rawValue, forKey: Self.formatTypeDefaultsKey)
        }
    }

    private static let accessKeyIdDefaultsKey = "translation.alibaba.accessKeyId"
    private static let accessKeySecretDefaultsKey = "translation.alibaba.accessKeySecret"
    private static let inputShortcutDefaultsKey = "translation.alibaba.shortcut.input"
    private static let selectionShortcutDefaultsKey = "translation.alibaba.shortcut.selection"
    private static let apiVersionDefaultsKey = "translation.alibaba.apiVersion"
    private static let formatTypeDefaultsKey = "translation.alibaba.formatType"

    init() {
        accessKeyId = OmniKitStore.shared.string(forKey: Self.accessKeyIdDefaultsKey) ?? ""
        accessKeySecret = OmniKitStore.shared.string(forKey: Self.accessKeySecretDefaultsKey) ?? ""
        let storedInputShortcut = Self.loadShortcut(key: Self.inputShortcutDefaultsKey)
        let storedSelectionShortcut = Self.loadShortcut(key: Self.selectionShortcutDefaultsKey)
        inputTranslationShortcut = storedInputShortcut == .legacyDefaultInput ? .defaultInput : (storedInputShortcut ?? .defaultInput)
        selectionTranslationShortcut = storedSelectionShortcut == .legacyDefaultSelection ? .defaultSelection : (storedSelectionShortcut ?? .defaultSelection)
        let apiVersionRaw = OmniKitStore.shared.string(forKey: Self.apiVersionDefaultsKey)
        apiVersion = TranslationAPIVersion(rawValue: apiVersionRaw ?? "") ?? .v20181012
        let formatTypeRaw = OmniKitStore.shared.string(forKey: Self.formatTypeDefaultsKey)
        formatType = TranslationFormatType(rawValue: formatTypeRaw ?? "") ?? .text

        if storedInputShortcut == .legacyDefaultInput {
            persistShortcut(inputTranslationShortcut, key: Self.inputShortcutDefaultsKey)
        }
        if storedSelectionShortcut == .legacyDefaultSelection {
            persistShortcut(selectionTranslationShortcut, key: Self.selectionShortcutDefaultsKey)
        }
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
