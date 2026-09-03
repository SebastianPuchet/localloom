import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        switch coordinator.state {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("LocalLoom — recording")
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("LocalLoom — paused")
        default:
            Image(systemName: "video.circle")
                .accessibilityLabel("LocalLoom")
        }
    }
}
