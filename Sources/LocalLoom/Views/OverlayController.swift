import AppKit
import SwiftUI

/// Owns the two floating overlay windows: the recording controls and the camera circle.
///
/// Both are shown while a recording is active *and* while the menu bar popover is open, so
/// the user can place the camera bubble before pressing record. Both are excluded from
/// capture two ways — `NSWindow.sharingType = .none` on the panel itself, and the
/// app-excluding `SCContentFilter` built in `SourceCatalog.makeFilter`. Only the second
/// one matters for our own movies, so `Preferences.overlaysCapturable` can drop the first
/// when the overlays need to show up in *another* recorder's capture.
@MainActor
final class OverlayController {
    static let shared = OverlayController()

    /// Window sizes, not content sizes: each panel keeps `overlayPadding` of clear space
    /// around its content so the SwiftUI shadow has somewhere to land. The window shadow
    /// is off — it drew a hard black outline around the transparent panels.
    static let overlayPadding: CGFloat = 16
    static let controlBarContentSize = CGSize(width: 306, height: 60)
    static var controlBarSize: CGSize {
        CGSize(width: controlBarContentSize.width + overlayPadding * 2,
               height: controlBarContentSize.height + overlayPadding * 2)
    }
    static let cameraDiameter: CGFloat = 190
    static var cameraWindowSize: CGSize {
        CGSize(width: cameraDiameter + overlayPadding * 2,
               height: cameraDiameter + overlayPadding * 2)
    }

    private var controlPanel: FloatingPanel?
    private var cameraPanel: FloatingPanel?
    /// Set while we move a panel ourselves, so the move notification is not read back as
    /// a user drag.
    private var isPositioning = false

    private init() {}

    func update() {
        let coordinator = RecordingCoordinator.shared
        if coordinator.overlaysVisible {
            showControlBar()
        } else {
            controlPanel?.orderOut(nil)
        }
        // No camera, or none selected: no circle at all. Screen-only stays first class.
        if coordinator.overlaysVisible && coordinator.cameraActive
            && coordinator.selectedCameraID != nil {
            showCameraBubble()
        } else {
            cameraPanel?.orderOut(nil)
        }
    }

    func hideAll() {
        controlPanel?.orderOut(nil)
        cameraPanel?.orderOut(nil)
    }

    // MARK: - Control bar

    private func showControlBar() {
        let panel: FloatingPanel
        if let existing = controlPanel {
            panel = existing
        } else {
            panel = FloatingPanel(size: Self.controlBarSize, draggable: true)
            panel.setContent(ControlBarView(coordinator: .shared))
            panel.onMove = { [weak self] frame in
                guard let self, !self.isPositioning else { return }
                Preferences.controlBarOrigin = frame.origin
            }
            controlPanel = panel
            place(panel, at: restoredControlBarOrigin(size: Self.controlBarSize))
        }
        panel.orderFrontRegardless()
    }

    /// The saved spot, if it is still on a screen that exists; otherwise bottom-centre.
    private func restoredControlBarOrigin(size: CGSize) -> CGPoint {
        if let saved = Preferences.controlBarOrigin {
            let rect = CGRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return saved
            }
        }
        let frame = targetScreen.visibleFrame
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 24)
    }

    // MARK: - Camera bubble

    private func showCameraBubble() {
        let panel: FloatingPanel
        if let existing = cameraPanel {
            panel = existing
        } else {
            panel = FloatingPanel(size: Self.cameraWindowSize, draggable: true)
            panel.setContent(CameraBubbleView(frames: RecordingCoordinator.shared.cameraFrames))
            panel.onMove = { [weak self] frame in
                guard let self, !self.isPositioning else { return }
                self.reportBubblePosition(windowFrame: frame)
            }
            cameraPanel = panel
        }
        if !panel.isVisible {
            place(panel, at: bubbleOrigin(size: Self.cameraWindowSize))
        }
        panel.orderFrontRegardless()
    }

    private func bubbleOrigin(size: CGSize) -> CGPoint {
        OverlayGeometry.windowOrigin(
            position: RecordingCoordinator.shared.bubblePosition,
            windowSize: size, screen: targetScreen.frame)
    }

    private func reportBubblePosition(windowFrame: CGRect) {
        let screen = screen(containing: windowFrame) ?? targetScreen
        guard screen.frame.width > 0, screen.frame.height > 0 else { return }
        RecordingCoordinator.shared.bubblePosition = OverlayGeometry.normalizedCentre(
            windowFrame: windowFrame, screen: screen.frame)
    }

    // MARK: - Placement helpers

    private func place(_ panel: FloatingPanel, at origin: CGPoint) {
        isPositioning = true
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        isPositioning = false
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
    }

    /// The display being recorded, when one is selected — that is the screen the bubble's
    /// normalized position is measured against.
    private var targetScreen: NSScreen {
        if case .display(let displayID)? = RecordingCoordinator.shared.selectedSourceID,
           let match = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                   .uint32Value == displayID
           }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}


/// The screen-space ↔ normalized mapping for the camera circle, kept free of AppKit state
/// so it can be reasoned about on its own.
///
/// AppKit screen coordinates and `CIImage` both put the origin at the bottom-left with y
/// increasing upwards, so a normalized position carries from one to the other with no
/// vertical flip. That is the whole trick behind the bubble being WYSIWYG.
enum OverlayGeometry {
    /// Bottom-left origin for a window whose *centre* should sit at `position`.
    static func windowOrigin(
        position: CGPoint, windowSize: CGSize, screen: CGRect
    ) -> CGPoint {
        let centreX = screen.minX + position.x * screen.width
        let centreY = screen.minY + position.y * screen.height
        return CGPoint(
            x: min(max(centreX - windowSize.width / 2, screen.minX),
                   screen.maxX - windowSize.width),
            y: min(max(centreY - windowSize.height / 2, screen.minY),
                   screen.maxY - windowSize.height))
    }

    /// Normalized centre of a window frame within a screen.
    static func normalizedCentre(windowFrame: CGRect, screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((windowFrame.midX - screen.minX) / screen.width, 0), 1),
            y: min(max((windowFrame.midY - screen.minY) / screen.height, 0), 1))
    }
}
