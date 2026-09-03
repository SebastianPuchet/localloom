import AVFoundation
import CoreVideo
import Foundation

/// Feeds the newest webcam frame into a `LatestCamFrame` box.
///
/// Frames are never timestamped and never queued — see `LatestCamFrame` for why.
final class CameraCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                            @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.sebastianpuchet.localloom.camera")
    private let frames: LatestCamFrame

    /// Called when the camera goes away mid-recording. The recording keeps going.
    var onDisconnect: (() -> Void)?

    init(deviceID: String, frames: LatestCamFrame) throws {
        self.frames = frames
        super.init()

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CameraError.deviceUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.deviceUnavailable
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Keeping only the newest frame is exactly the semantics we want.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.deviceUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()

        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification, object: device)
        NotificationCenter.default.addObserver(
            self, selector: #selector(runtimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    func start() {
        guard !session.isRunning else { return }
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        output.setSampleBufferDelegate(nil, queue: nil)
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
        frames.clear()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Delegate

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.put(buffer)
    }

    @objc private func deviceDisconnected(_ notification: Notification) {
        handleLoss()
    }

    @objc private func runtimeError(_ notification: Notification) {
        handleLoss()
    }

    private func handleLoss() {
        // The bubble disappears; the screen recording continues uninterrupted so the
        // video track stays continuous.
        frames.clear()
        onDisconnect?()
    }

    enum CameraError: LocalizedError {
        case deviceUnavailable
        var errorDescription: String? { "That camera is not available." }
    }
}
