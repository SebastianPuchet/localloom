import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Owns the `AVAssetWriter`. All writer state is confined to one serial queue, which is
/// what makes the `@unchecked Sendable` conformance sound.
final class MovieWriter: @unchecked Sendable {
    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.sebastianpuchet.localloom.writer")

    private var sessionStarted = false
    private var finished = false
    private var lastPresentationTime: CMTime = .zero
    private var lastHostTime: CMTime = .zero
    /// Kept so the watchdog can re-append it; safe because it comes from our own pool.
    private var lastPixelBuffer: CVPixelBuffer?
    private var watchdog: DispatchSourceTimer?

    private(set) var droppedFrames = 0

    /// Called on the writer queue when the writer enters `.failed`.
    var onFailure: ((Error) -> Void)?

    init(url: URL, width: Int, height: Int, includeAudio: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingSettings.bitrate(width: width, height: height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: RecordingSettings.framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(videoInput) else { throw WriterError.cannotAddInput }
        writer.add(videoInput)

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw writer.error ?? WriterError.cannotStart }
    }

    // MARK: - Appending

    /// Appends a composited frame. `pixelBuffer` must be owned by us, never an SCK buffer.
    func append(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: presentationTime)
                self.writerSessionStart = presentationTime
                self.sessionStarted = true
                self.startWatchdog()
            }
            // Never move backwards: a re-emitted watchdog frame may have overtaken a
            // real frame that was still in flight.
            guard presentationTime > self.lastPresentationTime || self.lastPixelBuffer == nil else {
                return
            }
            self.write(pixelBuffer, at: presentationTime)
        }
    }

    /// Mic PCM. It rides the same clock as the screen frames, so no re-timing is needed.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, let audioInput = self.audioInput, !self.finished else { return }
            // Anything before the video anchor has nowhere to go.
            guard self.sessionStarted else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= self.writerSessionStart
            else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
            self.checkFailure()
        }
    }

    private var writerSessionStart: CMTime = .zero

    /// Caller must already be on `queue`.
    private func write(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) {
        // Backpressure: dropping a frame is always better than blocking the capture queue.
        guard videoInput.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        lastPixelBuffer = pixelBuffer
        lastPresentationTime = presentationTime
        lastHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        checkFailure()
    }

    private func checkFailure() {
        guard writer.status == .failed, !finished else { return }
        finished = true
        stopWatchdog()
        let error = writer.error ?? WriterError.unknown
        onFailure?(error)
    }

    // MARK: - Static-screen watchdog

    /// ScreenCaptureKit stops emitting frames while nothing on screen changes. Without this
    /// the movie's duration stops advancing and the tail is silently lost — the single most
    /// common "my recording is broken" bug. Re-append the last composited frame instead.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + RecordingSettings.stallInterval,
            repeating: RecordingSettings.stallInterval / 2,
            leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, let buffer = self.lastPixelBuffer else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let sinceLastFrame = CMTimeGetSeconds(CMTimeSubtract(now, self.lastHostTime))
            guard sinceLastFrame >= RecordingSettings.stallInterval else { return }
            // Advance the presentation time by the wall-clock gap so the movie's duration
            // keeps tracking real time.
            let advance = CMTimeSubtract(now, self.lastHostTime)
            self.write(buffer, at: CMTimeAdd(self.lastPresentationTime, advance))
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - Teardown

    /// Finalizes the movie. Returns nil if nothing was ever written.
    func finish() async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopWatchdog()
                guard !finished else {
                    continuation.resume(returning: .failure(writer.error ?? WriterError.unknown))
                    return
                }
                finished = true
                guard sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: .failure(WriterError.noFrames))
                    return
                }
                // Timer coalescing can leave the last watchdog tick up to one interval in
                // the past, which would clip the tail. Land one final frame on "now".
                if let buffer = lastPixelBuffer {
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    let advance = CMTimeSubtract(now, lastHostTime)
                    if advance > .zero {
                        write(buffer, at: CMTimeAdd(lastPresentationTime, advance))
                    }
                }
                writer.endSession(atSourceTime: lastPresentationTime)
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                lastPixelBuffer = nil
                writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: .success(self.url))
                    } else {
                        continuation.resume(
                            returning: .failure(self.writer.error ?? WriterError.unknown))
                    }
                }
            }
        }
    }

    /// Abandons the movie and deletes the partial file. Never leave a zero-byte MP4 behind.
    func cancel() {
        queue.async { [self] in
            stopWatchdog()
            finished = true
            lastPixelBuffer = nil
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum WriterError: LocalizedError {
        case cannotAddInput
        case cannotStart
        case noFrames
        case unknown

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "Could not configure the movie file."
            case .cannotStart: return "Could not start writing the movie file."
            case .noFrames: return "No frames were captured, so nothing was saved."
            case .unknown: return "The movie file could not be written."
            }
        }
    }
}
