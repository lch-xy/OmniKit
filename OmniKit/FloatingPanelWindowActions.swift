//
//  FloatingPanelWindowActions.swift
//  OmniKit
//

import AppKit
import ObjectiveC

private var zoomRestoreFrameKey: UInt8 = 0

extension NSWindow {
    func omniKitMiniaturize() {
        if styleMask.contains(.miniaturizable) {
            miniaturize(nil)
        } else {
            orderOut(nil)
        }
    }

    func omniKitToggleZoom() {
        if let storedFrame = objc_getAssociatedObject(self, &zoomRestoreFrameKey) as? NSValue {
            setFrame(storedFrame.rectValue, display: true, animate: true)
            objc_setAssociatedObject(self, &zoomRestoreFrameKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        objc_setAssociatedObject(
            self,
            &zoomRestoreFrameKey,
            NSValue(rect: frame),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let insetFrame = visibleFrame.insetBy(dx: 24, dy: 24)
        let targetFrame = NSRect(
            x: insetFrame.minX,
            y: insetFrame.minY,
            width: max(insetFrame.width, minSize.width),
            height: max(insetFrame.height, minSize.height)
        )
        setFrame(targetFrame, display: true, animate: true)
    }
}
