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
            // Frames arrive on the camera queue; CALayer work has to happen on main.
            token = frames.addObserver { [weak view] buffer in
                DispatchQueue.main.async { view?.show(buffer) }
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
final class CameraPreviewView: NSView {
    var mirrored = true

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let imageLayer = CALayer()
    private var lastRenderAt: CFTimeInterval = 0

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
    }

    override var isFlipped: Bool { true }

    func show(_ buffer: CVPixelBuffer?) {
        guard let buffer else {
            imageLayer.contents = nil
            return
        }
        // 24fps is plenty for a preview and keeps the GPU cost off the capture path.
        let now = CACurrentMediaTime()
        guard now - lastRenderAt >= 1.0 / 24 else { return }
        lastRenderAt = now

        let scale = window?.backingScaleFactor ?? 2
        let target = max(bounds.width, 1) * scale
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let side = min(extent.width, extent.height)
        let originX = extent.midX - side / 2
        let originY = extent.midY - side / 2
        image = image
            .cropped(to: CGRect(x: originX, y: originY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
            .transformed(by: CGAffineTransform(scaleX: target / side, y: target / side))
        if mirrored {
            image = image
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: target, y: 0))
        }
        guard let rendered = context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: target, height: target))
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = rendered
        CATransaction.commit()
    }
}
