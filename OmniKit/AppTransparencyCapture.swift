//
//  AppTransparencyCapture.swift
//  OmniKit
//

import AppKit
import CoreImage
import ScreenCaptureKit

@MainActor
final class AppTransparencyCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let targetID: CGWindowID
    private let displayID: CGDirectDisplayID
    private let pixelSize: CGSize
    private let onFrame: (CGImage) -> Void
    private let onFailure: () -> Void
    nonisolated private let context = CIContext()
    private var stream: SCStream?
    private var stopped = false
    private var hasFrame = false

    init(targetID: CGWindowID, displayID: CGDirectDisplayID, pixelSize: CGSize,
         onFrame: @escaping (CGImage) -> Void, onFailure: @escaping () -> Void) {
        self.targetID = targetID
        self.displayID = displayID
        self.pixelSize = pixelSize
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if !content.windows.contains(where: { $0.windowID == self.targetID }) ||
                    !content.applications.contains(where: { $0.processID == getpid() }) {
                    try await Task.sleep(for: .milliseconds(350))
                    guard !self.stopped else { return }
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                guard !self.stopped else { return }
                guard let display = content.displays.first(where: { $0.displayID == self.displayID }),
                      let target = content.windows.first(where: { $0.windowID == self.targetID }),
                      let ownApp = content.applications.first(where: { $0.processID == getpid() }) else {
                    throw CaptureError.contentUnavailable
                }
                let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [target])
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(self.pixelSize.width))
                configuration.height = max(1, Int(self.pixelSize.height))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.lch.OmniKit.transparency.capture"))
                self.stream = stream
                try await stream.startCapture()
                if self.stopped {
                    try? await stream.stopCapture()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, !self.stopped, !self.hasFrame else { return }
                        self.onFailure()
                    }
                }
            } catch {
                if !self.stopped { self.onFailure() }
            }
        }
    }

    func stop() {
        stopped = true
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue) else { return }
        if status == .blank || status == .suspended || status == .stopped {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onFailure()
            }
            return
        }
        guard status == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let frame = context.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.hasFrame = true
            self.onFrame(frame)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onFailure()
        }
    }

    private enum CaptureError: Error { case contentUnavailable }
}
