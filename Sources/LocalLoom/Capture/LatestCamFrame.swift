import CoreVideo
import Foundation

/// Single-slot, lock-guarded box holding the newest camera frame.
///
/// This is the drift fix. Camera frames live on a different clock from the SCStream, so
/// they are never timestamped and never queued — the compositor simply takes whatever is
/// newest and draws it onto the screen frame being encoded. Worst case the bubble is one
/// frame stale; drift becomes structurally impossible.
final class LatestCamFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func put(_ newBuffer: CVPixelBuffer?) {
        lock.lock()
        buffer = newBuffer
        lock.unlock()
    }

    /// Returns the newest frame without consuming it — screen frames usually outpace the camera.
    func take() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() { put(nil) }
}
