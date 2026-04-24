//
//  TranslatorPanelManager.swift
//  OmniKit
//
//  Created by lincunhao on 2026/4/14.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TranslatorPanelManager: ObservableObject {
    private enum HotKeyActionID {
        static let inputTranslation: UInt32 = 1
        static let selectionTranslation: UInt32 = 2
    }

    private let settings: TranslationSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let service = AlibabaTranslationService()
    private let pinState = PanelPinState()

    private var panel: TranslatorFloatingPanel?
    private var panelViewModel: TranslatorPanelViewModel?
    private var notificationObservers: [NSObjectProtocol] = []

    init(settings: TranslationSettingsStore) {
        self.settings = settings
        registerShortcuts()
        observeApplicationLifecycle()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
    }

    func updateShortcuts() {
        registerShortcuts()
    }

    func suspendShortcuts() {
        hotKeyManager.unregister()
    }

    func showInputPanel() {
        showPanel(prefillText: "", autoSubmit: false)
    }

    private func registerShortcuts() {
        hotKeyManager.register(
            shortcuts: [
                HotKeyActionID.inputTranslation: settings.inputTranslationShortcut,
                HotKeyActionID.selectionTranslation: settings.selectionTranslationShortcut
            ]
        ) { [weak self] actionID in
            Task { @MainActor in
                guard let self else { return }
                if actionID == HotKeyActionID.selectionTranslation {
                    self.handleSelectionTranslationTrigger()
                } else {
                    self.togglePanel()
                }
            }
        }
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateShortcuts()
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateShortcuts()
            }
        ]
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showInputPanel()
    }

    private func showPanel(prefillText: String, autoSubmit: Bool) {
        if panel == nil {
            let viewModel = TranslatorPanelViewModel(settings: settings, service: service)
            panelViewModel = viewModel

            let newPanel = TranslatorFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.borderless, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newPanel.applyPinnedState(pinState.isPinned)
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isMovableByWindowBackground = true
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.minSize = NSSize(width: 500, height: 320)
            newPanel.center()
            newPanel.contentView = NSHostingView(
                rootView: TranslatorQuickPanelView(
                    viewModel: viewModel,
                    pinState: pinState,
                    closeAction: { [weak newPanel] in newPanel?.close() },
                    minimizeAction: { [weak newPanel] in newPanel?.performMiniaturize(nil) },
                    zoomAction: { [weak newPanel] in newPanel?.performZoom(nil) },
                    togglePinAction: { [weak self, weak newPanel] in
                        guard let self else { return }
                        self.pinState.isPinned.toggle()
                        newPanel?.applyPinnedState(self.pinState.isPinned)
                    }
                )
            )
            panel = newPanel
        }

        panelViewModel?.prepareForDisplay(prefillText: prefillText, autoSubmit: autoSubmit)
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func handleSelectionTranslationTrigger() {
        if let selectedText = captureSelectedText(), !selectedText.isEmpty {
            showPanel(prefillText: selectedText, autoSubmit: true)
        } else {
            showPanel(prefillText: "", autoSubmit: false)
        }
    }

    private func captureSelectedText() -> String? {
        let pasteboard = NSPasteboard.general
        let backup = pasteboard.string(forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true) // C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        let selected = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        if let backup {
            pasteboard.setString(backup, forType: .string)
        }
        return selected?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TranslatorFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var titlebarAppearsTransparent: Bool {
        get { false }
        set { }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func applyPinnedState(_ isPinned: Bool) {
        isFloatingPanel = isPinned
        level = isPinned ? .floating : .normal
    }
}

@MainActor
final class TranslatorPanelViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var isTranslating = false
    @Published var errorMessage = ""
    @Published var focusInput = false
    @Published var sourceLanguage: SourceLanguageOption = .autoDetect
    @Published var targetLanguage: TargetLanguageOption = .autoSelect

    private let settings: TranslationSettingsStore
    private let service: AlibabaTranslationService
    private let speechSynthesizer = NSSpeechSynthesizer()

    init(settings: TranslationSettingsStore, service: AlibabaTranslationService) {
        self.settings = settings
        self.service = service
    }

    func prepareForDisplay(prefillText: String, autoSubmit: Bool) {
        inputText = prefillText
        outputText = ""
        errorMessage = ""
        isTranslating = false
        sourceLanguage = .autoDetect
        targetLanguage = .autoSelect
        focusInput = true
        if autoSubmit, !prefillText.isEmpty {
            submit()
        }
    }

    func submit() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard !settings.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先在系统设置配置 AccessKey ID 和 AccessKey Secret。"
            return
        }

        isTranslating = true
        errorMessage = ""

        Task {
            do {
                let translated = try await service.translate(
                    text: content,
                    accessKeyId: settings.accessKeyId,
                    accessKeySecret: settings.accessKeySecret,
                    sourceLanguage: resolvedSourceLanguage(for: content),
                    targetLanguage: resolvedTargetLanguage(for: content),
                    apiVersion: settings.apiVersion.rawValue,
                    formatType: settings.formatType.rawValue
                )
                await MainActor.run {
                    self.outputText = translated
                    self.isTranslating = false
                    self.focusInput = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isTranslating = false
                }
            }
        }
    }

    func swapLanguages() {
        guard sourceLanguage != .autoDetect else {
            sourceLanguage = .chineseSimplified
            targetLanguage = .english
            return
        }
        let previousSource = sourceLanguage
        sourceLanguage = SourceLanguageOption(code: targetLanguage.code) ?? .autoDetect
        targetLanguage = TargetLanguageOption(code: previousSource.code) ?? .english
    }

    func copySourceText() {
        copyToPasteboard(inputText)
    }

    func copyResultText() {
        copyToPasteboard(outputText)
    }

    func speakSourceText() {
        speak(inputText)
    }

    func speakResultText() {
        speak(outputText)
    }

    var detectedLanguageLabel: String {
        let lang = detectLanguage(for: inputText)
        return lang == "zh" ? "识别为 中文简体" : "识别为 英文"
    }

    private func resolvedSourceLanguage(for text: String) -> String {
        sourceLanguage == .autoDetect ? "auto" : sourceLanguage.code
    }

    private func resolvedTargetLanguage(for text: String) -> String {
        if targetLanguage != .autoSelect {
            return targetLanguage.code
        }
        return detectLanguage(for: text) == "zh" ? "en" : "zh"
    }

    private func detectLanguage(for text: String) -> String {
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        return hasCJK ? "zh" : "en"
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speechSynthesizer.stopSpeaking()
        speechSynthesizer.startSpeaking(trimmed)
    }
}

protocol LanguageOptionProtocol: Identifiable, RawRepresentable, Hashable where RawValue == String {
    var title: String { get }
    var code: String { get }
}

extension LanguageOptionProtocol {
    var code: String { rawValue }
}

private enum TranslationLanguageCatalog {
    static func title(for code: String) -> String {
        switch code {
        case "zh": return "中文简体"
        case "en": return "英文"
        case "ja": return "日文"
        case "ko": return "韩文"
        case "fr": return "法文"
        case "de": return "德文"
        case "es": return "西班牙文"
        case "it": return "意大利文"
        case "pt": return "葡萄牙文"
        case "ru": return "俄文"
        case "ar": return "阿拉伯文"
        case "tr": return "土耳其文"
        case "th": return "泰文"
        case "vi": return "越南文"
        case "id": return "印尼文"
        case "ms": return "马来文"
        case "hi": return "印地文"
        default: return code.uppercased()
        }
    }
}

enum SourceLanguageOption: String, CaseIterable, Identifiable, LanguageOptionProtocol {
    case autoDetect = "auto"
    case chineseSimplified = "zh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    case turkish = "tr"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case hindi = "hi"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .autoDetect: return "自动检测"
        default: return TranslationLanguageCatalog.title(for: rawValue)
        }
    }

    init?(code: String) {
        self.init(rawValue: code)
    }
}

enum TargetLanguageOption: String, CaseIterable, Identifiable, LanguageOptionProtocol {
    case autoSelect = "auto_select"
    case chineseSimplified = "zh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    case turkish = "tr"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case hindi = "hi"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .autoSelect: return "自动选择"
        default: return TranslationLanguageCatalog.title(for: rawValue)
        }
    }

    init?(code: String) {
        self.init(rawValue: code)
    }
}

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct TranslatorQuickPanelView: View {
    @ObservedObject var viewModel: TranslatorPanelViewModel
    @ObservedObject var pinState: PanelPinState
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            VisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            VStack(spacing: 0) {
                // Header / Language Picker
                HStack(spacing: 12) {
                    WindowControlStrip(
                        isPinned: pinState.isPinned,
                        closeAction: closeAction,
                        minimizeAction: minimizeAction,
                        zoomAction: zoomAction,
                        togglePinAction: togglePinAction
                    )

                    languageMenu(selection: $viewModel.sourceLanguage, options: SourceLanguageOption.allCases)
                    
                    Button {
                        viewModel.swapLanguages()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    
                    languageMenu(selection: $viewModel.targetLanguage, options: TargetLanguageOption.allCases)
                    
                    Spacer()
                    
                    if viewModel.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.5)
                    .padding(.horizontal, 16)

                // Input Area
                VStack(alignment: .leading, spacing: 4) {
                    TextField("输入内容，按回车翻译", text: $viewModel.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .focused($inputFocused)
                        .onSubmit {
                            viewModel.submit()
                        }
                        .font(.system(size: 22, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    HStack(spacing: 12) {
                        actionButton(systemName: "speaker.wave.2", action: viewModel.speakSourceText)
                        actionButton(systemName: "doc.on.doc", action: viewModel.copySourceText)
                        
                        if !viewModel.inputText.isEmpty {
                            Text(viewModel.detectedLanguageLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue.opacity(0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }

                Divider()
                    .opacity(0.5)
                    .padding(.horizontal, 16)

                // Output Area
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.outputText.isEmpty && !viewModel.isTranslating {
                            Text("等待翻译...")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(viewModel.outputText)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                Divider()
                    .opacity(0.5)

                // Footer
                HStack {
                    Label("Alibaba Cloud", systemImage: "cloud.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        if !viewModel.errorMessage.isEmpty {
                            Text(viewModel.errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                        
                        actionButton(systemName: "speaker.wave.2", action: viewModel.speakResultText)
                        actionButton(systemName: "doc.on.doc", action: viewModel.copyResultText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.03))
            }
        }
        .frame(minWidth: 500, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.focusInput) { _, newValue in
            inputFocused = newValue
        }
        .onAppear {
            inputFocused = true
        }
    }

    private func languageMenu<T: LanguageOptionProtocol>(selection: Binding<T>, options: [T]) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.title)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.05))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct WindowControlStrip: View {
    let isPinned: Bool
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            WindowControlDot(color: Color(red: 1.0, green: 0.37, blue: 0.33), action: closeAction)
            WindowControlDot(color: Color(red: 1.0, green: 0.74, blue: 0.18), action: minimizeAction)
            WindowControlDot(color: Color(red: 0.17, green: 0.80, blue: 0.25), action: zoomAction)
            Button(action: togglePinAction) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消固定在最前" : "固定在最前")
        }
    }
}

@MainActor
private final class PanelPinState: ObservableObject {
    @Published var isPinned = false
}

private struct WindowControlDot: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
