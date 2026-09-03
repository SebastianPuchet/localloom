import AVFoundation
import AppKit
import CoreGraphics

/// TCC helpers. Screen Recording has no Info.plist key and is re-read by macOS only at
/// process launch, so granting it always requires a relaunch.
enum Permissions {
    enum ScreenStatus {
        /// Never asked. `CGRequestScreenCaptureAccess()` will show the system prompt.
        case notDetermined
        /// Asked and refused, or the toggle is off. Only System Settings can fix it.
        case denied
        case granted
    }

    private static let askedKey = "didRequestScreenCaptureAccess"

    static func screenStatus() -> ScreenStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: askedKey) ? .denied : .notDetermined
    }

    /// One-shot system prompt. Returns immediately; the grant only takes effect on the
    /// next launch, so callers must tell the user to quit and reopen.
    @discardableResult
    static func requestScreenAccess() -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        return CGRequestScreenCaptureAccess()
    }

    static func cameraStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
