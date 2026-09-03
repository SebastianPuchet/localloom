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
    private var observers: [UUID: (CVPixelBuffer?) -> Void] = [:]

    /// Fans the same frames out to the live previews — the floating camera circle and the
    /// popover's thumbnail. There is deliberately only ever one `AVCaptureSession` per
    /// device; opening a second one for a preview would fight the recording for the camera.
    @discardableResult
    func addObserver(_ observer: @escaping (CVPixelBuffer?) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = observer
        lock.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    func put(_ newBuffer: CVPixelBuffer?) {
        lock.lock()
        buffer = newBuffer
        let current = Array(observers.values)
        lock.unlock()
        // Called outside the lock: the previews hop to the main queue from here.
        for observer in current { observer(newBuffer) }
    }

    /// Returns the newest frame without consuming it — screen frames usually outpace the camera.
    func take() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() { put(nil) }
}
