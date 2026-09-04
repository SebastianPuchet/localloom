import AVFoundation
import Foundation
import ScreenCaptureKit

/// Stable, persistable identifier for a capture source.
enum SourceID: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)

    var rawValue: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .window(let id): return "window:\(id)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let number = UInt32(parts[1]) else { return nil }
        switch parts[0] {
        case "display": self = .display(number)
        case "window": self = .window(number)
        default: return nil
        }
    }
}

struct CaptureSource: Identifiable, Hashable {
    let id: SourceID
    let name: String
    let isDisplay: Bool
}

struct CaptureDevice: Identifiable, Hashable {
    /// `AVCaptureDevice.uniqueID`.
    let id: String
    let name: String
}

/// Enumerates shareable displays and A/V input devices.
///
/// Windows are deliberately **not** enumerated here. A list of every window on the machine
/// is a poor way to choose one — the names collide, the order is arbitrary and half the
/// entries are things nobody meant to record. `WindowPickerController` asks the user to
/// point at the window instead, and hands back a `SourceID.window`; `makeFilter` resolves
/// that id to an `SCWindow` when the recording starts.
@MainActor
final class SourceCatalog: ObservableObject {
    @Published private(set) var displays: [CaptureSource] = []
    @Published private(set) var cameras: [CaptureDevice] = []
    @Published private(set) var microphones: [CaptureDevice] = []
    /// Non-nil when `SCShareableContent` failed, usually because Screen Recording is denied.
    @Published private(set) var lastError: String?

    /// Retained so a filter can be rebuilt without a second `SCShareableContent` fetch.
    private var content: SCShareableContent?

    func refresh() async {
        refreshDevices()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            self.content = content
            displays = content.displays.enumerated().map { index, display in
                CaptureSource(
                    id: .display(display.displayID),
                    name: "Display \(index + 1) (\(display.width)×\(display.height))",
                    isDisplay: true)
            }
            lastError = nil
        } catch {
            displays = []
            content = nil
            lastError = (error as NSError).localizedDescription
        }
    }

    /// Device-only refresh, cheap enough to run on a hot-plug notification.
    func refreshDevices() {
        let cameraSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        cameras = cameraSession.devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }

        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        microphones = micSession.devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Builds the content filter for a source.
    ///
    /// Always refetches shareable content: the floating control panel and camera circle are
    /// created moments before this runs, and a cached window list would not contain them —
    /// which is exactly how overlays end up burned into the movie.
    func makeFilter(for id: SourceID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        self.content = content
        let bundleID = Bundle.main.bundleIdentifier
        switch id {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CatalogError.sourceGone
            }
            // Excluding the whole application also covers windows that appear *after* the
            // filter is built, which excluding a fixed window list would not.
            if let ownApp = content.applications.first(where: {
                $0.bundleIdentifier == bundleID
            }) {
                return SCContentFilter(
                    display: display, excludingApplications: [ownApp], exceptingWindows: [])
            }
            let ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CatalogError.sourceGone
            }
            // A single-window filter never contains anything else, overlays included.
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    enum CatalogError: LocalizedError {
        case sourceGone
        var errorDescription: String? {
            "That display or window is no longer available. Pick another source."
        }
    }
}
