import AppKit
import SwiftUI

/// Shared visual language for the popover and the floating overlays, so the three surfaces
/// read as one app. Every colour here is defined for both appearances.
enum LoomTheme {
    /// The one saturated colour in the app. Used for the primary action only.
    static let accent = Color(nsColor: accentColor)
    /// The same colour for the AppKit surfaces — the window picker draws with Core
    /// Graphics, not SwiftUI, so it needs an `NSColor` of exactly this hue.
    static let accentColor = NSColor(srgbRed: 0.36, green: 0.33, blue: 0.95, alpha: 1)
    static let recording = Color(red: 0.95, green: 0.26, blue: 0.30)
    static let paused = Color(red: 0.98, green: 0.68, blue: 0.18)

    /// Hit target for the icon-only buttons. Comfortable for a floating bar the user
    /// clicks mid-recording without looking.
    static let overlayButtonSize: CGFloat = 38
    static let overlayIconSize: CGFloat = 16

    static let cardCorner: CGFloat = 12
    static let rowCorner: CGFloat = 9

    /// Fill behind an icon tile or a selector row.
    static var rowFill: Color { Color.primary.opacity(0.06) }
    static var rowStroke: Color { Color.primary.opacity(0.08) }
}

extension View {
    /// Standard hit target for the icon-only buttons in the floating control bar.
    func overlayButtonFrame() -> some View {
        frame(width: LoomTheme.overlayButtonSize, height: LoomTheme.overlayButtonSize)
    }
}

/// `mm:ss`, or `h:mm:ss` once a recording runs past an hour.
func loomTimeString(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}
