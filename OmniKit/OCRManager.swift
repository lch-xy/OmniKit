//
//  OCRManager.swift
//  OmniKit
//
//  Created by Codex on 2026/4/14.
//

import AppKit
import Combine
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
                }
            } catch {
                await MainActor.run {
                    lastStatusMessage = error.localizedDescription
                }
            }
        }
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
