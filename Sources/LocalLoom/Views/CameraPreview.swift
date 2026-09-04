import CoreImage
import CoreVideo
import SwiftUI

/// Live webcam view fed from `LatestCamFrame`.
///
/// It never opens a capture session of its own — it subscribes to the frames the single
/// shared `CameraCapturer` is already producing, so the preview and the recorded bubble
/// always show the same thing and never fight over the device.
struct CameraPreview: NSViewRepresentable {
    let frames: LatestCamFrame
    /// Matches the composited bubble, which is mirrored like every video call.
    var mirrored = true

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.mirrored = mirrored
        context.coordinator.attach(to: view, frames: frames)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.mirrored = mirrored
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: UUID?
        private weak var frames: LatestCamFrame?

        func attach(to view: CameraPreviewView, frames: LatestCamFrame) {
            self.frames = frames
            // Handed straight to the view on the camera queue: the conversion runs on the
            // view's own render queue and only the layer assignment hops to main.
            token = frames.addObserver { [weak view] buffer in
                view?.submit(buffer)
            }
        }

        func detach() {
            if let token { frames?.removeObserver(token) }
            token = nil
        }

        deinit { detach() }
    }
}

/// Draws the newest camera frame into a circular layer, centre-cropped to a square.
///
/// The conversion (crop, mirror, `createCGImage`) happens off the main thread on a private
/// serial queue, and a frame is dropped only while an earlier one is still converting. The
/// preview therefore runs at whatever the camera delivers rather than at a fixed low cap,
/// and a bigger preview does not turn into main-thread work.
final class CameraPreviewView: NSView {
    var mirrored: Bool {
        get { stateLock.withLock { storedMirrored } }
        set { stateLock.withLock { storedMirrored = newValue } }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let imageLayer = CALayer()
    private let renderQueue = DispatchQueue(
        label: "com.sebastianpuchet.localloom.preview", qos: .userInitiated)

    private let stateLock = NSLock()
    private var storedMirrored = true
    /// Side of the square we render, in pixels. Refreshed on layout.
    private var targetPixels: CGFloat = 256
    private var isRendering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        let scale = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = scale
        stateLock.withLock { targetPixels = max(bounds.width, 1) * scale }
    }

    override var isFlipped: Bool { true }

    /// Callable from any thread — frames arrive on the camera capture queue.
    func submit(_ buffer: CVPixelBuffer?) {
        guard let buffer else {
            setContents(nil)
            return
        }
        stateLock.lock()
        // Back-pressure instead of a frame-rate cap: never more than one conversion in
        // flight, so the camera queue is never blocked and nothing piles up on main.
        guard !isRendering else {
            stateLock.unlock()
            return
        }
        isRendering = true
        let target = targetPixels
        let mirror = storedMirrored
        stateLock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            let rendered = self.render(buffer, target: target, mirror: mirror)
            self.setContents(rendered) {
                self.stateLock.withLock { self.isRendering = false }
            }
        }
    }

    private func setContents(_ image: CGImage?, then completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            if let self {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = image
                CATransaction.commit()
            }
            completion?()
        }
    }

    private func render(_ buffer: CVPixelBuffer, target: CGFloat, mirror: Bool) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, target > 0 else { return nil }

        let side = min(extent.width, extent.height)
        let originX = extent.midX - side / 2
        let originY = extent.midY - side / 2
        image = image
            .cropped(to: CGRect(x: originX, y: originY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
            .transformed(by: CGAffineTransform(scaleX: target / side, y: target / side))
        if mirror {
            image = image
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: target, y: 0))
        }
        return context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: target, height: target))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
