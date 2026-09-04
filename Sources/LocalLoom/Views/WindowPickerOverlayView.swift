import AppKit

/// The full-screen drawing for the window picker: one of these fills each display.
///
/// Deliberately Core Graphics rather than SwiftUI. The whole surface is one geometric
/// composition — a dim wash with a hole punched in it — and the hole has to land on a rect
/// derived from window-server coordinates to the pixel. Expressing that as a view tree
/// would add a layout pass between the number and the pixels for no benefit.
final class WindowPickerOverlayView: NSView {
    /// Called on a left click anywhere on the overlay.
    var onClick: (() -> Void)?
    /// Called on a right click or a two-finger click — always a cancel.
    var onCancel: (() -> Void)?

    /// This view's screen, in AppKit global coordinates. Everything drawn is offset by its
    /// origin to get into the view's own space.
    var screenFrame: CGRect = .zero

    /// The highlighted window in AppKit global coordinates, or nil when the cursor is over
    /// bare desktop.
    var highlight: CGRect? {
        didSet { if highlight != oldValue { needsDisplay = true } }
    }
    var title: String? {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    var subtitle: String? {
        didSet { if subtitle != oldValue { needsDisplay = true } }
    }
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    /// True on the display the cursor is currently on: only that one carries the hint, so
    /// a three-monitor setup does not shout the same sentence three times.
    var showsHint: Bool = false {
        didSet { if showsHint != oldValue { needsDisplay = true } }
    }

    // MARK: - Appearance constants

    private let dimAlpha: CGFloat = 0.34
    private let cornerRadius: CGFloat = 10
    private let borderWidth: CGFloat = 3

    // MARK: - Drawing

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Dim the whole display, so whatever is highlighted next reads as "chosen"
        //    rather than merely "outlined".
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        bounds.fill()

        if let local = localHighlight {
            let path = NSBezierPath(
                roundedRect: local, xRadius: cornerRadius, yRadius: cornerRadius)

            // 2. Punch the dim wash back out over the target so it shows at full
            //    brightness. `.clear` on a non-opaque window erases to transparent.
            context.saveGState()
            context.setBlendMode(.clear)
            path.fill()
            context.restoreGState()

            // 3. A light accent wash plus a solid accent border.
            LoomTheme.accentColor.withAlphaComponent(0.16).setFill()
            path.fill()

            let border = NSBezierPath(
                roundedRect: local.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                xRadius: cornerRadius, yRadius: cornerRadius)
            border.lineWidth = borderWidth
            LoomTheme.accentColor.setStroke()
            border.stroke()

            drawTitleChip(for: local)
        }

        if showsHint { drawHint() }
    }

    /// The highlight in this view's own coordinates, clipped to the view. Nil when the
    /// target window is entirely on another display.
    private var localHighlight: CGRect? {
        guard let highlight else { return nil }
        let local = highlight.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.intersects(bounds) else { return nil }
        return local
    }

    // MARK: - Title chip

    private func drawTitleChip(for highlight: CGRect) {
        guard let title else { return }
        let iconSide: CGFloat = 26
        let hPad: CGFloat = 13
        let vPad: CGFloat = 10
        let gap: CGFloat = 10

        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let subtitleText = subtitle.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.62),
            ])
        }

        let iconWidth = icon == nil ? 0 : iconSide + gap
        let natural = max(titleText.size().width, subtitleText?.size().width ?? 0)
        let available = max(160, min(bounds.width - 48, 460)) - hPad * 2 - iconWidth
        let textWidth = ceil(min(natural, available))
        let titleHeight = ceil(titleText.size().height)
        let subtitleHeight = subtitleText.map { ceil($0.size().height) + 2 } ?? 0
        let textHeight = titleHeight + subtitleHeight

        let chipSize = CGSize(
            width: hPad * 2 + iconWidth + textWidth,
            height: max(iconSide, textHeight) + vPad * 2)

        var origin = CGPoint(
            x: highlight.midX - chipSize.width / 2,
            y: highlight.midY - chipSize.height / 2)
        // A chip floating in the middle of a small window covers the thing being chosen.
        // Park it just outside instead, above if there is no room below.
        if highlight.height < chipSize.height + 40 || highlight.width < chipSize.width + 24 {
            origin.y = highlight.minY - chipSize.height - 10
            if origin.y < 12 { origin.y = highlight.maxY + 10 }
        }
        origin.x = clamp(origin.x, 12, bounds.width - chipSize.width - 12)
        origin.y = clamp(origin.y, 12, bounds.height - chipSize.height - 12)
        let chip = CGRect(origin: origin, size: chipSize)

        fillChip(chip)

        var textX = chip.minX + hPad
        if let icon {
            let iconRect = CGRect(
                x: textX, y: chip.midY - iconSide / 2, width: iconSide, height: iconSide)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            textX += iconSide + gap
        }

        let blockY = chip.midY - textHeight / 2
        titleText.draw(with: CGRect(
            x: textX, y: blockY + subtitleHeight, width: textWidth, height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let subtitleText, subtitleHeight > 0 {
            subtitleText.draw(with: CGRect(
                x: textX, y: blockY, width: textWidth, height: subtitleHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: - Hint

    private func drawHint() {
        let text = NSAttributedString(
            string: highlight == nil
                ? "Move over a window to choose it  ·  esc to cancel"
                : "Click to record this window  ·  esc to cancel",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ])
        let size = text.size()
        let chip = CGRect(
            x: (bounds.width - size.width - 36) / 2, y: 44,
            width: ceil(size.width) + 36, height: ceil(size.height) + 20)
        fillChip(chip)
        text.draw(at: CGPoint(x: chip.minX + 18, y: chip.midY - size.height / 2))
    }

    private func fillChip(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(white: 0.06, alpha: 0.88).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }

    // MARK: - Input

    /// The panel is non-activating and never becomes key, so clicks have to be taken on the
    /// first press rather than being spent on activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func otherMouseDown(with event: NSEvent) { onCancel?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
