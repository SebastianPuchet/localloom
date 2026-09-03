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
        case finalizing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .recording, .finalizing: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Non-fatal notice shown in the popover, e.g. "camera disconnected".
    @Published var notice: String?

    @Published var selectedSourceID: SourceID? {
        didSet { Preferences.sourceID = selectedSourceID?.rawValue }
    }
    @Published var selectedCameraID: String? {
        didSet { Preferences.cameraID = selectedCameraID }
    }
    @Published var selectedMicrophoneID: String? {
        didSet { Preferences.microphoneID = selectedMicrophoneID }
    }

    let catalog = SourceCatalog()

    private var capturer: ScreenCapturer?
    private var writer: MovieWriter?
    private var startTask: Task<Void, Never>?
    private var cancelRequested = false
    private var isStopping = false
    private var startedAt: Date?
    private var timer: Timer?
    private var diskTimer: Timer?

    private init() {
        if let raw = Preferences.sourceID { selectedSourceID = SourceID(rawValue: raw) }
        selectedCameraID = Preferences.cameraID
        selectedMicrophoneID = Preferences.microphoneID
    }

    var isRecording: Bool { state == .recording }

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

    // MARK: - Start

    func start() {
        guard !state.isBusy else { return }
        state = .preparing
        notice = nil
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

            let filter = try await catalog.makeFilter(for: sourceID)
            guard !cancelRequested else { throw CoordinatorError.cancelled }

            let capturer = try ScreenCapturer(filter: filter, microphoneID: microphoneID)
            let url = try RecordingSettings.newOutputURL()
            let writer = try MovieWriter(
                url: url, width: capturer.width, height: capturer.height,
                includeAudio: microphoneID != nil)
            guard let compositor = BubbleCompositor() else { throw CoordinatorError.noGPU }

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

    // MARK: - Stop

    func stop() {
        guard state == .preparing || state == .recording else { return }
        cancelRequested = true
        Task { [weak self] in
            guard let self else { return }
            await self.startTask?.value
            guard self.state == .recording else { return }
            await self.finishRecording(reveal: true)
        }
    }

    /// Stops and finalizes without waiting on a start in flight. Used at app termination.
    func finalizeForTermination() async {
        guard state == .recording || state == .preparing else { return }
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
        stopCamera()

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
        writer?.cancel()
        writer = nil
        stopCamera()
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
        guard state == .recording else { return }
        notice = "Capture stopped: \((error as NSError).localizedDescription) Saving what was recorded."
        Task { await finishRecording(reveal: true) }
    }

    private func handleWriterFailure(_ error: Error) {
        guard state == .recording || state == .preparing else { return }
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

    // MARK: - Camera (wired in CameraCapturer)

    let cameraFrames = LatestCamFrame()

    private func stopCamera() {}

    private func ensureMicrophoneAccess() async -> Bool {
        switch Permissions.microphoneStatus() {
        case .authorized: return true
        case .notDetermined: return await Permissions.requestMicrophoneAccess()
        default: return false
        }
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        startedAt = Date()
        elapsed = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
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
