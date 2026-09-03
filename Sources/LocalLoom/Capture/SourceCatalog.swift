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

/// Enumerates shareable displays/windows and A/V input devices.
@MainActor
final class SourceCatalog: ObservableObject {
    @Published private(set) var sources: [CaptureSource] = []
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
            var list: [CaptureSource] = content.displays.enumerated().map { index, display in
                CaptureSource(
                    id: .display(display.displayID),
                    name: "Display \(index + 1) (\(display.width)×\(display.height))",
                    isDisplay: true)
            }
            let bundleID = Bundle.main.bundleIdentifier
            list += content.windows
                .filter { window in
                    guard let title = window.title, !title.isEmpty else { return false }
                    guard window.frame.width > 120, window.frame.height > 120 else { return false }
                    return window.owningApplication?.bundleIdentifier != bundleID
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .map { window in
                    let app = window.owningApplication?.applicationName ?? "Window"
                    return CaptureSource(
                        id: .window(window.windowID),
                        name: "\(app) — \(window.title ?? "")",
                        isDisplay: false)
                }
            sources = list
            lastError = nil
        } catch {
            sources = []
            content = nil
            lastError = (error as NSError).localizedDescription
        }
    }

    private func refreshDevices() {
        let cameraSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        cameras = cameraSession.devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }

        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        microphones = micSession.devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Builds the content filter for a source, refetching shareable content if needed.
    func makeFilter(for id: SourceID) async throws -> SCContentFilter {
        let content: SCShareableContent
        if let cached = self.content {
            content = cached
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            self.content = content
        }
        switch id {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CatalogError.sourceGone
            }
            let ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CatalogError.sourceGone
            }
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
