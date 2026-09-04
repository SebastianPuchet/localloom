import SwiftUI

/// Small icon-only button used in the floating control bar and the popover.
struct IconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .primary
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: LoomTheme.overlayIconSize, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .overlayButtonFrame()
                .background(
                    Circle().fill(
                        prominent
                            ? AnyShapeStyle(tint)
                            : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The always-on-top recording controls.
///
/// Restart and Delete throw footage away, so neither fires on a single click: the bar swaps
/// to a confirm strip that reverts on its own after a few seconds. That is cheaper than a
/// modal (which a non-activating panel cannot show well anyway) and safer than an undo.
struct ControlBarView: View {
    @ObservedObject var coordinator: RecordingCoordinator

    enum Pending: Equatable { case restart, discard }
    @State private var pending: Pending?

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(LoomTheme.rowStroke))
                .shadow(color: .black.opacity(0.30), radius: 11, y: 3)

            if let pending {
                confirmStrip(pending)
            } else {
                controls
            }
        }
        .padding(OverlayController.overlayPadding)
        .frame(width: OverlayController.controlBarSize.width,
               height: OverlayController.controlBarSize.height)
        .task(id: pending) {
            guard pending != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { pending = nil }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            statusDot
            Text(loomTimeString(coordinator.elapsed))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(coordinator.isActive ? .primary : .secondary)
                .accessibilityLabel("Elapsed \(loomTimeString(coordinator.elapsed))")

            Divider().frame(height: 24).padding(.horizontal, 4)

            // Doubles as the start button, so the bar is useful before recording too.
            IconButton(
                systemImage: coordinator.isActive ? "stop.fill" : "record.circle.fill",
                label: coordinator.isActive ? "Stop and save" : "Start recording",
                tint: coordinator.isActive ? LoomTheme.recording : LoomTheme.accent,
                prominent: true
            ) { coordinator.toggleRecording() }
            .disabled(coordinator.selectedSourceID == nil || coordinator.state == .preparing
                      || coordinator.state == .finalizing)

            Group {
                IconButton(
                    systemImage: coordinator.isPaused ? "play.fill" : "pause.fill",
                    label: coordinator.isPaused ? "Resume recording" : "Pause recording"
                ) { coordinator.togglePause() }

                IconButton(systemImage: "arrow.counterclockwise", label: "Restart recording") {
                    pending = .restart
                }

                IconButton(systemImage: "trash", label: "Delete recording") {
                    pending = .discard
                }
            }
            .disabled(!coordinator.isActive)
            .opacity(coordinator.isActive ? 1 : 0.32)
        }
        .padding(.horizontal, 14)
    }

    private func confirmStrip(_ action: Pending) -> some View {
        HStack(spacing: 8) {
            Text(action == .restart ? "Start over?" : "Discard take?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 0)
            Button("Cancel") { pending = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button(action == .restart ? "Restart" : "Delete") {
                pending = nil
                if action == .restart { coordinator.restart() } else { coordinator.discard() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(LoomTheme.recording))
        }
        .padding(.horizontal, 16)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .padding(.trailing, 2)
            .accessibilityLabel(statusLabel)
    }

    private var dotColor: Color {
        if !coordinator.isActive { return Color.secondary.opacity(0.5) }
        return coordinator.isPaused ? LoomTheme.paused : LoomTheme.recording
    }

    private var statusLabel: String {
        if !coordinator.isActive { return "Ready to record" }
        return coordinator.isPaused ? "Paused" : "Recording"
    }
}

/// The floating camera circle. Dragging its window is what moves the bubble in the movie.
struct CameraBubbleView: View {
    let frames: LatestCamFrame

    var body: some View {
        CameraPreview(frames: frames)
            .frame(width: OverlayController.cameraDiameter,
                   height: OverlayController.cameraDiameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 4))
            .shadow(color: .black.opacity(0.35), radius: 11, y: 3)
            .padding(OverlayController.overlayPadding)
            .accessibilityLabel("Camera bubble — drag to place it in the recording")
    }
}
