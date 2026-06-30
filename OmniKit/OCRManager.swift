//
//  OCRManager.swift
//  OmniKit
//
//  Created by Codex on 2026/4/14.
//

import AppKit
import Combine
import SwiftUI
import Vision

enum OCRFlowError: LocalizedError {
    case screenshotCancelled
    case screenshotFailed(String)
    case imageNotFound
    case imageConversionFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .screenshotCancelled:
            return "已取消截图。"
        case let .screenshotFailed(message):
            return "截图失败：\(message)"
        case .imageNotFound:
            return "未读取到截图内容，请重试。"
        case .imageConversionFailed:
            return "截图格式不支持 OCR。"
        case .emptyResult:
            return "未识别到文本。"
        }
    }
}

@MainActor
final class OCRManager: ObservableObject {
    private enum HotKeyActionID {
        static let screenshotOCR: UInt32 = 100
    }

    @Published var isRecognizing = false
    @Published var lastRecognizedText = ""
    @Published var lastStatusMessage = ""

    private let settings: OCRSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let recognitionService = AppleOCRService()
    private var resultPanel: OCRResultPreviewPanel?
    private var resultViewModel: OCRResultPreviewViewModel?

    init(settings: OCRSettingsStore) {
        self.settings = settings
        registerShortcut()
    }

    func updateShortcut() {
        registerShortcut()
    }

    func suspendShortcut() {
        hotKeyManager.unregister()
    }

    func triggerOCR() {
        guard !isRecognizing else { return }
        isRecognizing = true
        lastStatusMessage = "请框选截图区域..."

        Task {
            defer {
                Task { @MainActor in
                    self.isRecognizing = false
                }
            }

            do {
                try await runInteractiveScreenCaptureToClipboard()
                let image = try readImageFromPasteboard()
                let text = try await recognitionService.recognizeText(from: image)
                await MainActor.run {
                    lastRecognizedText = text
                    lastStatusMessage = "识别完成，结果已复制到剪贴板。"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if settings.shouldPreviewResult {
                        presentResultPreview(text)
                    }
                }
            } catch {
                await MainActor.run {
                    lastStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func presentResultPreview(_ text: String) {
        if resultPanel == nil {
            let vm = OCRResultPreviewViewModel(text: text)
            resultViewModel = vm

            let newPanel = OCRResultPreviewPanel(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                styleMask: [.borderless, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isMovableByWindowBackground = true
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.minSize = NSSize(width: 560, height: 360)
            newPanel.contentView = NSHostingView(
                rootView: OCRResultPreviewView(
                    viewModel: vm,
                    closeAction: { [weak newPanel] in newPanel?.close() },
                    minimizeAction: { [weak newPanel] in newPanel?.omniKitMiniaturize() },
                    zoomAction: { [weak newPanel] in newPanel?.omniKitToggleZoom() }
                )
            )
            resultPanel = newPanel
        } else {
            resultViewModel?.text = text
            resultViewModel?.statusMessage = ""
        }

        NSApp.activate(ignoringOtherApps: true)
        resultPanel?.center()
        resultPanel?.orderFrontRegardless()
        resultPanel?.makeKeyAndOrderFront(nil)
    }

    private func registerShortcut() {
        hotKeyManager.register(
            shortcuts: [HotKeyActionID.screenshotOCR: settings.ocrShortcut]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.triggerOCR()
            }
        }
    }

    private func readImageFromPasteboard() throws -> NSImage {
        let pasteboard = NSPasteboard.general
        guard
            let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        else {
            throw OCRFlowError.imageNotFound
        }
        return image
    }

    private func runInteractiveScreenCaptureToClipboard() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-c", "-x"]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                    return
                }
                if process.terminationStatus == 1 {
                    continuation.resume(throwing: OCRFlowError.screenshotCancelled)
                    return
                }
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(throwing: OCRFlowError.screenshotFailed(output.isEmpty ? "未知错误" : output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: OCRFlowError.screenshotFailed(error.localizedDescription))
            }
        }
    }
}

private final class OCRResultPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
}

@MainActor
private final class OCRResultPreviewViewModel: ObservableObject {
    @Published var text: String
    @Published var statusMessage = ""

    init(text: String) {
        self.text = text
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "已复制"
    }
}

private struct OCRResultPreviewView: View {
    @ObservedObject var viewModel: OCRResultPreviewViewModel
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void

    var body: some View {
        ZStack {
            OCRResultVisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    OCRResultWindowControlDot(color: Color(red: 1.0, green: 0.37, blue: 0.33), action: closeAction)
                    OCRResultWindowControlDot(color: Color(red: 1.0, green: 0.74, blue: 0.18), action: minimizeAction)
                    OCRResultWindowControlDot(color: Color(red: 0.17, green: 0.80, blue: 0.25), action: zoomAction)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("OCR 识别结果")
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        if !viewModel.statusMessage.isEmpty {
                            SettingsInfoBadge(text: viewModel.statusMessage, tint: .green)
                        }
                    }

                    TextEditor(text: $viewModel.text)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Button("关闭") {
                            closeAction()
                        }
                        Button("复制结果") {
                            viewModel.copyResult()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct OCRResultVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}

private struct OCRResultWindowControlDot: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

struct AppleOCRService {
    func recognizeText(from image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRFlowError.imageConversionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    continuation.resume(throwing: OCRFlowError.emptyResult)
                } else {
                    continuation.resume(returning: content)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
