//
//  ClipboardPanelManager.swift
//  OmniKit
//

import AppKit
import ApplicationServices
import Combine
import CryptoKit
import SwiftUI

enum ClipboardEntryKind: String, Codable, CaseIterable, Identifiable {
    case text
    case code
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            return "文本"
        case .code:
            return "代码"
        case .image:
            return "图片"
        case .file:
            return "文件"
        }
    }

    var systemImage: String {
        switch self {
        case .text:
            return "doc.text"
        case .code:
            return "curlybraces.square"
        case .image:
            return "photo"
        case .file:
            return "folder"
        }
    }
}

enum ClipboardFilterKind: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case code
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .text:
            return "文本"
        case .image:
            return "图片"
        case .code:
            return "代码"
        case .file:
            return "文件"
        }
    }

    func matches(_ kind: ClipboardEntryKind) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            return kind == .text
        case .image:
            return kind == .image
        case .code:
            return kind == .code
        case .file:
            return kind == .file
        }
    }
}

struct ClipboardHistoryEntry: Identifiable, Equatable {
    let id: UUID
    var kind: ClipboardEntryKind
    var title: String
    var preview: String
    var fullText: String?
    var imageData: Data?
    var filePaths: [String]
    var copiedAt: Date
    var lastUsedAt: Date?
    var usageCount: Int
    var isPinned: Bool
    let fingerprint: String
    let searchBlob: String
    let transliteratedBlob: String
    let initialsBlob: String
}

@MainActor
final class ClipboardPanelManager: ObservableObject {
    private enum HotKeyActionID {
        static let toggleClipboardPanel: UInt32 = 400
    }

    private let settings: ClipboardSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let pinState = ClipboardPanelPinState()
    private let pasteboard = NSPasteboard.general
    private let viewModel = ClipboardPanelViewModel()

    private var panel: ClipboardFloatingPanel?
    private var pasteboardChangeCount: Int
    private var pasteboardMonitor: AnyCancellable?
    private var lastTargetApplication: NSRunningApplication?

    init(settings: ClipboardSettingsStore) {
        self.settings = settings
        pasteboardChangeCount = pasteboard.changeCount
        registerShortcut()
        startMonitoringPasteboard()
        capturePasteboardIfNeeded(force: true)
    }

    var totalCount: Int { viewModel.entries.count }
    var pinnedCount: Int { viewModel.entries.filter(\.isPinned).count }

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

    func clearUnpinnedEntries() {
        viewModel.clearUnpinned()
    }

    private func registerShortcut() {
        hotKeyManager.register(
            shortcuts: [HotKeyActionID.toggleClipboardPanel: settings.clipboardShortcut]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    private func startMonitoringPasteboard() {
        pasteboardMonitor = Timer.publish(every: 0.8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.capturePasteboardIfNeeded()
            }
    }

    private func capturePasteboardIfNeeded(force: Bool = false) {
        guard force || pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        guard let entry = makeHistoryEntry(from: pasteboard) else { return }
        viewModel.ingest(entry)
    }

    private func showPanel() {
        if panel == nil {
            let newPanel = ClipboardFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
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
            newPanel.minSize = NSSize(width: 980, height: 640)
            newPanel.submitAction = { [weak self] in
                self?.pasteSelectedEntry()
            }
            newPanel.moveSelectionAction = { [weak self] delta in
                self?.viewModel.moveSelection(by: delta)
            }
            newPanel.deleteSelectionAction = { [weak self] in
                self?.viewModel.deleteSelected()
            }
            newPanel.center()
            newPanel.contentView = NSHostingView(
                rootView: ClipboardQuickPanelView(
                    viewModel: viewModel,
                    pinState: pinState,
                    closeAction: { [weak newPanel] in newPanel?.close() },
                    minimizeAction: { [weak newPanel] in newPanel?.performMiniaturize(nil) },
                    zoomAction: { [weak newPanel] in newPanel?.performZoom(nil) },
                    togglePinAction: { [weak self, weak newPanel] in
                        guard let self else { return }
                        self.pinState.isPinned.toggle()
                        newPanel?.applyPinnedState(self.pinState.isPinned)
                    },
                    pasteSelectedAction: { [weak self] in
                        self?.pasteSelectedEntry()
                    },
                    pasteEntryAction: { [weak self] entry in
                        self?.pasteEntry(entry)
                    }
                )
            )
            panel = newPanel
        }

        capturePasteboardIfNeeded(force: true)
        viewModel.prepareForDisplay()
        lastTargetApplication = frontmostExternalApplication()
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.orderFrontRegardless()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func pasteSelectedEntry() {
        guard let entry = viewModel.selectedEntry else { return }
        pasteEntry(entry)
    }

    private func pasteEntry(_ entry: ClipboardHistoryEntry) {
        guard writeToPasteboard(entry) else {
            viewModel.setStatus("当前记录无法重新写回剪贴板", tint: .red)
            return
        }

        viewModel.markUsed(entry.id)

        guard AXIsProcessTrusted() else {
            viewModel.setStatus("请在系统设置中授予辅助功能权限后再使用自动粘贴", tint: .orange)
            return
        }

        panel?.orderOut(nil)
        lastTargetApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.postPasteCommand()
        }
    }

    private func writeToPasteboard(_ entry: ClipboardHistoryEntry) -> Bool {
        pasteboard.clearContents()

        switch entry.kind {
        case .text, .code:
            guard let text = entry.fullText, !text.isEmpty else { return false }
            return pasteboard.setString(text, forType: .string)
        case .image:
            guard let imageData = entry.imageData, let image = NSImage(data: imageData) else {
                return false
            }
            return pasteboard.writeObjects([image])
        case .file:
            let urls = entry.filePaths.map(URL.init(fileURLWithPath:))
            guard !urls.isEmpty else { return false }
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    private func postPasteCommand() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func frontmostExternalApplication() -> NSRunningApplication? {
        let currentBundleID = Bundle.main.bundleIdentifier
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != currentBundleID else { return nil }
        return app
    }

    private func makeHistoryEntry(from pasteboard: NSPasteboard) -> ClipboardHistoryEntry? {
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map(\.path)
            let title = fileURLs.count == 1 ? fileURLs[0].lastPathComponent : "\(fileURLs.count) 个文件"
            let preview = paths.prefix(3).joined(separator: "\n")
            let searchable = ([title, preview] + paths).joined(separator: "\n")
            return ClipboardHistoryEntry(
                id: UUID(),
                kind: .file,
                title: title,
                preview: preview,
                fullText: nil,
                imageData: nil,
                filePaths: paths,
                copiedAt: Date(),
                lastUsedAt: nil,
                usageCount: 0,
                isPinned: false,
                fingerprint: "file:" + sha256(paths.sorted().joined(separator: "|")),
                searchBlob: normalizeSearch(searchable),
                transliteratedBlob: transliteratedSearch(searchable),
                initialsBlob: transliteratedInitials(searchable)
            )
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let data = pngData(for: image) ?? image.tiffRepresentation {
            let size = image.size
            let title = "图片 \(Int(size.width))×\(Int(size.height))"
            let preview = "来自剪贴板"
            let searchable = "\(title) \(preview)"
            return ClipboardHistoryEntry(
                id: UUID(),
                kind: .image,
                title: title,
                preview: preview,
                fullText: nil,
                imageData: data,
                filePaths: [],
                copiedAt: Date(),
                lastUsedAt: nil,
                usageCount: 0,
                isPinned: false,
                fingerprint: "image:" + sha256(data),
                searchBlob: normalizeSearch(searchable),
                transliteratedBlob: transliteratedSearch(searchable),
                initialsBlob: transliteratedInitials(searchable)
            )
        }

        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return nil
        }

        let kind: ClipboardEntryKind = isCodeSnippet(text) ? .code : .text
        let title = makeTextTitle(from: text)
        let preview = makeTextPreview(from: text)
        let searchable = [title, preview, text].joined(separator: "\n")
        return ClipboardHistoryEntry(
            id: UUID(),
            kind: kind,
            title: title,
            preview: preview,
            fullText: text,
            imageData: nil,
            filePaths: [],
            copiedAt: Date(),
            lastUsedAt: nil,
            usageCount: 0,
            isPinned: false,
            fingerprint: "\(kind.rawValue):" + sha256(text),
            searchBlob: normalizeSearch(searchable),
            transliteratedBlob: transliteratedSearch(searchable),
            initialsBlob: transliteratedInitials(searchable)
        )
    }
}

private final class ClipboardFloatingPanel: NSPanel {
    var submitAction: (() -> Void)?
    var moveSelectionAction: ((Int) -> Void)?
    var deleteSelectionAction: (() -> Void)?

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

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty {
            switch event.keyCode {
            case 125:
                moveSelectionAction?(1)
                return
            case 126:
                moveSelectionAction?(-1)
                return
            case 36:
                submitAction?()
                return
            case 51:
                deleteSelectionAction?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
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
final class ClipboardPanelViewModel: ObservableObject {
    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    @Published var searchQuery = "" {
        didSet { refreshSelection() }
    }
    @Published var selectedFilter: ClipboardFilterKind = .all {
        didSet { refreshSelection() }
    }
    @Published var selectedEntryID: ClipboardHistoryEntry.ID? {
        didSet { syncSelectionFromVisibleList() }
    }
    @Published var statusMessage = ""
    @Published var statusTint: Color = .secondary

    var filteredEntries: [ClipboardHistoryEntry] {
        let query = normalizeSearch(searchQuery)
        return entries
            .filter { entry in
                selectedFilter.matches(entry.kind) && matches(entry, query: query)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                let leftRank = matchRank(for: lhs, query: query)
                let rightRank = matchRank(for: rhs, query: query)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                let leftDate = lhs.lastUsedAt ?? lhs.copiedAt
                let rightDate = rhs.lastUsedAt ?? rhs.copiedAt
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }
                return lhs.copiedAt > rhs.copiedAt
            }
    }

    var selectedEntry: ClipboardHistoryEntry? {
        guard let selectedEntryID else { return filteredEntries.first }
        return filteredEntries.first(where: { $0.id == selectedEntryID })
    }

    func prepareForDisplay() {
        refreshSelection()
        if statusMessage.isEmpty {
            statusTint = .secondary
        }
    }

    func ingest(_ incomingEntry: ClipboardHistoryEntry) {
        if let existingIndex = entries.firstIndex(where: { $0.fingerprint == incomingEntry.fingerprint }) {
            var existing = entries.remove(at: existingIndex)
            existing.kind = incomingEntry.kind
            existing.title = incomingEntry.title
            existing.preview = incomingEntry.preview
            existing.fullText = incomingEntry.fullText
            existing.imageData = incomingEntry.imageData
            existing.filePaths = incomingEntry.filePaths
            existing.copiedAt = incomingEntry.copiedAt
            entries.insert(existing, at: 0)
        } else {
            entries.insert(incomingEntry, at: 0)
        }

        trimEntries()
        refreshSelection()
    }

    func togglePinned(_ entryID: ClipboardHistoryEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].isPinned.toggle()
        refreshSelection()
    }

    func deleteEntry(_ entryID: ClipboardHistoryEntry.ID) {
        entries.removeAll { $0.id == entryID }
        refreshSelection()
    }

    func deleteSelected() {
        guard let selectedEntryID else { return }
        deleteEntry(selectedEntryID)
    }

    func clearUnpinned() {
        entries.removeAll { !$0.isPinned }
        refreshSelection()
    }

    func markUsed(_ entryID: ClipboardHistoryEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].lastUsedAt = Date()
        entries[index].usageCount += 1
        selectedEntryID = entryID
        refreshSelection()
    }

    func moveSelection(by delta: Int) {
        let visibleEntries = filteredEntries
        guard !visibleEntries.isEmpty else {
            selectedEntryID = nil
            return
        }

        guard let selectedEntryID,
              let currentIndex = visibleEntries.firstIndex(where: { $0.id == selectedEntryID }) else {
            selectedEntryID = visibleEntries.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + delta, 0), visibleEntries.count - 1)
        self.selectedEntryID = visibleEntries[nextIndex].id
    }

    func setStatus(_ message: String, tint: Color) {
        statusMessage = message
        statusTint = tint
    }

    private func refreshSelection() {
        let visibleEntries = filteredEntries
        if visibleEntries.isEmpty {
            selectedEntryID = nil
            return
        }
        if let selectedEntryID,
           visibleEntries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = visibleEntries.first?.id
    }

    private func syncSelectionFromVisibleList() {
        guard let selectedEntryID else { return }
        if !filteredEntries.contains(where: { $0.id == selectedEntryID }) {
            refreshSelection()
        }
    }

    private func trimEntries(maxCount: Int = 120) {
        while entries.count > maxCount {
            if let index = entries.lastIndex(where: { !$0.isPinned }) {
                entries.remove(at: index)
            } else {
                break
            }
        }
    }

    private func matches(_ entry: ClipboardHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.searchBlob.contains(query)
            || entry.transliteratedBlob.contains(query)
            || entry.initialsBlob.contains(query)
    }

    private func matchRank(for entry: ClipboardHistoryEntry, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        if normalizeSearch(entry.title).contains(query) {
            return 0
        }
        if normalizeSearch(entry.preview).contains(query) || entry.searchBlob.contains(query) {
            return 1
        }
        if entry.transliteratedBlob.contains(query) {
            return 2
        }
        if entry.initialsBlob.contains(query) {
            return 3
        }
        return 9
    }
}

private struct ClipboardQuickPanelView: View {
    @ObservedObject var viewModel: ClipboardPanelViewModel
    @ObservedObject var pinState: ClipboardPanelPinState
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void
    let pasteSelectedAction: () -> Void
    let pasteEntryAction: (ClipboardHistoryEntry) -> Void

    var body: some View {
        ZStack {
            ClipboardVisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ClipboardWindowControlStrip(
                            isPinned: pinState.isPinned,
                            closeAction: closeAction,
                            minimizeAction: minimizeAction,
                            zoomAction: zoomAction,
                            togglePinAction: togglePinAction
                        )

                        Spacer(minLength: 12)

                        TextField("搜索文本、代码、文件名、拼音或关键词", text: $viewModel.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)

                        Picker("", selection: $viewModel.selectedFilter) {
                            ForEach(ClipboardFilterKind.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                        .labelsHidden()
                    }

                    HStack(spacing: 10) {
                        SettingsInfoBadge(
                            text: "共 \(viewModel.filteredEntries.count) 条记录，支持上下键选择与回车粘贴",
                            tint: .secondary
                        )
                        if !viewModel.statusMessage.isEmpty {
                            SettingsInfoBadge(text: viewModel.statusMessage, tint: viewModel.statusTint)
                        }
                        Spacer()
                        Button("删除所选") {
                            viewModel.deleteSelected()
                        }
                        .buttonStyle(.bordered)
                        Button("清空未固定") {
                            viewModel.clearUnpinned()
                        }
                        .buttonStyle(.bordered)
                        Button("粘贴所选") {
                            pasteSelectedAction()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack(spacing: 12) {
                    ClipboardHistoryListView(
                        entries: viewModel.filteredEntries,
                        selectedEntryID: $viewModel.selectedEntryID,
                        searchQuery: viewModel.searchQuery,
                        togglePinnedAction: { entryID in
                            viewModel.togglePinned(entryID)
                        },
                        deleteEntryAction: { entryID in
                            viewModel.deleteEntry(entryID)
                        }
                    )
                    .frame(minWidth: 430, maxWidth: 470)

                    ClipboardDetailView(
                        entry: viewModel.selectedEntry,
                        searchQuery: viewModel.searchQuery,
                        pasteEntryAction: pasteEntryAction,
                        togglePinnedAction: { entryID in
                            viewModel.togglePinned(entryID)
                        },
                        deleteEntryAction: { entryID in
                            viewModel.deleteEntry(entryID)
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardHistoryListView: View {
    let entries: [ClipboardHistoryEntry]
    @Binding var selectedEntryID: ClipboardHistoryEntry.ID?
    let searchQuery: String
    let togglePinnedAction: (ClipboardHistoryEntry.ID) -> Void
    let deleteEntryAction: (ClipboardHistoryEntry.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("历史记录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            List(selection: $selectedEntryID) {
                ForEach(entries) { entry in
                    ClipboardHistoryRow(
                        entry: entry,
                        searchQuery: searchQuery,
                        selectAction: {
                            selectedEntryID = entry.id
                        },
                        pinAction: {
                            togglePinnedAction(entry.id)
                        },
                        deleteAction: {
                            deleteEntryAction(entry.id)
                        }
                    )
                    .tag(entry.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardHistoryEntry
    let searchQuery: String
    let selectAction: () -> Void
    let pinAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: selectAction) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.kind.systemImage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        HighlightedText(text: entry.title, query: searchQuery, font: .system(size: 13, weight: .semibold), color: .primary)
                            .lineLimit(1)

                        HighlightedText(text: entry.preview, query: searchQuery, font: .system(size: 11), color: .secondary)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            Text(entry.kind.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(relativeDateText(from: entry.lastUsedAt ?? entry.copiedAt))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Button(action: pinAction) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)

                Button(action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ClipboardDetailView: View {
    let entry: ClipboardHistoryEntry?
    let searchQuery: String
    let pasteEntryAction: (ClipboardHistoryEntry) -> Void
    let togglePinnedAction: (ClipboardHistoryEntry.ID) -> Void
    let deleteEntryAction: (ClipboardHistoryEntry.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("详情")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Group {
                if let entry {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            Label(entry.kind.title, systemImage: entry.kind.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(entry.isPinned ? "取消固定" : "固定") {
                                togglePinnedAction(entry.id)
                            }
                            .buttonStyle(.bordered)
                            Button("删除") {
                                deleteEntryAction(entry.id)
                            }
                            .buttonStyle(.bordered)
                            Button("粘贴到当前应用") {
                                pasteEntryAction(entry)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        HighlightedText(text: entry.title, query: searchQuery, font: .system(size: 16, weight: .semibold), color: .primary)
                            .lineLimit(2)

                        Text(detailMetaText(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Divider()

                        detailContent(for: entry)
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text("还没有可显示的剪贴板记录")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func detailContent(for entry: ClipboardHistoryEntry) -> some View {
        switch entry.kind {
        case .text, .code:
            ScrollView {
                Text(entry.fullText ?? entry.preview)
                    .font(.system(size: 12, design: entry.kind == .code ? .monospaced : .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 4)
            }
        case .image:
            if let imageData = entry.imageData, let image = NSImage(data: imageData) {
                GeometryReader { proxy in
                    VStack {
                        Spacer(minLength: 0)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: proxy.size.width - 8, maxHeight: proxy.size.height - 8)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("图片预览不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entry.filePaths, id: \.self) { path in
                        Label(path, systemImage: "doc")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
    }

    private func detailMetaText(for entry: ClipboardHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let copiedAt = formatter.string(from: entry.copiedAt)
        let usedAt = entry.lastUsedAt.map { formatter.string(from: $0) } ?? "未使用"
        return "复制于 \(copiedAt) · 最近粘贴 \(usedAt) · 使用 \(entry.usageCount) 次"
    }
}

private struct HighlightedText: View {
    let text: String
    let query: String
    let font: Font
    let color: Color

    var body: some View {
        if let highlighted = highlightedText() {
            highlighted
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
        }
    }

    private func highlightedText() -> Text? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty,
              let range = text.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let prefix = String(text[..<range.lowerBound])
        let matched = String(text[range])
        let suffix = String(text[range.upperBound...])

        return Text(prefix)
            .font(font)
            .foregroundStyle(color)
        + Text(matched)
            .font(font.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        + Text(suffix)
            .font(font)
            .foregroundStyle(color)
    }
}

private struct ClipboardVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ClipboardWindowControlStrip: View {
    let isPinned: Bool
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: closeAction) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.37, blue: 0.33))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Button(action: minimizeAction) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Button(action: zoomAction) {
                Circle()
                    .fill(Color(red: 0.16, green: 0.82, blue: 0.33))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Button(action: togglePinAction) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消固定在最前" : "固定在最前")
        }
    }
}

private final class ClipboardPanelPinState: ObservableObject {
    @Published var isPinned = false
}

private func makeTextTitle(from text: String) -> String {
    let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return truncate(lines.first ?? text, limit: 70)
}

private func makeTextPreview(from text: String) -> String {
    let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if lines.count > 1 {
        return truncate(lines.dropFirst().joined(separator: " "), limit: 120)
    }
    return truncate(text, limit: 120)
}

private func isCodeSnippet(_ text: String) -> Bool {
    let lineBreakCount = text.filter { $0 == "\n" }.count
    let codeHints = [
        "import ", "func ", "class ", "struct ", "let ", "var ", "const ",
        "return ", "=>", "{", "}", "</", "SELECT ", "INSERT ", "UPDATE "
    ]
    let containsHint = codeHints.contains { text.localizedCaseInsensitiveContains($0) }
    let punctuationScore = text.filter { "{}();<>[]".contains($0) }.count
    return containsHint || lineBreakCount >= 2 || punctuationScore >= 6
}

private func normalizeSearch(_ text: String) -> String {
    text
        .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func transliteratedSearch(_ text: String) -> String {
    let latin = mutableLatinText(from: text)
    return latin.replacingOccurrences(of: " ", with: "")
}

private func transliteratedInitials(_ text: String) -> String {
    let latin = mutableLatinText(from: text)
    return latin
        .split(separator: " ")
        .compactMap(\.first)
        .map(String.init)
        .joined()
}

private func mutableLatinText(from text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return normalizeSearch(mutable as String)
}

private func truncate(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
}

private func sha256(_ text: String) -> String {
    sha256(Data(text.utf8))
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func pngData(for image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

private func relativeDateText(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.localizedString(for: date, relativeTo: Date())
}
