//
//  FormatPanelManager.swift
//  OmniKit
//

import AppKit
import Combine
import CryptoKit
import SwiftUI

enum FormatDataType: String, CaseIterable, Identifiable {
    case json
    case uuid
    case chineseIDCard
    case encrypt
    case decrypt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .json:
            return "JSON"
        case .uuid:
            return "UUID"
        case .chineseIDCard:
            return "身份证号"
        case .encrypt:
            return "加密"
        case .decrypt:
            return "解密"
        }
    }

    var requiresInput: Bool {
        switch self {
        case .json, .encrypt, .decrypt:
            return true
        case .uuid, .chineseIDCard:
            return false
        }
    }
}

enum JSONActionType: String, CaseIterable, Identifiable {
    case prettify
    case minify

    var id: String { rawValue }
    var title: String {
        switch self {
        case .prettify:
            return "格式化"
        case .minify:
            return "压缩"
        }
    }
}

enum CryptoAlgorithmType: String, CaseIterable, Identifiable {
    case base64
    case md5
    case urlPercent
    case escape
    case unicode

    var id: String { rawValue }
    var title: String {
        switch self {
        case .base64:
            return "Base64"
        case .md5:
            return "MD5"
        case .urlPercent:
            return "URL"
        case .escape:
            return "转义"
        case .unicode:
            return "Unicode"
        }
    }
}

@MainActor
final class FormatPanelManager: ObservableObject {
    private enum HotKeyActionID {
        static let toggleFormatPanel: UInt32 = 200
    }

    private let settings: FormatSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let pinState = FormatPanelPinState()

    private var panel: FormatFloatingPanel?
    private var viewModel: FormatPanelViewModel?

    init(settings: FormatSettingsStore) {
        self.settings = settings
        registerShortcut()
    }

    func updateShortcut() {
        registerShortcut()
    }

    func suspendShortcut() {
        hotKeyManager.unregister()
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        presentPanel()
    }

    func presentPanel() {
        showPanel()
    }

    private func registerShortcut() {
        hotKeyManager.register(
            shortcuts: [HotKeyActionID.toggleFormatPanel: settings.formatShortcut]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let vm = FormatPanelViewModel()
            viewModel = vm

            let newPanel = FormatFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
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
            newPanel.minSize = NSSize(width: 820, height: 520)
            newPanel.center()
            newPanel.contentView = NSHostingView(
                rootView: FormatQuickPanelView(
                    viewModel: vm,
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

        viewModel?.prepareForDisplay()
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
    }
}

private final class FormatFloatingPanel: NSPanel {
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
final class FormatPanelViewModel: ObservableObject {
    @Published var selectedType: FormatDataType = .json
    @Published var selectedJSONAction: JSONActionType = .prettify
    @Published var selectedCryptoAlgorithm: CryptoAlgorithmType = .base64
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var statusMessage = ""
    @Published var statusTint: Color = .secondary

    var availableCryptoAlgorithms: [CryptoAlgorithmType] {
        switch selectedType {
        case .encrypt:
            return [.base64, .md5, .urlPercent, .escape, .unicode]
        case .decrypt:
            return [.base64, .urlPercent, .escape, .unicode]
        default:
            return [.base64, .md5, .urlPercent, .escape, .unicode]
        }
    }

    var contextualHint: String {
        switch selectedType {
        case .json:
            return "支持从整段文本中自动提取 JSON。"
        case .uuid:
            return "无需输入，点击执行后随机生成 5 个 UUID。"
        case .chineseIDCard:
            return "无需输入，点击执行后随机生成 5 个合法校验位的 18 位身份证号。"
        case .encrypt:
            return "输入原文后点击执行，支持 Base64、MD5、URL、转义和 Unicode 编码。"
        case .decrypt:
            return "输入密文后点击执行，支持 Base64、URL、转义和 Unicode 解码。MD5 不可逆，不支持解密。"
        }
    }

    var secondaryControlTitle: String {
        switch selectedType {
        case .json:
            return "功能"
        case .encrypt, .decrypt:
            return "算法"
        case .uuid, .chineseIDCard:
            return "模式"
        }
    }

    func prepareForDisplay() {
        statusMessage = ""
        statusTint = .secondary
        normalizeCryptoSelection()
    }

    func runConversion() {
        switch selectedType {
        case .json:
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                statusMessage = "请输入内容"
                statusTint = .orange
                outputText = ""
                return
            }
            do {
                let result = try processJSON(trimmed, action: selectedJSONAction)
                outputText = result
                statusMessage = "处理完成"
                statusTint = .green
            } catch {
                outputText = ""
                statusMessage = error.localizedDescription
                statusTint = .red
            }
        case .uuid:
            outputText = (0..<5)
                .map { _ in UUID().uuidString.lowercased() }
                .joined(separator: "\n")
            statusMessage = "已生成 5 个 UUID"
            statusTint = .green
        case .chineseIDCard:
            outputText = (0..<5)
                .map { _ in generateChineseResidentID() }
                .joined(separator: "\n")
            statusMessage = "已生成 5 个身份证号"
            statusTint = .green
        case .encrypt, .decrypt:
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                statusMessage = "请输入内容"
                statusTint = .orange
                outputText = ""
                return
            }
            do {
                let result = try processCrypto(trimmed, mode: selectedType, algorithm: selectedCryptoAlgorithm)
                outputText = result
                statusMessage = selectedType == .encrypt ? "加密完成" : "解密完成"
                statusTint = .green
            } catch {
                outputText = ""
                statusMessage = error.localizedDescription
                statusTint = .red
            }
        }
    }

    func copyResult() {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        statusMessage = "结果已复制"
        statusTint = .green
    }

    func clearAll() {
        inputText = ""
        outputText = ""
        statusMessage = ""
        statusTint = .secondary
    }

    private func processJSON(_ content: String, action: JSONActionType) throws -> String {
        let objects = try extractJSONObjects(from: content)
        let objectToSerialize: Any = objects.count == 1 ? objects[0] : objects
        let options: JSONSerialization.WritingOptions = action == .prettify ? [.prettyPrinted] : []
        let outputData = try JSONSerialization.data(withJSONObject: objectToSerialize, options: options)
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw ConversionError.invalidEncoding
        }
        return output
    }

    private func extractJSONObjects(from content: String) throws -> [Any] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = parseJSONObject(from: trimmed) {
            return [object]
        }

        var extractedObjects: [Any] = []
        var searchIndex = trimmed.startIndex
        while searchIndex < trimmed.endIndex {
            guard let start = trimmed[searchIndex...].firstIndex(where: { $0 == "{" || $0 == "[" }) else {
                break
            }

            if let candidate = extractBalancedJSONCandidate(in: trimmed, from: start),
               let object = parseJSONObject(from: candidate.payload) {
                extractedObjects.append(object)
                searchIndex = trimmed.index(after: candidate.endIndex)
                continue
            }

            searchIndex = trimmed.index(after: start)
        }

        if !extractedObjects.isEmpty {
            return extractedObjects
        }

        throw ConversionError.jsonNotFound
    }

    private func extractBalancedJSONCandidate(
        in content: String,
        from start: String.Index
    ) -> (payload: String, endIndex: String.Index)? {
        var stack: [Character] = []
        var inString = false
        var isEscaped = false
        var index = start

        while index < content.endIndex {
            let character = content[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{", "[":
                    stack.append(character)
                case "}":
                    guard stack.last == "{" else { return nil }
                    stack.removeLast()
                    if stack.isEmpty {
                        return (String(content[start...index]), index)
                    }
                case "]":
                    guard stack.last == "[" else { return nil }
                    stack.removeLast()
                    if stack.isEmpty {
                        return (String(content[start...index]), index)
                    }
                default:
                    break
                }
            }

            index = content.index(after: index)
        }

        return nil
    }

    private func parseJSONObject(from value: String) -> Any? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func processCrypto(
        _ content: String,
        mode: FormatDataType,
        algorithm: CryptoAlgorithmType
    ) throws -> String {
        switch (mode, algorithm) {
        case (.encrypt, .base64):
            guard let data = content.data(using: .utf8) else {
                throw ConversionError.invalidEncoding
            }
            return data.base64EncodedString()
        case (.encrypt, .md5):
            return Insecure.MD5.hash(data: Data(content.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        case (.decrypt, .base64):
            guard let data = Data(base64Encoded: content),
                  let output = String(data: data, encoding: .utf8) else {
                throw ConversionError.invalidBase64
            }
            return output
        case (.encrypt, .urlPercent):
            guard let encoded = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw ConversionError.invalidEncoding
            }
            return encoded
        case (.decrypt, .urlPercent):
            guard let decoded = content.removingPercentEncoding else {
                throw ConversionError.invalidURLText
            }
            return decoded
        case (.encrypt, .escape):
            return escapeText(content)
        case (.decrypt, .escape):
            return try unescapeText(content)
        case (.encrypt, .unicode):
            return unicodeEscapeText(content)
        case (.decrypt, .unicode):
            return try decodeUnicodeEscapes(content)
        default:
            throw ConversionError.unsupportedConversion
        }
    }

    func normalizeCryptoSelection() {
        guard selectedType == .encrypt || selectedType == .decrypt else { return }
        if !availableCryptoAlgorithms.contains(selectedCryptoAlgorithm) {
            selectedCryptoAlgorithm = availableCryptoAlgorithms.first ?? .base64
        }
    }

    private func escapeText(_ content: String) -> String {
        var output = ""
        for character in content {
            switch character {
            case "\\":
                output += "\\\\"
            case "\"":
                output += "\\\""
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                output.append(character)
            }
        }
        return output
    }

    private func unescapeText(_ content: String) throws -> String {
        try decodeEscapedText(content, decodeUnicode: true)
    }

    private func unicodeEscapeText(_ content: String) -> String {
        content.utf16
            .map { String(format: "\\u%04X", $0) }
            .joined()
    }

    private func decodeUnicodeEscapes(_ content: String) throws -> String {
        try decodeEscapedText(content, decodeUnicode: true, onlyUnicodeEscapes: true)
    }

    private func decodeEscapedText(
        _ content: String,
        decodeUnicode: Bool,
        onlyUnicodeEscapes: Bool = false
    ) throws -> String {
        let characters = Array(content)
        var output = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "\\" else {
                output.append(character)
                index += 1
                continue
            }

            let nextIndex = index + 1
            guard nextIndex < characters.count else {
                throw ConversionError.invalidEscapedText
            }

            let marker = characters[nextIndex]
            if decodeUnicode, marker == "u" {
                let scalar = try parseUnicodeEscape(in: characters, startIndex: index)
                output.append(String(scalar.value))
                index = scalar.nextIndex
                continue
            }

            if onlyUnicodeEscapes {
                output.append(character)
                index += 1
                continue
            }

            switch marker {
            case "\\":
                output += "\\"
            case "\"":
                output += "\""
            case "/":
                output += "/"
            case "n":
                output += "\n"
            case "r":
                output += "\r"
            case "t":
                output += "\t"
            case "b":
                output += "\u{08}"
            case "f":
                output += "\u{0C}"
            default:
                throw ConversionError.invalidEscapedText
            }
            index += 2
        }

        return output
    }

    private func parseUnicodeEscape(
        in characters: [Character],
        startIndex: Int
    ) throws -> (value: Unicode.Scalar, nextIndex: Int) {
        let codeUnit = try parseUnicodeCodeUnit(in: characters, startIndex: startIndex)
        var nextIndex = startIndex + 6

        if (0xD800...0xDBFF).contains(codeUnit) {
            guard nextIndex + 5 < characters.count,
                  characters[nextIndex] == "\\",
                  characters[nextIndex + 1] == "u" else {
                throw ConversionError.invalidUnicodeText
            }

            let lowSurrogate = try parseUnicodeCodeUnit(in: characters, startIndex: nextIndex)
            guard (0xDC00...0xDFFF).contains(lowSurrogate) else {
                throw ConversionError.invalidUnicodeText
            }

            let highValue = UInt32(codeUnit - 0xD800)
            let lowValue = UInt32(lowSurrogate - 0xDC00)
            let scalarValue = 0x10000 + ((highValue << 10) | lowValue)
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw ConversionError.invalidUnicodeText
            }
            nextIndex += 6
            return (scalar, nextIndex)
        }

        guard !(0xDC00...0xDFFF).contains(codeUnit),
              let scalar = Unicode.Scalar(UInt32(codeUnit)) else {
            throw ConversionError.invalidUnicodeText
        }
        return (scalar, nextIndex)
    }

    private func parseUnicodeCodeUnit(in characters: [Character], startIndex: Int) throws -> UInt16 {
        guard startIndex + 5 < characters.count,
              characters[startIndex] == "\\",
              characters[startIndex + 1] == "u" else {
            throw ConversionError.invalidUnicodeText
        }

        let hex = String(characters[(startIndex + 2)...(startIndex + 5)])
        guard let value = UInt16(hex, radix: 16) else {
            throw ConversionError.invalidUnicodeText
        }
        return value
    }

    private func generateChineseResidentID() -> String {
        let regions = [
            "110101", "110105", "120101", "310101", "310104",
            "320102", "330106", "330108", "440103", "440106",
            "440305", "440506", "500103", "510104", "510107"
        ]
        let region = regions.randomElement() ?? "110101"

        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(from: DateComponents(year: 1975, month: 1, day: 1)) ?? .now
        let endDate = calendar.date(from: DateComponents(year: 2010, month: 12, day: 31)) ?? .now
        let randomTimeInterval = TimeInterval.random(in: startDate.timeIntervalSince1970...endDate.timeIntervalSince1970)
        let birthDate = Date(timeIntervalSince1970: randomTimeInterval)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd"
        let birth = formatter.string(from: birthDate)

        let sequence = String(format: "%03d", Int.random(in: 1...999))
        let base = region + birth + sequence
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checkDigits = Array("10X98765432")
        let sum = zip(base, weights).reduce(0) { partial, pair in
            guard let digit = pair.0.wholeNumberValue else { return partial }
            return partial + digit * pair.1
        }
        let checksum = checkDigits[sum % 11]
        return base + String(checksum)
    }
}

private enum ConversionError: LocalizedError {
    case invalidEncoding
    case jsonNotFound
    case invalidBase64
    case invalidURLText
    case invalidEscapedText
    case invalidUnicodeText
    case unsupportedConversion

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "文本编码异常，无法处理。"
        case .jsonNotFound:
            return "未在文本中找到可解析的 JSON。"
        case .invalidBase64:
            return "Base64 内容无效，无法解密。"
        case .invalidURLText:
            return "URL 编码内容无效，无法解密。"
        case .invalidEscapedText:
            return "转义内容无效，无法解密。"
        case .invalidUnicodeText:
            return "Unicode 编码内容无效，无法解密。"
        case .unsupportedConversion:
            return "当前转换组合暂不支持。"
        }
    }
}

private struct FormatQuickPanelView: View {
    @ObservedObject var viewModel: FormatPanelViewModel
    @ObservedObject var pinState: FormatPanelPinState
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            FormatVisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        FormatWindowControlStrip(
                            isPinned: pinState.isPinned,
                            closeAction: closeAction,
                            minimizeAction: minimizeAction,
                            zoomAction: zoomAction,
                            togglePinAction: togglePinAction
                        )

                        Spacer(minLength: 8)

                        Text("选择类型")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $viewModel.selectedType) {
                            ForEach(FormatDataType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }

                    HStack {
                        Text(viewModel.secondaryControlTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if viewModel.selectedType == .json {
                            Picker("", selection: $viewModel.selectedJSONAction) {
                                ForEach(JSONActionType.allCases) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                        } else if viewModel.selectedType == .encrypt || viewModel.selectedType == .decrypt {
                            Picker("", selection: $viewModel.selectedCryptoAlgorithm) {
                                ForEach(viewModel.availableCryptoAlgorithms) { algorithm in
                                    Text(algorithm.title).tag(algorithm)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                        } else {
                            Text("随机生成")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.selectedType.requiresInput ? "输入" : "说明")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Group {
                            if viewModel.selectedType.requiresInput {
                                TextEditor(text: $viewModel.inputText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .focused($inputFocused)
                                    .frame(minHeight: 270)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("随机生成", systemImage: "sparkles")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(viewModel.contextualHint)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 270, alignment: .topLeading)
                                .padding(14)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("输出")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.outputText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 270)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    if !viewModel.statusMessage.isEmpty {
                        SettingsInfoBadge(text: viewModel.statusMessage, tint: viewModel.statusTint)
                    }
                    Spacer()
                    Button("清空") { viewModel.clearAll() }
                        .buttonStyle(.bordered)
                    Button("复制结果") { viewModel.copyResult() }
                        .buttonStyle(.bordered)
                    Button("执行") { viewModel.runConversion() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            inputFocused = viewModel.selectedType.requiresInput
        }
        .onChange(of: viewModel.selectedType) { _, newValue in
            inputFocused = newValue.requiresInput
            viewModel.normalizeCryptoSelection()
        }
    }
}

private struct FormatVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct FormatWindowControlStrip: View {
    let isPinned: Bool
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FormatWindowControlDot(color: Color(red: 1.0, green: 0.37, blue: 0.33), action: closeAction)
            FormatWindowControlDot(color: Color(red: 1.0, green: 0.74, blue: 0.18), action: minimizeAction)
            FormatWindowControlDot(color: Color(red: 0.17, green: 0.80, blue: 0.25), action: zoomAction)
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
private final class FormatPanelPinState: ObservableObject {
    @Published var isPinned = false
}

private struct FormatWindowControlDot: View {
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
