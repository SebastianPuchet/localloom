import AppKit
import SwiftUI

/// The LocalLoom mark for the menu bar: a screen outline with the webcam bubble notched
/// into its lower-left corner, matching AppIcon.
///
/// Drawn into an NSImage with Core Graphics rather than composed as a SwiftUI view.
/// A `MenuBarExtra` label renders through an NSStatusItem button, where blend modes and
/// GeometryReader collapse to nothing — an earlier SwiftUI version produced an invisible
/// icon. The full-colour AppIcon is unusable here for a different reason: it is an
/// illegible blob below about 64px and cannot tint for light/dark or the recording state.
private enum Mark {
    static let idle: NSImage = draw(color: .black, template: true)
    static let recording: NSImage = draw(color: .systemRed, template: false)
    static let paused: NSImage = draw(color: .systemOrange, template: false)

    private static func draw(color: NSColor, template: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let w = rect.width, h = rect.height
            let line: CGFloat = 1.5
            let bubble = h * 0.60

            ctx.setLineWidth(line)
            ctx.setStrokeColor(color.cgColor)

            // Screen: occupies the upper-right, inset to leave room for the bubble.
            let screen = CGRect(x: w * 0.24 + line / 2,
                                y: h * 0.24 + line / 2,
                                width: w * 0.76 - line,
                                height: h * 0.76 - line)
            ctx.addPath(CGPath(roundedRect: screen,
                               cornerWidth: h * 0.16, cornerHeight: h * 0.16,
                               transform: nil))
            ctx.strokePath()

            // Clear a gap so the bubble reads as sitting in front of the screen.
            let centre = CGPoint(x: bubble / 2, y: bubble / 2)
            let gap = bubble + line * 2.5
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: centre.x - gap / 2, y: centre.y - gap / 2,
                                       width: gap, height: gap))
            ctx.setBlendMode(.normal)

            ctx.setStrokeColor(color.cgColor)
            ctx.strokeEllipse(in: CGRect(x: centre.x - bubble / 2 + line / 2,
                                         y: centre.y - bubble / 2 + line / 2,
                                         width: bubble - line, height: bubble - line))
            return true
        }
        image.isTemplate = template
        return image
    }
}

struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        switch coordinator.state {
        case .recording:
            Image(nsImage: Mark.recording).accessibilityLabel("LocalLoom — recording")
        case .paused:
            Image(nsImage: Mark.paused).accessibilityLabel("LocalLoom — paused")
        default:
            Image(nsImage: Mark.idle).accessibilityLabel("LocalLoom")
        }
    }
}
