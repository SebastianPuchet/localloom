import AppKit
import QuartzCore

/// A borderless overlay panel for the window picker — one per display.
///
/// Built on the same rules as `FloatingPanel`, including the one that cost a bug last
/// sprint: `hasShadow = false`. AppKit traces the alpha mask of a borderless, non-opaque
/// window and strokes a hard black contour around it, which on a full-screen overlay would
/// frame every display in black.
///
/// It is **non-activating** and never becomes key, for two reasons. Taking key status would
/// close the menu bar popover the picker was launched from, and — more importantly — it
/// would reshuffle which app is frontmost while the user is choosing, changing the very
/// z-order the picker is reading to decide what is under the cursor.
final class WindowPickerPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        isFloatingPanel = true
        // Above the menu bar and the Dock: selection mode owns the display while it lasts.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                              .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        // Same double guarantee the other overlays get: never captured, whatever filter is
        // in force. `SourceCatalog.makeFilter` excludes our whole application as well.
        sharingType = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The interactive "pick a window" mode: every display is covered by a dimming overlay, the
/// window under the cursor is highlighted with its name, a click selects it, and Escape (or
/// a click on bare desktop) cancels.
///
/// ### It cannot get stuck
/// The worst failure a full-screen overlay can have is eating every click with no way out.
/// That is structurally impossible here: the overlay covers the whole screen, and **every**
/// click on it ends selection mode — over a window it selects, anywhere else it cancels.
/// Escape, a right click and switching apps all end it too, so no single one of those
/// mechanisms is load-bearing.
///
/// ### Why the cursor is polled rather than tracked
/// The panels are non-activating, so `mouseMoved` delivery depends on which app is active
/// and whether the window is key — exactly the things this picker refuses to disturb.
/// `NSEvent.mouseLocation` is a direct read of the window server's cursor position and is
/// true regardless of event routing, so a 60 Hz poll is both simpler and more reliable.
/// The expensive half — enumerating windows — is throttled separately.
@MainActor
final class WindowPickerController {
    static let shared = WindowPickerController()

    private struct Overlay {
        let panel: WindowPickerPanel
        let view: WindowPickerOverlayView
        let screenFrame: CGRect
    }

    private(set) var isActive = false

    private var overlays: [Overlay] = []
    private var completion: ((PickableWindow?) -> Void)?
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Front-to-back window list, refreshed on a throttle rather than on every tick.
    private var windowList: [PickableWindow] = []
    private var lastListRefresh: CFTimeInterval = 0
    private var lastMouse = WindowPickerController.noMouse
    private var current: PickableWindow?

    /// The window we faded out for the duration (the menu bar popover), and its old alpha.
    private weak var dimmedWindow: NSWindow?
    private var dimmedWindowAlpha: CGFloat = 1

    /// How often the window list is re-enumerated while hovering. `CGWindowListCopyWindowInfo`
    /// is cheap next to `SCShareableContent`, but not free, and windows do not move at 60 Hz.
    private let listRefreshInterval: CFTimeInterval = 0.25
    private let pollInterval: TimeInterval = 1.0 / 60.0

    /// How long after the picker opens a loss of focus is ignored. See `installMonitors`.
    fileprivate let deactivationGrace: CFTimeInterval = 1.0
    fileprivate var startedAt: CFTimeInterval = 0

    /// A cursor position no real cursor can hold, so the first tick always renders.
    private static let noMouse = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)

    private init() {}

    // MARK: - Lifecycle

    /// Enters selection mode.
    ///
    /// - Parameters:
    ///   - hiding: a window to fade out for the duration — the menu bar popover, which
    ///     would otherwise sit under the dim wash looking broken. It keeps key status while
    ///     invisible, which is what lets the local Escape monitor see key events at all, and
    ///     it comes back with the new selection already rendered.
    ///   - completion: the chosen window, or nil if the user cancelled.
    func begin(hiding: NSWindow?, completion: @escaping (PickableWindow?) -> Void) {
        guard !isActive else { return }
        isActive = true
        startedAt = CACurrentMediaTime()
        self.completion = completion

        if let hiding {
            dimmedWindow = hiding
            dimmedWindowAlpha = hiding.alphaValue
            hiding.alphaValue = 0
        }

        refreshWindowList()
        buildOverlays()
        installMonitors()
        startPolling()
        tick()
    }

    /// Dismisses without selecting. Safe to call when the picker is not running.
    func cancel() {
        guard isActive else { return }
        finish(with: nil)
    }

    private func finish(with picked: PickableWindow?) {
        guard isActive else { return }
        isActive = false

        pollTimer?.invalidate()
        pollTimer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()

        for overlay in overlays {
            overlay.panel.orderOut(nil)
            overlay.panel.contentView = nil
        }
        overlays.removeAll()
        windowList.removeAll()
        current = nil
        lastMouse = WindowPickerController.noMouse

        dimmedWindow?.alphaValue = dimmedWindowAlpha
        dimmedWindow = nil

        let handler = completion
        completion = nil
        handler?(picked)
    }

    // MARK: - Overlays

    private func buildOverlays() {
        for overlay in overlays { overlay.panel.orderOut(nil) }
        overlays.removeAll()

        for screen in NSScreen.screens {
            let panel = WindowPickerPanel(screen: screen)
            let view = WindowPickerOverlayView(
                frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.screenFrame = screen.frame
            view.onClick = { [weak self] in self?.handleClick() }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.orderFrontRegardless()
            overlays.append(Overlay(panel: panel, view: view, screenFrame: screen.frame))
        }
        // The cursor rects belong to a window that never becomes key; invalidating them
        // once the view is installed is what gets the pointer to change shape.
        for overlay in overlays { overlay.panel.invalidateCursorRects(for: overlay.view) }
    }

    // MARK: - Monitors

    private func installMonitors() {
        // Local monitor: the app is active (the picker is only ever entered from the open
        // popover, which holds key), so key events are delivered to us and Escape is seen
        // here without any window of ours needing to become key.
        let escapeKeyCode: UInt16 = 53
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == escapeKeyCode else { return event }
            let cancelled = MainActor.assumeIsolated { () -> Bool in
                let controller = WindowPickerController.shared
                guard controller.isActive else { return false }
                controller.cancel()
                return true
            }
            return cancelled ? nil : event
        }
        if let local { monitors.append(local) }

        // Belt and braces. Only fires if the user has granted Accessibility, which we never
        // ask for — harmless when it does nothing.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == escapeKeyCode else { return }
            MainActor.assumeIsolated { WindowPickerController.shared.cancel() }
        }
        if let global { monitors.append(global) }

        // Leaving a shielding-level overlay on every display while the user cmd-tabs away
        // would be obnoxious, so losing focus ends selection mode too.
        //
        // The grace period is load-bearing, not a fudge: the picker is entered from the
        // menu bar popover, and an accessory app that loses its last window is deactivated
        // by AppKit as the previous app comes forward. Without the delay that deactivation
        // would cancel the picker in the same breath as opening it.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let controller = WindowPickerController.shared
                guard controller.isActive,
                      CACurrentMediaTime() - controller.startedAt >= controller.deactivationGrace
                else { return }
                controller.cancel()
            }
        })

        // A display plugged in or unplugged mid-pick would leave a screen uncovered, or an
        // overlay hanging over nothing.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let controller = WindowPickerController.shared
                guard controller.isActive else { return }
                controller.buildOverlays()
                controller.lastMouse = WindowPickerController.noMouse
                controller.tick()
            }
        })
    }

    // MARK: - Hover

    private func startPolling() {
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so the poll survives a menu tracking loop or a live window drag.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        guard isActive else { return }
        let now = CACurrentMediaTime()
        if now - lastListRefresh >= listRefreshInterval {
            refreshWindowList()
            lastListRefresh = now
        }

        let mouse = NSEvent.mouseLocation
        let mouseMoved = mouse != lastMouse
        lastMouse = mouse

        let hit = WindowHitTester.window(
            at: ScreenGeometry.cgPoint(fromAppKit: mouse,
                                       primaryHeight: ScreenGeometry.primaryHeight),
            in: windowList)
        guard mouseMoved || hit != current else { return }
        current = hit
        render(hit: hit, mouse: mouse)
    }

    private func refreshWindowList() {
        windowList = WindowHitTester.snapshot(
            excludingPIDs: [ProcessInfo.processInfo.processIdentifier])
    }

    private func render(hit: PickableWindow?, mouse: CGPoint) {
        let appKitFrame = hit.map {
            ScreenGeometry.appKitRect(
                fromCG: $0.cgFrame, primaryHeight: ScreenGeometry.primaryHeight)
        }
        let icon = hit?.icon
        for overlay in overlays {
            overlay.view.highlight = appKitFrame
            overlay.view.title = hit?.displayName
            overlay.view.subtitle = hit.map { $0.displayName == $0.appName ? "" : $0.appName }
                .flatMap { $0.isEmpty ? nil : $0 }
            overlay.view.icon = icon
            overlay.view.showsHint = overlay.screenFrame.contains(mouse)
        }
    }

    private func handleClick() {
        // Clicking bare desktop selects nothing, and "nothing" is not a recordable source —
        // so it cancels rather than silently clearing the user's previous choice.
        finish(with: current)
    }
}
