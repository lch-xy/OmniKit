//
//  OmniKitApp.swift
//  OmniKit
//
//  Created by lincunhao on 2026/4/14.
//

import SwiftUI

@main
struct OmniKitApp: App {
    @StateObject private var translationSettings = TranslationSettingsStore()
    @StateObject private var ocrSettings = OCRSettingsStore()
    @StateObject private var formatSettings = FormatSettingsStore()
    @StateObject private var textDiffSettings = TextDiffSettingsStore()
    @StateObject private var imageSettings = ImageSettingsStore()
    @StateObject private var clipboardSettings = ClipboardSettingsStore()
    @StateObject private var translatorPanelManager: TranslatorPanelManager
    @StateObject private var ocrManager: OCRManager
    @StateObject private var meetingManager = MeetingManager()
    @StateObject private var formatPanelManager: FormatPanelManager
    @StateObject private var textDiffPanelManager: TextDiffPanelManager
    @StateObject private var imagePanelManager: ImagePanelManager
    @StateObject private var clipboardPanelManager: ClipboardPanelManager
    @StateObject private var batteryManager = BatteryManager()
    @StateObject private var appDimmingManager = AppDimmingManager()
    @StateObject private var menuBarIconManager: MenuBarIconManager
    @StateObject private var menuBarFolder: MenuBarFolderController

    init() {
        OmniKitDataLocation.ensureDirectoriesExist()
        PreferencesMigrator.migrateIfNeeded()
        let menuBarIconManager = MenuBarIconManager()
        _menuBarIconManager = StateObject(wrappedValue: menuBarIconManager)
        _menuBarFolder = StateObject(wrappedValue: MenuBarFolderController(iconManager: menuBarIconManager))
        let translationSettings = TranslationSettingsStore()
        let ocrSettings = OCRSettingsStore()
        let formatSettings = FormatSettingsStore()
        let textDiffSettings = TextDiffSettingsStore()
        let imageSettings = ImageSettingsStore()
        let clipboardSettings = ClipboardSettingsStore()
        _translationSettings = StateObject(wrappedValue: translationSettings)
        _ocrSettings = StateObject(wrappedValue: ocrSettings)
        _formatSettings = StateObject(wrappedValue: formatSettings)
        _textDiffSettings = StateObject(wrappedValue: textDiffSettings)
        _imageSettings = StateObject(wrappedValue: imageSettings)
        _clipboardSettings = StateObject(wrappedValue: clipboardSettings)
        _translatorPanelManager = StateObject(wrappedValue: TranslatorPanelManager(settings: translationSettings))
        _ocrManager = StateObject(wrappedValue: OCRManager(settings: ocrSettings))
        _formatPanelManager = StateObject(wrappedValue: FormatPanelManager(settings: formatSettings))
        _textDiffPanelManager = StateObject(wrappedValue: TextDiffPanelManager(settings: textDiffSettings))
        _imagePanelManager = StateObject(wrappedValue: ImagePanelManager(settings: imageSettings))
        _clipboardPanelManager = StateObject(wrappedValue: ClipboardPanelManager(settings: clipboardSettings))
    }

    var body: some Scene {
        Window("OmniKit", id: OmniKitSceneID.mainWindow) {
            ContentView()
                .environmentObject(translationSettings)
                .environmentObject(translatorPanelManager)
                .environmentObject(ocrSettings)
                .environmentObject(ocrManager)
                .environmentObject(meetingManager)
                .environmentObject(formatSettings)
                .environmentObject(formatPanelManager)
                .environmentObject(textDiffSettings)
                .environmentObject(textDiffPanelManager)
                .environmentObject(imageSettings)
                .environmentObject(imagePanelManager)
                .environmentObject(clipboardSettings)
                .environmentObject(clipboardPanelManager)
                .environmentObject(batteryManager)
                .environmentObject(menuBarIconManager)
                .environmentObject(menuBarFolder)
                .environmentObject(appDimmingManager)
        }
        MenuBarExtra {
            MenuBarControlView()
                .environmentObject(translatorPanelManager)
                .environmentObject(ocrManager)
                .environmentObject(meetingManager)
                .environmentObject(formatPanelManager)
                .environmentObject(textDiffPanelManager)
                .environmentObject(imagePanelManager)
                .environmentObject(clipboardPanelManager)
                .environmentObject(batteryManager)
        } label: {
            // 默认使用 cube.transparent (3D透视魔方)，极客且契合 Kit (工具箱) 概念
            Label("OmniKit", systemImage: meetingManager.isRecording ? "record.circle.fill" : "cube.transparent")
                .labelStyle(.iconOnly)
        }
    }
}
