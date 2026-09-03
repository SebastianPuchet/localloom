import Foundation

/// Remembers the last-used source, camera and microphone across launches.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let sourceID = "lastSourceID"
        static let cameraID = "lastCameraID"
        static let microphoneID = "lastMicrophoneID"
    }

    /// `SourceID.rawValue`, e.g. "display:1" or "window:4213".
    static var sourceID: String? {
        get { defaults.string(forKey: Key.sourceID) }
        set { defaults.set(newValue, forKey: Key.sourceID) }
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
}
