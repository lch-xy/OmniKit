//
//  HotKeyManager.swift
//  OmniKit
//
//  Created by lincunhao on 2026/4/14.
//

import Carbon
import Foundation

final class HotKeyManager {
    private static let registry = SharedHotKeyRegistry()
    private static var sharedEventHandlerRef: EventHandlerRef?

    private var registeredHotKeyIDs: Set<UInt32> = []

    func register(shortcuts: [UInt32: ShortcutCombination], onPressed: @escaping (UInt32) -> Void) {
        unregister()
        installSharedHandlerIfNeeded()

        for (id, shortcut) in shortcuts {
            let hotKeyID = EventHotKeyID(signature: fourCharCode("OMKT"), id: id)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                HotKeyManager.registry.hotKeyRefs[id] = hotKeyRef
                HotKeyManager.registry.handlers[id] = { onPressed(id) }
                registeredHotKeyIDs.insert(id)
            }
        }
    }

    func unregister() {
        for id in registeredHotKeyIDs {
            if let hotKeyRef = HotKeyManager.registry.hotKeyRefs[id] {
                UnregisterEventHotKey(hotKeyRef)
                HotKeyManager.registry.hotKeyRefs[id] = nil
            }
            HotKeyManager.registry.handlers[id] = nil
        }
        registeredHotKeyIDs.removeAll()

        if HotKeyManager.registry.hotKeyRefs.isEmpty,
           let eventHandlerRef = HotKeyManager.sharedEventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            HotKeyManager.sharedEventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }

    private func installSharedHandlerIfNeeded() {
        guard HotKeyManager.sharedEventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(HotKeyManager.registry).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let registry = Unmanaged<SharedHotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr, let handler = registry.handlers[hotKeyID.id] {
                    handler()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &HotKeyManager.sharedEventHandlerRef
        )
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

private final class SharedHotKeyRegistry {
    var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    var handlers: [UInt32: () -> Void] = [:]
}
