import SwiftUI

/// The LocalLoom mark, drawn as a monochrome glyph: a screen outline with the webcam
/// bubble notched into its lower-left corner. Drawn rather than loaded from AppIcon.icns
/// because a colour raster cannot tint for light/dark or for the recording state, and the
/// full-colour mark is illegible at menu bar size.
private struct MarkShape: View {
    /// Stroke weight, in points, at the nominal 18x14 glyph size.
    private let line: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bubble = h * 0.62
            // The screen is inset from the left/bottom to leave room for the bubble.
            let screen = CGRect(x: w * 0.22, y: 0, width: w * 0.78, height: h * 0.78)
            let centre = CGPoint(x: bubble / 2, y: h - bubble / 2)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .stroke(lineWidth: line)
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: screen.minX, y: screen.minY)

                // Punch a gap so the bubble reads as sitting in front of the screen.
                Circle()
                    .frame(width: bubble + line * 2.5, height: bubble + line * 2.5)
                    .offset(x: centre.x - (bubble + line * 2.5) / 2,
                            y: centre.y - (bubble + line * 2.5) / 2)
                    .blendMode(.destinationOut)

                Circle()
                    .stroke(lineWidth: line)
                    .frame(width: bubble, height: bubble)
                    .offset(x: centre.x - bubble / 2, y: centre.y - bubble / 2)
            }
            .compositingGroup()
        }
        .frame(width: 18, height: 14)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        switch coordinator.state {
        case .recording:
            MarkShape()
                .foregroundStyle(.red)
                .accessibilityLabel("LocalLoom — recording")
        case .paused:
            MarkShape()
                .foregroundStyle(.orange)
                .accessibilityLabel("LocalLoom — paused")
        default:
            MarkShape()
                .accessibilityLabel("LocalLoom")
        }
    }
}
