//
//  ContentView.swift
//  OmniKit
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var translationSettings: TranslationSettingsStore
    @EnvironmentObject private var translatorPanelManager: TranslatorPanelManager
    @EnvironmentObject private var ocrSettings: OCRSettingsStore
    @EnvironmentObject private var ocrManager: OCRManager
    @EnvironmentObject private var meetingManager: MeetingManager
    @EnvironmentObject private var formatSettings: FormatSettingsStore
    @EnvironmentObject private var formatPanelManager: FormatPanelManager
    @EnvironmentObject private var imageSettings: ImageSettingsStore
    @EnvironmentObject private var imagePanelManager: ImagePanelManager
    @EnvironmentObject private var clipboardSettings: ClipboardSettingsStore
    @EnvironmentObject private var clipboardPanelManager: ClipboardPanelManager
    @EnvironmentObject private var batteryManager: BatteryManager
    @EnvironmentObject private var menuBarIconManager: MenuBarIconManager
    @EnvironmentObject private var menuBarFolder: MenuBarFolderController

    @State private var selectedModule: SettingsModule? = .translation

    var body: some View {
        NavigationSplitView {
            List(SettingsModule.allCases, selection: $selectedModule) { module in
                NavigationLink(value: module) {
                    Label(module.title, systemImage: module.icon)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
            
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                sidebarFooter
            }
        } detail: {
            if let module = selectedModule {
                detailView(for: module)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text("选择一个模块开始")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private func detailView(for module: SettingsModule) -> some View {
        switch module {
        case .translation:
            TranslationConfigView()
                .environmentObject(translationSettings)
                .environmentObject(translatorPanelManager)
        case .ocr:
            OCRConfigView()
                .environmentObject(ocrSettings)
                .environmentObject(ocrManager)
        case .meeting:
            MeetingConfigView()
                .environmentObject(meetingManager)
        case .format:
            FormatConfigView()
                .environmentObject(formatSettings)
                .environmentObject(formatPanelManager)
        case .image:
            ImageConfigView()
                .environmentObject(imageSettings)
                .environmentObject(imagePanelManager)
        case .clipboard:
            ClipboardConfigView()
                .environmentObject(clipboardSettings)
                .environmentObject(clipboardPanelManager)
        case .battery:
            BatteryConfigView()
                .environmentObject(batteryManager)
        case .icon:
            IconConfigView()
                .environmentObject(menuBarIconManager)
                .environmentObject(menuBarFolder)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("OmniKit v1.0")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private enum SettingsModule: CaseIterable, Identifiable {
    case translation
    case ocr
    case meeting
    case format
    case image
    case clipboard
    case battery
    case icon

    var id: Self { self }
    var title: String {
        switch self {
        case .translation: return "翻译"
        case .ocr: return "OCR"
        case .meeting: return "会议"
        case .format: return "格式转换"
        case .image: return "图片"
        case .clipboard: return "剪贴板"
        case .battery: return "电池"
        case .icon: return "图标"
        }
    }
    var icon: String {
        switch self {
        case .translation: return "globe"
        case .ocr: return "text.viewfinder"
        case .meeting: return "person.2.wave.2"
        case .format: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .image: return "photo.on.rectangle.angled"
        case .clipboard: return "doc.on.clipboard"
        case .battery: return "battery.100percent"
        case .icon: return "menubar.rectangle"
        }
    }
}

#Preview {
    let translationSettings = TranslationSettingsStore()
    let ocrSettings = OCRSettingsStore()
    let formatSettings = FormatSettingsStore()
    let imageSettings = ImageSettingsStore()
    let clipboardSettings = ClipboardSettingsStore()
    let batteryManager = BatteryManager()
    let menuBarIconManager = MenuBarIconManager()
    ContentView()
        .frame(width: 1000, height: 700)
        .environmentObject(translationSettings)
        .environmentObject(TranslatorPanelManager(settings: translationSettings))
        .environmentObject(ocrSettings)
        .environmentObject(OCRManager(settings: ocrSettings))
        .environmentObject(MeetingManager())
        .environmentObject(formatSettings)
        .environmentObject(FormatPanelManager(settings: formatSettings))
        .environmentObject(imageSettings)
        .environmentObject(ImagePanelManager(settings: imageSettings))
        .environmentObject(clipboardSettings)
        .environmentObject(ClipboardPanelManager(settings: clipboardSettings))
        .environmentObject(batteryManager)
        .environmentObject(menuBarIconManager)
}
