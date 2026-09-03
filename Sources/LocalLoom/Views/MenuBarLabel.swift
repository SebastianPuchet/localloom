import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.isRecording {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "video.circle")
        }
    }
}
