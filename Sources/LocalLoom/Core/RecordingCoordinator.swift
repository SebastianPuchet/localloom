import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    static let shared = RecordingCoordinator()

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case finalizing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .recording, .paused, .finalizing: return true
            case .idle, .failed: return false
            }
        }

        /// Capturing right now, whether or not frames are being written.
        var isActive: Bool {
            switch self {
            case .recording, .paused: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle {
        didSet {
            guard !isSettingUp, state != oldValue else { return }
            syncCameraSession()
            OverlayController.shared.update()
        }
    }
    @Published private(set) var elapsed: TimeInterval = 0
    /// Non-fatal notice shown in the popover, e.g. "microphone access denied".
    @Published var notice: String?
    /// Camera-specific notice, kept apart from `notice` so it can be cleared the moment the
    /// camera works again. Folding it into `notice` is what made "camera disconnected"
    /// stick around forever: nothing but `start()` ever cleared it.
    @Published var cameraNotice: String?
    /// True once camera access has been refused, so we stop retrying on every UI change.
    /// Reset when the popover opens — the user may have granted it in System Settings.
    @Published private(set) var cameraAccessDenied = false
    /// True while a camera session is actually delivering frames.
    @Published private(set) var cameraActive = false
    /// The menu bar popover is on screen. The floating overlays follow it.
    @Published private(set) var popoverOpen = false
    /// The window hosting the popover, recorded by `PopoverWindowReader`.
    ///
    /// `AppDelegate` watches `NSWindow.willCloseNotification` as a backstop for the
    /// popover closing. Every SwiftUI `Menu` in the popover opens — and closes — a window
    /// of its own, so that observer has to match on *identity*: matching on "any window
    /// that is not a FloatingPanel" made picking a camera or microphone read as the
    /// popover closing, which tore the overlays and the camera session down mid-interaction.
    weak var popoverWindow: NSWindow?

    @Published var selectedSourceID: SourceID? {
        didSet {
            Preferences.sourceID = selectedSourceID?.rawValue
            guard !isSettingUp, selectedSourceID != oldValue else { return }
            OverlayController.shared.update()
        }
    }
    @Published var selectedCameraID: String? {
        didSet {
            Preferences.cameraID = selectedCameraID
            guard !isSettingUp, selectedCameraID != oldValue else { return }
            syncCameraSession()
            OverlayController.shared.update()
        }
    }
    @Published var selectedMicrophoneID: String? {
        didSet { Preferences.microphoneID = selectedMicrophoneID }
    }

    /// Normalized (0...1, bottom-left origin) centre of the webcam bubble. Dragging the
    /// floating camera circle writes here, and the compositor reads it for every frame —
    /// so where the circle sits on screen is where it lands in the MP4.
    @Published var bubblePosition: CGPoint {
        didSet {
            Preferences.bubblePosition = bubblePosition
            compositor?.bubblePosition = bubblePosition
        }
    }

    let catalog = SourceCatalog()
    let cameraFrames = LatestCamFrame()

    private var capturer: ScreenCapturer?
    private var camera: CameraCapturer?
    /// Device ID of the session we currently want running, nil when none.
    private var runningCameraID: String?
    private var cameraTask: Task<Void, Never>?
    private var writer: MovieWriter?
    /// Kept for the app's lifetime so the bubble position survives between recordings.
    private var compositor: BubbleCompositor?
    private var startTask: Task<Void, Never>?
    private var cancelRequested = false
    private var isStopping = false
    private var startedAt: Date?
    private var accumulatedElapsed: TimeInterval = 0
    private var timer: Timer?
    private var diskTimer: Timer?
    /// `OverlayController` reaches back for `RecordingCoordinator.shared`, so the property
    /// observers must stay quiet until this singleton has finished initializing.
    private var isSettingUp = true

    private init() {
        bubblePosition = Preferences.bubblePosition
        if let raw = Preferences.sourceID { selectedSourceID = SourceID(rawValue: raw) }
        selectedCameraID = Preferences.cameraID
        selectedMicrophoneID = Preferences.microphoneID
        isSettingUp = false

        // A camera that comes back must bring the bubble back with it, and clear the
        // disconnect notice. External capture devices drop out often enough that a
        // one-way "gone forever" latch is simply wrong.
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecordingCoordinator.shared.cameraReturned() }
        }
    }

    /// A capture device was plugged back in.
    private func cameraReturned() {
        catalog.refreshDevices()
        guard selectedCameraID != nil, runningCameraID == nil else { return }
        cameraNotice = nil
        syncCameraSession()
    }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    var isActive: Bool { state.isActive }
    /// The floating control panel and camera circle are on screen exactly when this is true.
    var overlaysVisible: Bool { state.isActive || popoverOpen }

    func refreshSources() async {
        await catalog.refresh()
        // Restored selections may point at a display, window or device that is gone.
        if let id = selectedSourceID, !catalog.sources.contains(where: { $0.id == id }) {
            selectedSourceID = nil
        }
        if selectedSourceID == nil { selectedSourceID = catalog.sources.first?.id }
        if let id = selectedCameraID, !catalog.cameras.contains(where: { $0.id == id }) {
            selectedCameraID = nil
        }
        if let id = selectedMicrophoneID, !catalog.microphones.contains(where: { $0.id == id }) {
            selectedMicrophoneID = nil
        }
    }

    func toggleRecording() {
        if state.isBusy { stop() } else { start() }
    }

    // MARK: - Popover presence

    func popoverAppeared() {
        popoverOpen = true
        // The user may have granted access in System Settings since the last refusal.
        cameraAccessDenied = false
        syncCameraSession()
        OverlayController.shared.update()
    }

    func popoverDisappeared() {
        popoverOpen = false
        syncCameraSession()
        OverlayController.shared.update()
    }

    // MARK: - Start

    func start() {
        guard !state.isBusy else { return }
        state = .preparing
        notice = nil
        cameraNotice = nil
        cancelRequested = false
        isStopping = false
        startTask = Task { [weak self] in await self?.performStart() }
    }

    private func performStart() async {
        do {
            guard let sourceID = selectedSourceID else { throw CoordinatorError.noSource }

            switch Permissions.screenStatus() {
            case .granted:
                break
            case .notDetermined:
                Permissions.requestScreenAccess()
                throw CoordinatorError.screenAccessJustRequested
            case .denied:
                throw CoordinatorError.screenAccessDenied
            }

            try checkFreeSpace(minimum: RecordingSettings.minimumFreeBytesToStart)

            var microphoneID = selectedMicrophoneID
            if microphoneID != nil, await !ensureMicrophoneAccess() {
                microphoneID = nil
                notice = "Microphone access was denied — recording without audio."
            }

            // The overlays must be on screen *before* the content filter is built, or
            // ScreenCaptureKit will not know to exclude them and they get burned into the
            // movie. Bringing them up here also settles the camera session.
            OverlayController.shared.update()
            syncCameraSession()
            await cameraTask?.value

            let filter = try await catalog.makeFilter(for: sourceID)
            guard !cancelRequested else { throw CoordinatorError.cancelled }

            let capturer = try ScreenCapturer(filter: filter, microphoneID: microphoneID)
            let url = try RecordingSettings.newOutputURL()
            let writer = try MovieWriter(
                url: url, width: capturer.width, height: capturer.height,
                includeAudio: microphoneID != nil)
            if compositor == nil { compositor = BubbleCompositor() }
            guard let compositor else { throw CoordinatorError.noGPU }
            compositor.bubblePosition = bubblePosition

            // These closures run on the capture queue. They deliberately capture only
            // Sendable-by-confinement objects, never the coordinator's UI state.
            capturer.onScreenFrame = { [weak self] screenBuffer, presentationTime in
                let camera = self?.cameraFrames.take()
                guard let composited = compositor.composite(screen: screenBuffer, camera: camera)
                else { return }
                writer.append(composited, at: presentationTime)
            }
            capturer.onMicrophoneSample = { sampleBuffer in
                writer.appendAudio(sampleBuffer)
            }
            capturer.onStop = { [weak self] error in
                Task { @MainActor in self?.handleStreamStopped(error) }
            }
            writer.onFailure = { [weak self] error in
                Task { @MainActor in self?.handleWriterFailure(error) }
            }

            guard !cancelRequested else { throw CoordinatorError.cancelled }
            try await capturer.start()

            self.capturer = capturer
            self.writer = writer

            guard !cancelRequested else {
                await finishRecording(reveal: false)
                return
            }

            state = .recording
            startTimer()
            startDiskPoll()
        } catch {
            await abort(with: error)
        }
    }

    // MARK: - Pause / resume

    func pause() {
        guard state == .recording, let writer else { return }
        writer.pause()
        // Freeze the clock too — a paused recording that keeps counting is a lie.
        accumulatedElapsed = elapsed
        timer?.invalidate()
        timer = nil
        startedAt = nil
        state = .paused
    }

    func resume() {
        guard state == .paused, let writer else { return }
        writer.resume()
        state = .recording
        startedAt = Date()
        scheduleTimer()
    }

    func togglePause() {
        if state == .paused { resume() } else { pause() }
    }

    // MARK: - Stop / restart / delete

    func stop() {
        guard state == .preparing || state == .recording || state == .paused else { return }
        cancelRequested = true
        Task { [weak self] in
            guard let self else { return }
            await self.startTask?.value
            guard self.state == .recording || self.state == .paused else { return }
            await self.finishRecording(reveal: true)
        }
    }

    /// Throws the current take away and starts a fresh one with the same settings.
    func restart() {
        guard state.isActive else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.discardCurrent()
            self.start()
        }
    }

    /// Throws the current take away and returns to idle. Leaves no file behind.
    func discard() {
        guard state.isActive else { return }
        Task { [weak self] in await self?.discardCurrent() }
    }

    private func discardCurrent() async {
        guard !isStopping else { return }
        isStopping = true
        state = .finalizing
        stopTimer()
        stopDiskPoll()

        await capturer?.stop()
        capturer = nil
        // Awaited so the partial file is gone before a restart reuses the same name.
        await writer?.cancel()
        writer = nil
        isStopping = false
        state = .idle
    }

    /// Stops and finalizes without waiting on a start in flight. Used at app termination.
    func finalizeForTermination() async {
        guard state.isActive || state == .preparing else { return }
        cancelRequested = true
        await startTask?.value
        await finishRecording(reveal: false)
    }

    private func finishRecording(reveal: Bool) async {
        guard !isStopping else { return }
        isStopping = true
        state = .finalizing
        stopTimer()
        stopDiskPoll()

        await capturer?.stop()
        capturer = nil

        guard let writer else {
            state = .idle
            isStopping = false
            return
        }
        self.writer = nil

        let result = await writer.finish()
        isStopping = false
        switch result {
        case .success(let url):
            state = .idle
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func abort(with error: Error) async {
        await capturer?.stop()
        capturer = nil
        await writer?.cancel()
        writer = nil
        stopTimer()
        stopDiskPoll()
        isStopping = false
        if case CoordinatorError.cancelled = error {
            state = .idle
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Failure handling

    /// Display unplugged, window closed, or the user revoked access mid-recording. Keep the
    /// footage: finalize rather than discard.
    private func handleStreamStopped(_ error: Error) {
        guard state.isActive else { return }
        notice = "Capture stopped: \((error as NSError).localizedDescription) Saving what was recorded."
        Task { await finishRecording(reveal: true) }
    }

    private func handleWriterFailure(_ error: Error) {
        guard state.isActive || state == .preparing else { return }
        Task { await abort(with: error) }
    }

    // MARK: - Disk space

    private func checkFreeSpace(minimum: Int64) throws {
        let directory = try RecordingSettings.outputDirectory()
        let values = try directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if available < minimum { throw CoordinatorError.diskFull }
    }

    private func startDiskPoll() {
        let timer = Timer(
            timeInterval: RecordingSettings.diskPollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                do {
                    try self.checkFreeSpace(minimum: RecordingSettings.minimumFreeBytesToContinue)
                } catch {
                    self.notice = "Ran out of disk space — recording stopped and saved."
                    await self.finishRecording(reveal: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }

    private func stopDiskPoll() {
        diskTimer?.invalidate()
        diskTimer = nil
    }

    // MARK: - Camera

    /// Starts or stops the single shared `AVCaptureSession` so it is running exactly when
    /// something needs it: the floating circle, the popover preview, or the recording.
    /// There is never more than one session on a device.
    private func syncCameraSession() {
        let desired: String? = (overlaysVisible || state.isBusy) ? selectedCameraID : nil
        guard desired != runningCameraID else { return }

        cameraTask?.cancel()
        camera?.stop()
        camera = nil
        cameraFrames.clear()
        cameraActive = false
        runningCameraID = desired

        guard let desired else { return }
        guard !cameraAccessDenied else {
            runningCameraID = nil
            cameraNotice = "Camera access is off for LocalLoom — recording the screen only."
            return
        }
        cameraTask = Task { [weak self] in
            guard let self else { return }
            guard await self.ensureCameraAccess() else {
                guard self.runningCameraID == desired else { return }
                self.runningCameraID = nil
                self.cameraAccessDenied = true
                // The selection is the user's, not ours to throw away: keep it so the
                // bubble comes back by itself once access is granted.
                self.cameraNotice =
                    "Camera access is off for LocalLoom — recording the screen only."
                return
            }
            guard !Task.isCancelled, self.runningCameraID == desired else { return }
            do {
                let capturer = try CameraCapturer(deviceID: desired, frames: self.cameraFrames)
                capturer.onDisconnect = { [weak self] in
                    Task { @MainActor in self?.handleCameraLoss(deviceID: desired) }
                }
                capturer.start()
                self.camera = capturer
                self.cameraActive = true
                // The camera is live: whatever the last camera complaint was, it is stale.
                self.cameraNotice = nil
                OverlayController.shared.update()
            } catch {
                self.runningCameraID = nil
                self.cameraActive = false
                // A missing camera must never block a screen recording.
                self.cameraNotice = "Camera unavailable — recording the screen only."
                OverlayController.shared.update()
            }
        }
    }

    /// The camera went away. Tear the dead session down so a reconnect can rebuild it, and
    /// say so only while it is actually gone.
    private func handleCameraLoss(deviceID: String) {
        guard runningCameraID == deviceID else { return }
        camera?.stop()
        camera = nil
        cameraActive = false
        runningCameraID = nil
        cameraNotice = state.isActive
            ? "Camera disconnected — the bubble is gone, recording continues."
            : "Camera disconnected."
        OverlayController.shared.update()
    }

    private func ensureCameraAccess() async -> Bool {
        switch Permissions.cameraStatus() {
        case .authorized: return true
        case .notDetermined: return await Permissions.requestCameraAccess()
        default: return false
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch Permissions.microphoneStatus() {
        case .authorized: return true
        case .notDetermined: return await Permissions.requestMicrophoneAccess()
        default: return false
        }
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        accumulatedElapsed = 0
        elapsed = 0
        startedAt = Date()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = self.accumulatedElapsed + Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        accumulatedElapsed = 0
        elapsed = 0
    }

    enum CoordinatorError: LocalizedError {
        case noSource
        case screenAccessDenied
        case screenAccessJustRequested
        case diskFull
        case noGPU
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noSource:
                return "Pick a display or window first."
            case .screenAccessDenied:
                return "Screen Recording is off for LocalLoom. Turn it on in System Settings, then quit and reopen LocalLoom."
            case .screenAccessJustRequested:
                return "Grant Screen Recording access, then quit and reopen LocalLoom — macOS only reads the setting at launch."
            case .diskFull:
                return "Not enough free disk space to start a recording."
            case .noGPU:
                return "No Metal device is available for compositing."
            case .cancelled:
                return "Cancelled."
            }
        }
    }
}
