import Foundation
import CoreGraphics

/// Static tuning for the capture + encode pipeline. Deliberately not user-facing in v1.
enum RecordingSettings {
    /// Target capture frame rate.
    static let framesPerSecond: Int = 30

    /// SCStream buffer pool depth. 6-8 keeps SCK from starving while we composite.
    static let queueDepth: Int = 6

    /// Diameter of the webcam bubble, in output pixels. Capped so a full-screen recording
    /// gets a reasonable bubble, and proportional so recording a small window does not get
    /// a bubble that swallows it.
    static func bubbleDiameter(width: Int, height: Int) -> CGFloat {
        min(320, CGFloat(min(width, height)) * 0.22)
    }

    /// Inset of the bubble from the bottom-left corner of the frame, in output pixels.
    static func bubbleInset(diameter: CGFloat) -> CGFloat { diameter * 0.15 }

    /// Width of the white ring drawn around the bubble, in output pixels.
    static let bubbleRingWidth: CGFloat = 4

    /// If no `.complete` screen frame arrives within this interval, the watchdog
    /// re-appends the last composited buffer so the movie does not silently truncate.
    static let stallInterval: TimeInterval = 0.5

    /// Refuse to start a recording when the output volume has less free space than this.
    static let minimumFreeBytesToStart: Int64 = 2 * 1024 * 1024 * 1024

    /// Auto-stop a running recording when free space drops below this.
    static let minimumFreeBytesToContinue: Int64 = 500 * 1024 * 1024

    /// How often the free-space poll runs while recording.
    static let diskPollInterval: TimeInterval = 10

    /// ~8 Mbps at 1080p30, scaled by pixel count.
    static func bitrate(width: Int, height: Int) -> Int {
        let pixels = Double(width * height)
        let scale = pixels / (1920.0 * 1080.0)
        return max(2_000_000, min(40_000_000, Int(8_000_000 * scale)))
    }

    /// ~/Movies/LocalLoom, created on demand.
    static func outputDirectory() throws -> URL {
        let movies = try FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = movies.appendingPathComponent("LocalLoom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "LocalLoom \(formatter.string(from: Date())).mp4"
        return try outputDirectory().appendingPathComponent(name)
    }
}
