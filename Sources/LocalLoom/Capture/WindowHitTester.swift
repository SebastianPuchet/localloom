import AppKit
import CoreGraphics

/// Converts between the two coordinate spaces macOS uses for on-screen geometry.
///
/// **CoreGraphics display space** — `kCGWindowBounds`, `SCWindow.frame`, `CGDisplayBounds`
/// — has its origin at the **top-left of the primary display**, with y increasing
/// **downward**, measured in points.
///
/// **AppKit space** — `NSScreen.frame`, `NSWindow.frame`, `NSEvent.mouseLocation` — has its
/// origin at the **bottom-left of the primary display**, with y increasing **upward**.
///
/// The flip is against the height of the *primary* display: the screen whose origin is
/// `(0, 0)`. It is **not** `NSScreen.main`, which is merely the screen that currently has
/// keyboard focus and can be any display in the arrangement. On a single-display Mac the
/// two are always the same screen, which is exactly why using `main` here is a bug that
/// stays invisible until a second monitor is plugged in.
///
/// The rect conversion is its own inverse (`y' = H - y - height` either way), so one
/// implementation serves both directions.
enum ScreenGeometry {
    /// The screen whose origin is `(0, 0)`. AppKit documents `NSScreen.screens.first` as
    /// that screen; the explicit search is a cheap guard in case that ever stops holding.
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
    }

    /// Height of the primary display, in points — the axis every flip is measured against.
    static var primaryHeight: CGFloat { primaryScreen?.frame.height ?? 0 }

    /// CoreGraphics display rect → AppKit screen rect.
    static func appKitRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// AppKit screen rect → CoreGraphics display rect. Same arithmetic; the flip is an
    /// involution.
    static func cgRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// AppKit screen point (e.g. `NSEvent.mouseLocation`) → CoreGraphics display point.
    static func cgPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// CoreGraphics display point → AppKit screen point.
    static func appKitPoint(fromCG point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

/// One on-screen window that the picker is allowed to target.
///
/// `cgFrame` is kept in CoreGraphics display space because that is what
/// `CGWindowListCopyWindowInfo` and `SCWindow.frame` both speak; it is converted to AppKit
/// space only at the moment something has to be drawn.
struct PickableWindow: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    /// CoreGraphics display space: top-left origin, y down.
    let cgFrame: CGRect
    /// `kCGWindowName`. Requires the Screen Recording grant; nil without it.
    let title: String?
    /// `kCGWindowOwnerName`, available with no permission at all.
    let appName: String

    /// What the picker shows. Falls back to the app name when the window has no title of
    /// its own, or when we have no Screen Recording grant to read titles with.
    var displayName: String {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return appName
        }
        return title
    }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: ownerPID)?.icon
    }
}

/// Finds the window under the cursor, the way the system's own window picker does.
///
/// `SCShareableContent.windows` has **no guaranteed z-order**, so it cannot answer "which
/// window is on top here". `CGWindowListCopyWindowInfo` does: it returns windows **front to
/// back**, so the first frame that contains the cursor is the one the user is pointing at.
/// The `CGWindowID` it yields is the same number as `SCWindow.windowID`, so the result maps
/// straight onto a `SourceID.window` with no ScreenCaptureKit call on the hover path.
enum WindowHitTester {
    /// Window layers we treat as pickable. Ordinary document windows are layer 0; a few
    /// legitimate app surfaces (utility palettes, torn-off menus, modal sheets, floating
    /// inspectors) sit just above it. The Dock (20), the menu bar (24) and status windows
    /// (25) are far higher, and the desktop sits at a large negative layer, so a narrow
    /// band keeps real app windows without dragging system furniture in.
    static let pickableLayers: ClosedRange<Int> = 0...8

    /// Windows smaller than this in either dimension are helper/shadow windows, not
    /// something a person means to record.
    static let minimumSide: CGFloat = 40

    /// Every pickable window, front to back.
    ///
    /// - Parameter excludingPIDs: processes whose windows must never be targets. LocalLoom
    ///   always passes its own PID: the picker overlays, the floating control bar and the
    ///   camera bubble are all our windows and are lying on top of everything, so without
    ///   this the picker would only ever be able to select itself.
    static func snapshot(excludingPIDs: Set<pid_t>) -> [PickableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        return raw.compactMap { info -> PickableWindow? in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }

            guard !excludingPIDs.contains(pid) else { return nil }
            guard pickableLayers.contains(layer) else { return nil }
            guard frame.width >= minimumSide, frame.height >= minimumSide else { return nil }
            // A fully transparent window is still "on screen" as far as the window server
            // is concerned, but there is nothing there to point at.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                return nil
            }

            let appName = info[kCGWindowOwnerName as String] as? String ?? "Window"
            return PickableWindow(
                windowID: number, ownerPID: pid, cgFrame: frame,
                title: info[kCGWindowName as String] as? String, appName: appName)
        }
    }

    /// The frontmost window containing `point`, or nil over bare desktop.
    ///
    /// `list` must be in front-to-back order — i.e. straight out of `snapshot`.
    static func window(at point: CGPoint, in list: [PickableWindow]) -> PickableWindow? {
        list.first { $0.cgFrame.contains(point) }
    }

    /// Whether a window id is still on screen. Used to validate a remembered selection
    /// without paying for a `SCShareableContent` fetch.
    static func windowExists(_ windowID: CGWindowID) -> Bool {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID) as? [[String: Any]]
        else { return false }
        return raw.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// Best-effort name for a window id, for restoring a label after a relaunch.
    static func name(of windowID: CGWindowID) -> String? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID) as? [[String: Any]],
            let info = raw.first(where: {
                ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
            })
        else { return nil }
        let title = info[kCGWindowName as String] as? String
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return info[kCGWindowOwnerName as String] as? String
    }
}
