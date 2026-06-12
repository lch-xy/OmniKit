//
//  ImagePanelManager.swift
//  OmniKit
//

import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageToolType: String, CaseIterable, Identifiable {
    case compress
    case formatConvert
    case flip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress:
            return "图片压缩"
        case .formatConvert:
            return "格式转换"
        case .flip:
            return "图片翻转"
        }
    }
}

enum ImageOutputFormat: String, CaseIterable, Identifiable {
    case jpeg
    case png
    case tiff
    case heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg:
            return "JPEG"
        case .png:
            return "PNG"
        case .tiff:
            return "TIFF"
        case .heic:
            return "HEIC"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        case .tiff:
            return .tiff
        case .heic:
            return .heic
        }
    }

    var fileExtension: String {
        utType.preferredFilenameExtension ?? rawValue
    }

    static func from(fileExtension: String) -> ImageOutputFormat? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return .jpeg
        case "png":
            return .png
        case "tif", "tiff":
            return .tiff
        case "heic":
            return .heic
        default:
            return nil
        }
    }
}

enum ImageFlipDirection: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal:
            return "水平翻转"
        case .vertical:
            return "垂直翻转"
        }
    }
}

enum ImageProcessingError: LocalizedError {
    case imageNotSelected
    case imageLoadFailed
    case unsupportedFormat
    case exportFailed(String)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .imageNotSelected:
            return "请先选择图片。"
        case .imageLoadFailed:
            return "图片读取失败。"
        case .unsupportedFormat:
            return "当前图片格式暂不支持该操作。"
        case let .exportFailed(message):
            return "导出失败：\(message)"
        case .conversionFailed:
            return "图片处理失败。"
        }
    }
}

@MainActor
final class ImagePanelManager: ObservableObject {
    private enum HotKeyActionID {
        static let toggleImagePanel: UInt32 = 300
    }

    private let settings: ImageSettingsStore
    private let hotKeyManager = HotKeyManager()
    private let pinState = ImagePanelPinState()

    private var panel: ImageFloatingPanel?
    private var viewModel: ImagePanelViewModel?

    init(settings: ImageSettingsStore) {
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
            shortcuts: [HotKeyActionID.toggleImagePanel: settings.imageShortcut]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let vm = ImagePanelViewModel()
            viewModel = vm

            let newPanel = ImageFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
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
            newPanel.center()
            newPanel.contentView = NSHostingView(
                rootView: ImageQuickPanelView(
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

private final class ImageFloatingPanel: NSPanel {
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
final class ImagePanelViewModel: ObservableObject {
    @Published var selectedTool: ImageToolType = .compress
    @Published var compressionQuality: Double = 0.72
    @Published var conversionFormat: ImageOutputFormat = .png
    @Published var flipDirection: ImageFlipDirection = .horizontal
    @Published var sourceImage: NSImage?
    @Published var resultImage: NSImage?
    @Published var statusMessage = ""
    @Published var statusTint: Color = .secondary
    @Published var sourceSummary = "尚未选择图片"
    @Published var resultSummary = "处理后的图片会显示在这里"

    private var sourceURL: URL?
    private var sourceData: Data?
    private var sourceFormat: ImageOutputFormat?
    private var sourceFileExtension: String?
    private var resultData: Data?
    private var resultFormat: ImageOutputFormat = .png
    private var resultFileExtension: String = ImageOutputFormat.png.fileExtension

    func prepareForDisplay() {
        if sourceImage == nil {
            statusMessage = ""
            statusTint = .secondary
        }
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP, .gif, .bmp]
        panel.prompt = "选择图片"
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    func importImageFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            sourceImage = image
            resultImage = nil
            sourceURL = nil
            sourceData = image.tiffRepresentation
            sourceFormat = nil
            sourceFileExtension = nil
            resultData = nil
            resultFileExtension = resultFormat.fileExtension
            sourceSummary = describe(imageData: sourceData, fallbackTitle: "来自剪贴板")
            resultSummary = "处理后的图片会显示在这里"
            statusMessage = "已从剪贴板导入图片"
            statusTint = .green
        } else {
            statusMessage = "剪贴板中没有图片"
            statusTint = .orange
        }
    }

    func clearImages() {
        sourceImage = nil
        resultImage = nil
        sourceURL = nil
        sourceData = nil
        sourceFormat = nil
        sourceFileExtension = nil
        resultData = nil
        resultFileExtension = ImageOutputFormat.png.fileExtension
        sourceSummary = "尚未选择图片"
        resultSummary = "处理后的图片会显示在这里"
        statusMessage = ""
        statusTint = .secondary
    }

    func runProcessing() {
        guard let sourceImage else {
            statusMessage = ImageProcessingError.imageNotSelected.localizedDescription
            statusTint = .orange
            return
        }
        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusMessage = ImageProcessingError.imageLoadFailed.localizedDescription
            statusTint = .red
            return
        }

        do {
            let processed: (image: NSImage, data: Data, format: ImageOutputFormat, summary: String)
            switch selectedTool {
            case .compress:
                processed = try processCompression(cgImage)
            case .formatConvert:
                processed = try processFormatConversion(cgImage)
            case .flip:
                processed = try processFlip(cgImage)
            }

            resultImage = processed.image
            resultData = processed.data
            resultFormat = processed.format
            resultFileExtension = resolvedResultFileExtension(for: processed.format)
            resultSummary = processed.summary
            statusMessage = "处理完成"
            statusTint = .green
        } catch {
            resultImage = nil
            resultData = nil
            resultSummary = "处理后的图片会显示在这里"
            statusMessage = error.localizedDescription
            statusTint = .red
        }
    }

    func exportResult() {
        guard let resultData else {
            statusMessage = "请先执行图片处理"
            statusTint = .orange
            return
        }
        writeResultData(resultData, to: suggestedOutputURL())
    }

    func copyResultImage() {
        guard let resultImage else {
            statusMessage = "请先执行图片处理"
            statusTint = .orange
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([resultImage])
        statusMessage = "结果图片已复制"
        statusTint = .green
    }

    var optionLabel: String {
        switch selectedTool {
        case .compress:
            return "压缩强度"
        case .formatConvert:
            return "目标格式"
        case .flip:
            return "翻转方向"
        }
    }

    var toolHint: String {
        switch selectedTool {
        case .compress:
            return "通过重新编码压缩图片，质量越低体积越小。"
        case .formatConvert:
            return "将当前图片转换为新的输出格式。"
        case .flip:
            return "对图片进行水平或垂直翻转。"
        }
    }

    private func loadImage(from url: URL) {
        do {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data) else {
                throw ImageProcessingError.imageLoadFailed
            }
            sourceImage = image
            resultImage = nil
            sourceURL = url
            sourceData = data
            sourceFormat = ImageOutputFormat.from(fileExtension: url.pathExtension)
            sourceFileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
            resultData = nil
            resultFileExtension = resolvedResultFileExtension(for: sourceFormat ?? .png)
            sourceSummary = describe(imageData: data, fallbackTitle: url.lastPathComponent, cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            resultSummary = "处理后的图片会显示在这里"
            statusMessage = "已载入 \(url.lastPathComponent)"
            statusTint = .green
        } catch {
            statusMessage = error.localizedDescription
            statusTint = .red
        }
    }

    private func processCompression(_ cgImage: CGImage) throws -> (NSImage, Data, ImageOutputFormat, String) {
        let outputFormat = sourceFormat ?? .jpeg
        let data = try compressedData(cgImage: cgImage, format: outputFormat, preferredQuality: compressionQuality)
        guard let image = NSImage(data: data) else {
            throw ImageProcessingError.conversionFailed
        }

        let sourceSize = sourceData?.count ?? 0
        let ratio = sourceSize > 0 ? Double(data.count) / Double(sourceSize) : 0
        let summary = "\(outputFormat.title) 压缩后 \(formatBytes(data.count))，约为原图的 \(Int(ratio * 100))%"
        return (image, data, outputFormat, summary)
    }

    private func processFormatConversion(_ cgImage: CGImage) throws -> (NSImage, Data, ImageOutputFormat, String) {
        let quality: CGFloat = conversionFormat == .jpeg || conversionFormat == .heic ? 0.9 : 1.0
        let data = try encode(cgImage: cgImage, format: conversionFormat, quality: quality)
        guard let image = NSImage(data: data) else {
            throw ImageProcessingError.conversionFailed
        }
        let summary = "\(conversionFormat.title) 格式，\(formatBytes(data.count))"
        return (image, data, conversionFormat, summary)
    }

    private func processFlip(_ cgImage: CGImage) throws -> (NSImage, Data, ImageOutputFormat, String) {
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessingError.conversionFailed
        }

        context.interpolationQuality = .high
        if flipDirection == .horizontal {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let outputCGImage = context.makeImage() else {
            throw ImageProcessingError.conversionFailed
        }

        let data = try encode(cgImage: outputCGImage, format: .png, quality: 1.0)
        guard let image = NSImage(data: data) else {
            throw ImageProcessingError.conversionFailed
        }
        return (image, data, .png, "\(flipDirection.title)，\(formatBytes(data.count))")
    }

    private func encode(cgImage: CGImage, format: ImageOutputFormat, quality: CGFloat) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, format.utType.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.unsupportedFormat
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.conversionFailed
        }
        return mutableData as Data
    }

    private func compressedData(cgImage: CGImage, format: ImageOutputFormat, preferredQuality: Double) throws -> Data {
        let targetQuality = CGFloat(preferredQuality)
        let originalSize = sourceData?.count ?? .max

        if format == .jpeg || format == .heic {
            var bestData = try encode(cgImage: cgImage, format: format, quality: targetQuality)
            if bestData.count < originalSize {
                return bestData
            }

            var quality = targetQuality
            while quality > 0.12 {
                quality -= 0.08
                let candidate = try encode(cgImage: cgImage, format: format, quality: max(0.1, quality))
                if candidate.count < bestData.count {
                    bestData = candidate
                }
                if candidate.count < originalSize {
                    return candidate
                }
            }
            return bestData
        }

        return try encode(cgImage: cgImage, format: format, quality: targetQuality)
    }

    private func suggestedOutputName() -> String {
        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "image-output"
        return "\(baseName)-\(selectedTool.rawValue).\(resultFileExtension)"
    }

    private func suggestedOutputURL() -> URL {
        let directory = sourceURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "image-output"
        let ext = resultFileExtension
        var candidate = directory.appendingPathComponent("\(baseName)-\(selectedTool.rawValue)").appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(selectedTool.rawValue)-\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private func resolvedResultFileExtension(for format: ImageOutputFormat) -> String {
        if format == .jpeg, let sourceFileExtension {
            let normalized = sourceFileExtension.lowercased()
            if normalized == "jpg" || normalized == "jpeg" {
                return normalized
            }
        }
        if format == .tiff, let sourceFileExtension {
            let normalized = sourceFileExtension.lowercased()
            if normalized == "tif" || normalized == "tiff" {
                return normalized
            }
        }
        return format.fileExtension
    }

    private func writeResultData(_ data: Data, to destinationURL: URL) {
        do {
            let hasSecurityAccess = sourceURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if hasSecurityAccess {
                    sourceURL?.stopAccessingSecurityScopedResource()
                }
            }
            try data.write(to: destinationURL)
            statusMessage = "已导出到 \(destinationURL.lastPathComponent)"
            statusTint = .green
        } catch {
            statusMessage = ImageProcessingError.exportFailed(error.localizedDescription).localizedDescription
            statusTint = .red
        }
    }

    private func describe(imageData: Data?, fallbackTitle: String, cgImage: CGImage? = nil) -> String {
        let pixelLabel: String
        if let cgImage {
            pixelLabel = "\(cgImage.width)×\(cgImage.height)"
        } else {
            pixelLabel = "未知尺寸"
        }
        let sizeLabel = imageData.map { formatBytes($0.count) } ?? "--"
        return "\(fallbackTitle) · \(pixelLabel) · \(sizeLabel)"
    }

    private func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}

private struct ImageQuickPanelView: View {
    @ObservedObject var viewModel: ImagePanelViewModel
    @ObservedObject var pinState: ImagePanelPinState
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        ZStack {
            ImageVisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ImageWindowControlStrip(
                            isPinned: pinState.isPinned,
                            closeAction: closeAction,
                            minimizeAction: minimizeAction,
                            zoomAction: zoomAction,
                            togglePinAction: togglePinAction
                        )

                        Spacer(minLength: 8)

                        Text("功能")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $viewModel.selectedTool) {
                            ForEach(ImageToolType.allCases) { tool in
                                Text(tool.title).tag(tool)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }

                    HStack(alignment: .center) {
                        Text(viewModel.optionLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()

                        switch viewModel.selectedTool {
                        case .compress:
                            HStack(spacing: 12) {
                                Slider(value: $viewModel.compressionQuality, in: 0.2...0.95)
                                    .frame(width: 180)
                                Text("\(Int(viewModel.compressionQuality * 100))%")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        case .formatConvert:
                            Picker("", selection: $viewModel.conversionFormat) {
                                ForEach(ImageOutputFormat.allCases) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                        case .flip:
                            Picker("", selection: $viewModel.flipDirection) {
                                ForEach(ImageFlipDirection.allCases) { direction in
                                    Text(direction.title).tag(direction)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                HStack(alignment: .top, spacing: 12) {
                    ImagePreviewCard(
                        title: "原图",
                        summary: viewModel.sourceSummary,
                        image: viewModel.sourceImage,
                        emptyText: "选择图片或从剪贴板导入"
                    )

                    ImagePreviewCard(
                        title: "结果",
                        summary: viewModel.resultSummary,
                        image: viewModel.resultImage,
                        emptyText: "执行后在这里预览结果"
                    )
                }
                .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    SettingsInfoBadge(text: viewModel.toolHint, tint: .secondary)
                    if !viewModel.statusMessage.isEmpty {
                        SettingsInfoBadge(text: viewModel.statusMessage, tint: viewModel.statusTint)
                    }
                    Spacer()
                    Button("选择图片") { viewModel.importImage() }
                        .buttonStyle(.bordered)
                    Button("从剪贴板导入") { viewModel.importImageFromPasteboard() }
                        .buttonStyle(.bordered)
                    Button("清空") { viewModel.clearImages() }
                        .buttonStyle(.bordered)
                    Button("执行") { viewModel.runProcessing() }
                        .buttonStyle(.borderedProminent)
                    Button("复制结果") { viewModel.copyResultImage() }
                        .buttonStyle(.bordered)
                    Button("导出") { viewModel.exportResult() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImagePreviewCard: View {
    let title: String
    let summary: String
    let image: NSImage?
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 430)

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ImageWindowControlStrip: View {
    let isPinned: Bool
    let closeAction: () -> Void
    let minimizeAction: () -> Void
    let zoomAction: () -> Void
    let togglePinAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ImageWindowControlDot(color: Color(red: 1.0, green: 0.37, blue: 0.33), action: closeAction)
            ImageWindowControlDot(color: Color(red: 1.0, green: 0.74, blue: 0.18), action: minimizeAction)
            ImageWindowControlDot(color: Color(red: 0.17, green: 0.80, blue: 0.25), action: zoomAction)
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
private final class ImagePanelPinState: ObservableObject {
    @Published var isPinned = false
}

private struct ImageWindowControlDot: View {
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
