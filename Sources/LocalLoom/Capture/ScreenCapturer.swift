import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Wraps one `SCStream`. Screen frames and microphone PCM arrive on the same serial queue
/// and, critically, on the same clock — which is why there is only one writer session.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Composited-and-append hook. Called on the capture queue; must not retain `buffer`.
    var onScreenFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onMicrophoneSample: ((CMSampleBuffer) -> Void)?
    /// Stream died on its own — display unplugged, window closed, user revoked access.
    var onStop: ((Error) -> Void)?

    let width: Int
    let height: Int

    private var stream: SCStream!
    private let queue = DispatchQueue(label: "com.sebastianpuchet.localloom.capture")
    private let capturesMicrophone: Bool

    init(
        filter: SCContentFilter, microphoneID: String?, resolution: VideoResolution
    ) throws {
        // `contentRect` is in points; only `pointPixelScale` gets us real pixels. Never
        // trust SCDisplay.width. Dimensions must be even for H.264 and HEVC.
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let sourceWidth = RecordingSettings.evenDimension(rect.width * scale)
        let sourceHeight = RecordingSettings.evenDimension(rect.height * scale)

        // The downscale happens here, in the stream configuration, rather than in the
        // compositor: ScreenCaptureKit resizes on the GPU while it is already touching
        // the frame, which costs nothing, and every stage after this one — compositing,
        // the pixel buffer pool, the encoder — then works on the smaller frame too.
        let size = RecordingSettings.outputSize(
            width: sourceWidth, height: sourceHeight, resolution: resolution)
        width = size.width
        height = size.height
        let isDownscaled = width < sourceWidth || height < sourceHeight

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(RecordingSettings.framesPerSecond))
        config.queueDepth = RecordingSettings.queueDepth
        // `scalesToFit` is what makes SCK resize rather than crop. The output box is
        // derived from the source's own aspect ratio, so `preservesAspectRatio` has
        // nothing left to letterbox.
        config.scalesToFit = isDownscaled
        config.preservesAspectRatio = true
        config.showsCursor = true
        config.showMouseClicks = true
        config.capturesAudio = false
        config.excludesCurrentProcessAudio = true
        if let microphoneID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphoneID
        }
        capturesMicrophone = microphoneID != nil

        super.init()
        // The delegate has to be handed over at init, and `self` is only available here.
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async {
        do {
            try await stream.stopCapture()
        } catch {
            // -3808 (already stopping) and -3807 are benign during teardown.
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .microphone:
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            onMicrophoneSample?(sampleBuffer)
        case .screen:
            guard CMSampleBufferDataIsReady(sampleBuffer),
                  Self.frameStatus(of: sampleBuffer) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            onScreenFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        default:
            return
        }
    }

    /// Only `.complete` frames carry pixels; `.idle` means the display did not change.
    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
