import CoreGraphics
import Foundation

/// Remembers the last-used source, camera and microphone across launches.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let sourceID = "lastSourceID"
        static let cameraID = "lastCameraID"
        static let microphoneID = "lastMicrophoneID"
        static let windowName = "lastWindowName"
        static let bubbleX = "bubblePositionX"
        static let bubbleY = "bubblePositionY"
        static let controlBarX = "controlBarOriginX"
        static let controlBarY = "controlBarOriginY"
    }

    /// `SourceID.rawValue`, e.g. "display:1" or "window:4213".
    static var sourceID: String? {
        get { defaults.string(forKey: Key.sourceID) }
        set { defaults.set(newValue, forKey: Key.sourceID) }
    }

    /// Human-readable name of the window chosen with the picker.
    ///
    /// Window ids are not stable across relaunches of the app that owns them, so this is a
    /// label to show in the popover, not an identifier. `SourceID` remains the identity.
    static var windowName: String? {
        get { defaults.string(forKey: Key.windowName) }
        set { defaults.set(newValue, forKey: Key.windowName) }
    }

    /// `AVCaptureDevice.uniqueID`, or nil for "no camera".
    static var cameraID: String? {
        get { defaults.string(forKey: Key.cameraID) }
        set { defaults.set(newValue, forKey: Key.cameraID) }
    }

    /// `AVCaptureDevice.uniqueID`, or nil for "no microphone".
    static var microphoneID: String? {
        get { defaults.string(forKey: Key.microphoneID) }
        set { defaults.set(newValue, forKey: Key.microphoneID) }
    }

    /// Normalized (0...1, bottom-left origin) centre of the webcam bubble. Driven by
    /// dragging the floating camera circle, and read by the compositor so the recorded
    /// frame matches what the user placed on screen.
    static var bubblePosition: CGPoint {
        get {
            guard defaults.object(forKey: Key.bubbleX) != nil,
                  defaults.object(forKey: Key.bubbleY) != nil
            else { return RecordingSettings.defaultBubblePosition }
            return CGPoint(
                x: min(max(defaults.double(forKey: Key.bubbleX), 0), 1),
                y: min(max(defaults.double(forKey: Key.bubbleY), 0), 1))
        }
        set {
            defaults.set(min(max(newValue.x, 0), 1), forKey: Key.bubbleX)
            defaults.set(min(max(newValue.y, 0), 1), forKey: Key.bubbleY)
        }
    }

    /// Bottom-left origin of the floating control bar, in AppKit screen coordinates.
    /// Nil until the user drags it somewhere.
    static var controlBarOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.controlBarX) != nil,
                  defaults.object(forKey: Key.controlBarY) != nil
            else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Key.controlBarX),
                y: defaults.double(forKey: Key.controlBarY))
        }
        set {
            guard let newValue else { return }
            defaults.set(newValue.x, forKey: Key.controlBarX)
            defaults.set(newValue.y, forKey: Key.controlBarY)
        }
    }
}
