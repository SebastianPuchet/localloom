import AppKit
import SwiftUI

/// A borderless, always-on-top panel used for the on-screen recording controls and the
/// camera circle.
///
/// It is a **non-activating** panel on purpose: clicking it must not deactivate whatever
/// the user is recording, or every click would flash their app's title bar in the movie.
/// `canBecomeKey` stays false for the same reason — mouse events still arrive, keyboard
/// focus never moves.
final class FloatingPanel: NSPanel {
    /// Fired after the user drags the window, with the new frame.
    var onMove: ((NSRect) -> Void)?

    init(size: NSSize, draggable: Bool) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                              .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = draggable
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Keep it off screenshots-of-the-app lists as far as AppKit allows; the real
        // exclusion happens in the SCContentFilter.
        sharingType = .none

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove(_:)),
            name: NSWindow.didMoveNotification, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setContent<Content: View>(_ content: Content) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: frame.size)
        contentView = host
    }

    @objc private func didMove(_ notification: Notification) {
        onMove?(frame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Borderless windows refuse to accept mouse events unless they say otherwise.
    override var acceptsFirstResponder: Bool { true }
}
