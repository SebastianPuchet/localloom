import Foundation
import CoreGraphics

/// How large the recorded movie is allowed to be. Capping the output is the single
/// biggest lever on file size: a Retina display hands ScreenCaptureKit 20 megapixels per
/// frame, and nobody watches a screen recording above 1080p.
///
/// The cap is a *bounding box*, not a fixed size — the frame keeps the source's aspect
/// ratio and is never letterboxed, and a source smaller than the box is left alone rather
/// than blown up.
enum VideoResolution: String, CaseIterable, Identifiable {
    case fullHD
    case native
    case hd

    static let fallback: VideoResolution = .fullHD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullHD: return "1080p"
        case .native: return "Native"
        case .hd: return "720p"
        }
    }

    var detail: String {
        switch self {
        case .fullHD: return "Recommended"
        case .native: return "Sharpest, largest files"
        case .hd: return "Smallest files"
        }
    }

    /// The box the output frame must fit inside, in pixels. Nil means "no cap".
    var boundingBox: (width: Int, height: Int)? {
        switch self {
        case .fullHD: return (1920, 1080)
        case .native: return nil
        case .hd: return (1280, 720)
        }
    }
}

/// The video codec the movie is encoded with.
///
/// H.264 is the default on purpose. HEVC is roughly 45% smaller for the same picture and
/// is hardware-encoded on Apple Silicon, but H.264 is the format every site, editor and
/// messaging app accepts without argument — which matters more for a recording that is
/// about to be uploaded somewhere.
enum VideoFormat: String, CaseIterable, Identifiable {
    case h264
    case hevc

    static let fallback: VideoFormat = .h264

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var detail: String {
        switch self {
        case .h264: return "Most compatible"
        case .hevc: return "Smaller files"
        }
    }

    /// Target bitrate at 1080p30, scaled by pixel count for everything else.
    ///
    /// 8 Mbps — the old value — is a camera-footage number. A user interface is mostly
    /// flat colour that does not move, so it reaches the same visual quality on a little
    /// over half of that.
    var bitrateAt1080p: Double {
        switch self {
        case .h264: return 4_500_000
        case .hevc: return 2_500_000
        }
    }

    var minimumBitrate: Int {
        switch self {
        case .h264: return 1_200_000
        case .hevc: return 700_000
        }
    }

    var maximumBitrate: Int {
        switch self {
        case .h264: return 24_000_000
        case .hevc: return 14_000_000
        }
    }
}

/// Static tuning for the capture + encode pipeline.
enum RecordingSettings {
    /// Target capture frame rate.
    static let framesPerSecond: Int = 30

    /// SCStream buffer pool depth. 6-8 keeps SCK from starving while we composite.
    static let queueDepth: Int = 6

    /// Diameter of the webcam bubble, in output pixels.
    ///
    /// Purely proportional, with no pixel ceiling: the recorded bubble has to be the same
    /// fraction of the frame whatever the output resolution is, or choosing 1080p instead
    /// of Native would silently resize the bubble the user placed on screen.
    static func bubbleDiameter(width: Int, height: Int) -> CGFloat {
        CGFloat(min(width, height)) * 0.22
    }

    /// Keep-out margin between the bubble and the frame edge, in output pixels.
    static func bubbleMargin(diameter: CGFloat) -> CGFloat { diameter * 0.15 }

    /// Where the bubble sits in the recorded frame, normalized 0...1 on each axis and
    /// measured to the bubble's *centre*. The origin is bottom-left, which is what both
    /// AppKit screen coordinates and `CIImage` use — so a screen-space drag maps across
    /// with no vertical flip. Default is the classic bottom-left corner.
    static let defaultBubblePosition = CGPoint(x: 0.12, y: 0.18)

    /// Bottom-left origin of the bubble, in output pixels, for a normalized centre.
    /// Clamped so the bubble is always fully inside the frame.
    static func bubbleOrigin(
        position: CGPoint, diameter: CGFloat, width: Int, height: Int
    ) -> CGPoint {
        let margin = bubbleMargin(diameter: diameter)
        let maxX = max(margin, CGFloat(width) - diameter - margin)
        let maxY = max(margin, CGFloat(height) - diameter - margin)
        let x = min(max(position.x * CGFloat(width) - diameter / 2, margin), maxX)
        let y = min(max(position.y * CGFloat(height) - diameter / 2, margin), maxY)
        return CGPoint(x: x, y: y)
    }

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

    /// The codec's 1080p target, scaled by pixel count and clamped.
    static func bitrate(width: Int, height: Int, format: VideoFormat) -> Int {
        let scale = Double(width * height) / (1920.0 * 1080.0)
        return max(
            format.minimumBitrate,
            min(format.maximumBitrate, Int(format.bitrateAt1080p * scale)))
    }

    /// Seconds between forced keyframes.
    ///
    /// The old value was 2s. Screen content barely changes between keyframes, so at 2s
    /// most of the file *is* keyframes and the interval, not the picture, sets the size.
    /// 5s cuts the keyframe count by 60%. It is also the point where the tradeoff turns:
    /// a player seeking into the middle of a GOP has to decode from the previous keyframe,
    /// and 5s of near-static screen content decodes instantly, while intervals past ~10s
    /// start to make scrubbing in editors feel sticky and cost more when a frame is lost.
    static let keyFrameIntervalSeconds: Double = 5

    /// Output frame size for a source of `width` x `height` pixels.
    ///
    /// Fits the source inside the resolution's bounding box, preserving its aspect ratio,
    /// never upscaling, and always landing on even dimensions — H.264 and HEVC both
    /// require them.
    static func outputSize(
        width: Int, height: Int, resolution: VideoResolution
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        guard let box = resolution.boundingBox else {
            return (evenDimension(Double(width)), evenDimension(Double(height)))
        }
        let scale = min(
            Double(box.width) / Double(width), Double(box.height) / Double(height))
        // Never upscale: a 900px-tall window stays 900px tall.
        guard scale < 1 else {
            return (evenDimension(Double(width)), evenDimension(Double(height)))
        }
        return (
            evenDimension(Double(width) * scale), evenDimension(Double(height) * scale))
    }

    /// Rounds to the nearest even pixel, with a floor of 2.
    static func evenDimension(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
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
