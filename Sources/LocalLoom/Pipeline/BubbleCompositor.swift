import CoreImage
import CoreVideo
import Foundation
import Metal

/// Draws the circular webcam bubble onto each screen frame on the GPU, and — just as
/// importantly — copies every frame into a pixel buffer we own.
///
/// ScreenCaptureKit hands out IOSurface-backed buffers from a fixed pool sized by
/// `queueDepth`; holding one past the callback starves the stream. Rendering into our own
/// pool means the writer queue and the stall watchdog can keep a frame as long as they like.
final class BubbleCompositor {
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Cached: the bubble geometry only changes if the frame size does, which it never
    /// does within one recording.
    private var bubbleDiameter: CGFloat = 0
    private var bubbleMask = CIImage.empty()
    private var ringImage = CIImage.empty()

    /// Normalized (0...1, bottom-left origin) centre of the bubble in the output frame.
    /// Written from the main actor when the floating camera circle is dragged, read on the
    /// capture queue for every frame — hence the lock.
    private let positionLock = NSLock()
    private var storedPosition = RecordingSettings.defaultBubblePosition

    var bubblePosition: CGPoint {
        get {
            positionLock.lock()
            defer { positionLock.unlock() }
            return storedPosition
        }
        set {
            positionLock.lock()
            storedPosition = newValue
            positionLock.unlock()
        }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// Renders `screen` (plus `camera`, when present) into a freshly vended pixel buffer.
    func composite(screen: CVPixelBuffer, camera: CVPixelBuffer?) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(screen)
        let height = CVPixelBufferGetHeight(screen)
        guard let output = vendBuffer(width: width, height: height) else { return nil }

        var image = CIImage(cvPixelBuffer: screen)
        if let camera {
            prepareBubbleGeometry(width: width, height: height)
            let origin = RecordingSettings.bubbleOrigin(
                position: bubblePosition, diameter: bubbleDiameter,
                width: width, height: height)
            if let bubble = makeBubble(camera: camera, origin: origin) {
                image = bubble.composited(over: image)
            }
        }
        context.render(
            image, to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace)
        return output
    }

    private func prepareBubbleGeometry(width: Int, height: Int) {
        let diameter = RecordingSettings.bubbleDiameter(width: width, height: height)
        guard diameter != bubbleDiameter else { return }
        bubbleDiameter = diameter
        bubbleMask = Self.circleImage(diameter: diameter, color: CIColor.white)
        ringImage = Self.circleImage(
            diameter: diameter + RecordingSettings.bubbleRingWidth * 2,
            color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    }

    private func makeBubble(camera: CVPixelBuffer, origin: CGPoint) -> CIImage? {
        let diameter = bubbleDiameter
        let camImage = CIImage(cvPixelBuffer: camera)
        let extent = camImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // Centre-crop to a square, then scale that square to the bubble diameter.
        let side = min(extent.width, extent.height)
        let cropped = camImage
            .cropped(to: CGRect(
                x: extent.midX - side / 2, y: extent.midY - side / 2,
                width: side, height: side))
            .transformed(by: CGAffineTransform(
                translationX: -(extent.midX - side / 2), y: -(extent.midY - side / 2)))
        let scale = diameter / side
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Mirror horizontally so the bubble reads like a mirror, the way every video call does.
        let mirrored = scaled
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: diameter, y: 0))

        guard let masked = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: mirrored,
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: bubbleMask,
        ])?.outputImage else { return nil }

        let ringOffset = RecordingSettings.bubbleRingWidth
        let ring = ringImage.transformed(by: CGAffineTransform(
            translationX: origin.x - ringOffset, y: origin.y - ringOffset))
        return masked
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .composited(over: ring)
    }

    private func vendBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                attributes as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let newPool else { return nil }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    /// A hard-edged filled circle, used both as the bubble mask and as the ring behind it.
    private static func circleImage(diameter: CGFloat, color: CIColor) -> CIImage {
        let radius = diameter / 2
        let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: radius, y: radius),
            "inputRadius0": radius - 1,
            "inputRadius1": radius,
            "inputColor0": color,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])
        let image = filter?.outputImage ?? CIImage.empty()
        return image.cropped(to: CGRect(x: 0, y: 0, width: diameter, height: diameter))
    }
}
