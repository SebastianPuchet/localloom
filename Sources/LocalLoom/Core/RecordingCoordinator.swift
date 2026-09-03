import AVFoundation
import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
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

    private var startedAt: Date?
    private var timer: Timer?

    init() {
        if let raw = Preferences.sourceID { selectedSourceID = SourceID(rawValue: raw) }
        selectedCameraID = Preferences.cameraID
        selectedMicrophoneID = Preferences.microphoneID
    }

    var isRecording: Bool { state == .recording }

    func refreshSources() async {
        await catalog.refresh()
        // Restored selections may point at a display or window that is gone.
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
        if isRecording || state == .preparing {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard case .idle = stateIgnoringFailure() else { return }
        state = .preparing
    }

    func stop() {
        guard state == .recording || state == .preparing else { return }
        state = .idle
        stopTimer()
    }

    private func stateIgnoringFailure() -> State {
        if case .failed = state { return .idle }
        return state
    }

    fileprivate func startTimer() {
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

    fileprivate func stopTimer() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        elapsed = 0
    }
}
