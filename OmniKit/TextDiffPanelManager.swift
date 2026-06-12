//
//  TextDiffPanelManager.swift
//  OmniKit
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TextDiffPanelManager: ObservableObject {
    private enum HotKeyActionID {
        static let toggleTextDiffPanel: UInt32 = 500
    }

    private let settings: TextDiffSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let pinState = TextDiffPanelPinState()

    private var panel: TextDiffFloatingPanel?
    private var viewModel: TextDiffPanelViewModel?

    init(settings: TextDiffSettingsStore) {
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
            shortcuts: [HotKeyActionID.toggleTextDiffPanel: settings.textDiffShortcut]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let vm = TextDiffPanelViewModel()
            viewModel = vm

            let newPanel = TextDiffFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
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
            newPanel.minSize = NSSize(width: 860, height: 560)
            newPanel.center()
            newPanel.contentView = NSHostingView(
                rootView: TextDiffQuickPanelView(
                    viewModel: vm,
                    pinState: pinState,
                    closeAction: { [weak newPanel] in newPanel?.close() },
                    minimizeAction: { [weak newPanel] in newPanel?.omniKitMiniaturize() },
                    zoomAction: { [weak newPanel] in newPanel?.omniKitToggleZoom() },
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

private final class TextDiffFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var titlebarAppearsTransparent: Bool {
        get { false }
        set { }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
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
final class TextDiffPanelViewModel: ObservableObject {
    @Published var leftText = ""
    @Published var rightText = ""
    @Published private(set) var rows: [TextDiffRow] = []
    @Published var statusMessage = ""
    @Published var statusTint: Color = .secondary
    @Published var ignoreWhitespace = false
    @Published var ignoreCase = false

    var hasResult: Bool { !rows.isEmpty }

    func prepareForDisplay() {
        if rows.isEmpty {
            statusMessage = ""
            statusTint = .secondary
        }
    }

    func compare() {
        let leftLines = leftText.splitIntoDiffLines()
        let rightLines = rightText.splitIntoDiffLines()
        guard !leftText.isEmpty || !rightText.isEmpty else {
            rows = []
            statusMessage = "请输入要比对的文本"
            statusTint = .orange
            return
        }

        rows = Self.buildDiffRows(
            leftLines: leftLines,
            rightLines: rightLines,
            normalize: normalizedLine(_:)
        )
        let summary = summarize(rows)
        statusMessage = summary
        statusTint = summary == "两个文本一致" ? .green : .orange
    }

    func clearAll() {
        leftText = ""
        rightText = ""
        rows = []
        statusMessage = ""
        statusTint = .secondary
    }

    func swapTexts() {
        let oldLeftText = leftText
        leftText = rightText
        rightText = oldLeftText
        compare()
    }

    private func normalizedLine(_ line: String) -> String {
        var output = line
        if ignoreWhitespace {
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            output = output.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        if ignoreCase {
            output = output.lowercased()
        }
        return output
    }

    private func summarize(_ rows: [TextDiffRow]) -> String {
        let added = rows.filter { $0.kind == .added }.count
        let removed = rows.filter { $0.kind == .removed }.count
        let modified = rows.filter { $0.kind == .modified }.count
        if added == 0, removed == 0, modified == 0 {
            return "两个文本一致"
        }

        var parts: [String] = []
        if modified > 0 { parts.append("\(modified) 处修改") }
        if added > 0 { parts.append("\(added) 行新增") }
        if removed > 0 { parts.append("\(removed) 行删除") }
        return parts.joined(separator: "，")
    }

    private static func buildDiffRows(
        leftLines: [String],
        rightLines: [String],
        normalize: (String) -> String
    ) -> [TextDiffRow] {
        let leftNormalized = leftLines.map(normalize)
        let rightNormalized = rightLines.map(normalize)
        let operations = diffOperations(left: leftNormalized, right: rightNormalized)

        var rows: [TextDiffRow] = []
        var pendingRemoved: [(number: Int, text: String)] = []

        func flushRemoved() {
            for item in pendingRemoved {
                rows.append(TextDiffRow(leftNumber: item.number, leftText: item.text, rightNumber: nil, rightText: nil, kind: .removed))
            }
            pendingRemoved.removeAll()
        }

        for operation in operations {
            switch operation {
            case let .equal(leftIndex, rightIndex):
                flushRemoved()
                rows.append(TextDiffRow(
                    leftNumber: leftIndex + 1,
                    leftText: leftLines[leftIndex],
                    rightNumber: rightIndex + 1,
                    rightText: rightLines[rightIndex],
                    kind: .equal
                ))
            case let .remove(leftIndex):
                pendingRemoved.append((leftIndex + 1, leftLines[leftIndex]))
            case let .insert(rightIndex):
                if let removed = pendingRemoved.first {
                    pendingRemoved.removeFirst()
                    rows.append(TextDiffRow(
                        leftNumber: removed.number,
                        leftText: removed.text,
                        rightNumber: rightIndex + 1,
                        rightText: rightLines[rightIndex],
                        kind: .modified
                    ))
                } else {
                    rows.append(TextDiffRow(
                        leftNumber: nil,
                        leftText: nil,
                        rightNumber: rightIndex + 1,
                        rightText: rightLines[rightIndex],
                        kind: .added
                    ))
                }
            }
        }
        flushRemoved()
        return rows
    }

    private static func diffOperations(left: [String], right: [String]) -> [DiffOperation] {
        let leftCount = left.count
        let rightCount = right.count
        var table = Array(repeating: Array(repeating: 0, count: rightCount + 1), count: leftCount + 1)

        if leftCount > 0, rightCount > 0 {
            for i in stride(from: leftCount - 1, through: 0, by: -1) {
                for j in stride(from: rightCount - 1, through: 0, by: -1) {
                    if left[i] == right[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }

        var operations: [DiffOperation] = []
        var i = 0
        var j = 0
        while i < leftCount, j < rightCount {
            if left[i] == right[j] {
                operations.append(.equal(leftIndex: i, rightIndex: j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                operations.append(.remove(leftIndex: i))
                i += 1
            } else {
                operations.append(.insert(rightIndex: j))
                j += 1
            }
        }
        while i < leftCount {
            operations.append(.remove(leftIndex: i))
            i += 1
        }
        while j < rightCount {
            operations.append(.insert(rightIndex: j))
            j += 1
        }
        return operations
    }
}

struct TextDiffRow: Identifiable {
    let id = UUID()
    let leftNumber: Int?
    let leftText: String?
    let rightNumber: Int?
    let rightText: String?
    let kind: TextDiffRowKind
}

enum TextDiffRowKind {
    case equal
    case added
    case removed
    case modified

    var title: String {
        switch self {
        case .equal:
            return ""
        case .added:
            return "新增"
        case .removed:
            return "删除"
        case .modified:
            return "修改"
        }
    }

    var tint: Color {
        switch self {
        case .equal:
            return .secondary
        case .added:
            return .green
        case .removed:
            return .red
        case .modified:
            return .orange
        }
    }

    var background: Color {
        switch self {
        case .equal:
            return Color.primary.opacity(0.025)
        case .added:
            return Color.green.opacity(0.14)
        case .removed:
            return Color.red.opacity(0.12)
        case .modified:
            return Color.orange.opacity(0.14)
        }
    }
}

private enum DiffOperation {
    case equal(leftIndex: Int, rightIndex: Int)
    case remove(leftIndex: Int)
    case insert(rightIndex: Int)
}

private extension String {
    func splitIntoDiffLines() -> [String] {
        guard !isEmpty else { return [] }
        return components(separatedBy: .newlines)
    }
}

private struct TextDiffQuickPanelView: View {
    @ObservedObject var viewModel: TextDiffPanelViewModel
    @ObservedObject var pinState: TextDiffPanelPinState
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void
    @FocusState private var leftFocused: Bool

    var body: some View {
        ZStack {
            TextDiffVisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            VStack(spacing: 12) {
                header
                inputArea
                resultArea
                footer
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            leftFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextDiffWindowControlStrip(
                isPinned: pinState.isPinned,
                closeAction: closeAction,
                minimizeAction: minimizeAction,
                zoomAction: zoomAction,
                togglePinAction: togglePinAction
            )

            Text("文本比对")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Toggle("忽略空白", isOn: $viewModel.ignoreWhitespace)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Toggle("忽略大小写", isOn: $viewModel.ignoreCase)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var inputArea: some View {
        HStack(alignment: .top, spacing: 10) {
            textInput(title: "左侧文本", text: $viewModel.leftText)
                .focused($leftFocused)
            textInput(title: "右侧文本", text: $viewModel.rightText)
        }
        .padding(.horizontal, 16)
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("差异结果")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 2) {
                    if viewModel.hasResult {
                        ForEach(viewModel.rows) { row in
                            TextDiffRowView(row: row)
                        }
                    } else {
                        Text("点击“开始比对”后显示差异")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 150)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !viewModel.statusMessage.isEmpty {
                SettingsInfoBadge(text: viewModel.statusMessage, tint: viewModel.statusTint)
            }
            Spacer()
            Button("清空") { viewModel.clearAll() }
                .buttonStyle(.bordered)
            Button("交换左右") { viewModel.swapTexts() }
                .buttonStyle(.bordered)
            Button("开始比对") { viewModel.compare() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func textInput(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 170)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct TextDiffRowView: View {
    let row: TextDiffRow

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell(lineNumber: row.leftNumber, text: row.leftText, alignment: .leading)
                Divider()
                    .frame(width: 1)
                cell(lineNumber: row.rightNumber, text: row.rightText, alignment: .leading)
                statusBadge
            }
        }
        .background(row.kind.background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func cell(lineNumber: Int?, text: String?, alignment: Alignment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(lineNumber.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(text ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(text == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 360, alignment: .topLeading)
    }

    private var statusBadge: some View {
        Text(row.kind.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(row.kind.tint)
            .frame(width: 42)
            .padding(.vertical, 6)
    }
}

private struct TextDiffVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct TextDiffWindowControlStrip: View {
    let isPinned: Bool
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextDiffWindowControlDot(color: Color(red: 1.0, green: 0.37, blue: 0.33), action: closeAction)
            TextDiffWindowControlDot(color: Color(red: 1.0, green: 0.74, blue: 0.18), action: minimizeAction)
            TextDiffWindowControlDot(color: Color(red: 0.17, green: 0.80, blue: 0.25), action: zoomAction)
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
private final class TextDiffPanelPinState: ObservableObject {
    @Published var isPinned = false
}

private struct TextDiffWindowControlDot: View {
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
