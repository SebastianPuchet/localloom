import AVFoundation
import SwiftUI

struct PopoverView: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject private var catalog: SourceCatalog

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        self.catalog = coordinator.catalog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            permissionBanner
            sourceRows.disabled(coordinator.state.isBusy)
            cameraPreview
            messages
            primaryButton
            if coordinator.isActive { activeControls }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(PopoverWindowReader())
        .task { await coordinator.refreshSources() }
        .onAppear { coordinator.popoverAppeared() }
        .onDisappear { coordinator.popoverDisappeared() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(coordinator.isActive ? LoomTheme.recording : LoomTheme.accent)
            Text("LocalLoom")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch coordinator.state {
        case .recording, .paused:
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isPaused ? LoomTheme.paused : LoomTheme.recording)
                    .frame(width: 7, height: 7)
                Text(loomTimeString(coordinator.elapsed))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(LoomTheme.rowFill))
            .accessibilityLabel(
                "\(coordinator.isPaused ? "Paused" : "Recording"), "
                + loomTimeString(coordinator.elapsed))
        case .preparing:
            Text("Starting…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .finalizing:
            Text("Saving…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .idle, .failed:
            EmptyView()
        }
    }

    // MARK: - Source rows

    private var sourceRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ModeButton(
                    icon: "macwindow", title: "Entire Screen",
                    isSelected: !coordinator.isWindowSource
                ) { coordinator.selectEntireScreen() }
                ModeButton(
                    icon: "macwindow.badge.plus", title: "Window",
                    isSelected: coordinator.isWindowSource
                ) { coordinator.beginWindowPicking() }
            }

            if coordinator.isWindowSource {
                windowRow
            } else if catalog.displays.count > 1 {
                SelectorRow(
                    icon: "display", tint: LoomTheme.accent, title: "Display",
                    value: displayName
                ) {
                    Picker("Display", selection: $coordinator.selectedSourceID) {
                        ForEach(catalog.displays) { source in
                            Text(source.name).tag(SourceID?.some(source.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            SelectorRow(
                icon: coordinator.selectedCameraID == nil ? "video.slash" : "video.fill",
                tint: Color.teal, title: "Camera", value: cameraName
            ) {
                Picker("Camera", selection: $coordinator.selectedCameraID) {
                    Text("Off").tag(String?.none)
                    ForEach(catalog.cameras) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            SelectorRow(
                icon: coordinator.selectedMicrophoneID == nil ? "mic.slash" : "mic.fill",
                tint: Color.orange, title: "Microphone", value: microphoneName
            ) {
                Picker("Microphone", selection: $coordinator.selectedMicrophoneID) {
                    Text("Off").tag(String?.none)
                    ForEach(catalog.microphones) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    /// The chosen window, and the way back into the picker. Tapping anywhere on the row
    /// re-enters selection mode, so changing the target is one click from here.
    private var windowRow: some View {
        Button {
            coordinator.beginWindowPicking()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LoomTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LoomTheme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("WINDOW")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(coordinator.selectedWindowName ?? "Choose a window…")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(coordinator.selectedWindowName == nil ? "Choose…" : "Change…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LoomTheme.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .fill(LoomTheme.rowFill))
            .overlay(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .strokeBorder(LoomTheme.rowStroke))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Window: \(coordinator.selectedWindowName ?? "none chosen"). Choose a window.")
    }

    private var displayName: String {
        guard let id = coordinator.selectedSourceID,
              let source = catalog.displays.first(where: { $0.id == id })
        else { return catalog.displays.isEmpty ? "No display available" : "Choose a display" }
        return source.name
    }

    private var cameraName: String {
        guard let id = coordinator.selectedCameraID,
              let device = catalog.cameras.first(where: { $0.id == id })
        else { return catalog.cameras.isEmpty ? "No camera connected" : "Off" }
        return device.name
    }

    private var microphoneName: String {
        guard let id = coordinator.selectedMicrophoneID,
              let device = catalog.microphones.first(where: { $0.id == id })
        else { return "Off" }
        return device.name
    }

    // MARK: - Camera preview

    @ViewBuilder
    private var cameraPreview: some View {
        if coordinator.cameraActive, coordinator.selectedCameraID != nil {
            VStack(spacing: 6) {
                CameraPreview(frames: coordinator.cameraFrames)
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 3))
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
                    .accessibilityLabel("Live camera preview")
                Text("Drag the circle on screen to place it in the recording.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messages: some View {
        if let error = catalog.lastError, catalog.displays.isEmpty {
            noticeLabel(error, icon: "display.trianglebadge.exclamationmark", tint: .secondary)
        }
        if let cameraNotice = coordinator.cameraNotice {
            noticeLabel(
                cameraNotice, icon: "video.slash.fill", tint: .orange,
                action: coordinator.cameraAccessDenied ? "Open Settings…" : nil,
                perform: { Permissions.openCameraSettings() },
                dismiss: { coordinator.cameraNotice = nil })
        }
        if let notice = coordinator.notice {
            noticeLabel(
                notice, icon: "exclamationmark.triangle.fill", tint: .orange,
                dismiss: { coordinator.notice = nil })
        }
        if case .failed(let message) = coordinator.state {
            noticeLabel(message, icon: "xmark.octagon.fill", tint: LoomTheme.recording)
        }
    }

    /// Notices are advisory, so every one of them can be dismissed by hand as well as
    /// clearing itself when the condition goes away.
    private func noticeLabel(
        _ text: String, icon: String, tint: Color,
        action: String? = nil, perform: (() -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let action, let perform {
                    Button(action, action: perform)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LoomTheme.accent)
                }
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var primaryButton: some View {
        Button {
            coordinator.toggleRecording()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: coordinator.state.isActive ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(coordinator.state.isActive ? LoomTheme.recording : LoomTheme.accent))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(primaryDisabled)
        .opacity(primaryDisabled ? 0.4 : 1)
        .accessibilityLabel(primaryTitle)
    }

    private var primaryTitle: String {
        switch coordinator.state {
        case .recording, .paused: return "Stop & Save"
        case .preparing: return "Starting…"
        case .finalizing: return "Saving…"
        case .idle, .failed: return "Start Recording"
        }
    }

    private var primaryDisabled: Bool {
        coordinator.selectedSourceID == nil
            || coordinator.state == .finalizing
            || coordinator.state == .preparing
    }

    private var activeControls: some View {
        HStack(spacing: 6) {
            IconButton(
                systemImage: coordinator.isPaused ? "play.fill" : "pause.fill",
                label: coordinator.isPaused ? "Resume recording" : "Pause recording"
            ) { coordinator.togglePause() }
            Spacer(minLength: 0)
            Text("Controls also float on screen")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text("Stop with \(HotKeyMonitor.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Quit LocalLoom")
            }
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionBanner: some View {
        switch Permissions.screenStatus() {
        case .granted:
            EmptyView()
        case .notDetermined:
            banner(
                title: "LocalLoom needs Screen Recording permission.",
                detail: nil, action: "Grant Access…"
            ) {
                Permissions.requestScreenAccess()
                coordinator.notice = "Quit and reopen LocalLoom after granting access."
            }
        case .denied:
            banner(
                title: "Screen Recording is turned off for LocalLoom.",
                detail: "Enable it, then quit and reopen LocalLoom — macOS only re-reads the setting at launch.",
                action: "Open System Settings…"
            ) { Permissions.openScreenRecordingSettings() }
        }
    }

    private func banner(
        title: String, detail: String?, action: String, perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LoomTheme.accent)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
    }
}

/// Records which `NSWindow` is hosting the popover, so the `willClose` backstop in
/// `AppDelegate` can tell the popover apart from the transient windows SwiftUI's `Menu`
/// puts up for each picker.
private struct PopoverWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        capture(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { capture(nsView) }

    /// `view.window` is nil until the view is in the hierarchy, hence the hop.
    private func capture(_ view: NSView) {
        Task { @MainActor in
            guard let window = view.window else { return }
            RecordingCoordinator.shared.popoverWindow = window
        }
    }
}

/// One of the two top-level source choices. Big enough to read as the primary decision on
/// the panel, because it is: everything below it is a refinement of this answer.
private struct ModeButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? LoomTheme.accent : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .fill(isSelected ? LoomTheme.accent.opacity(0.14) : LoomTheme.rowFill))
            .overlay(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .strokeBorder(
                        isSelected ? LoomTheme.accent.opacity(0.6) : LoomTheme.rowStroke,
                        lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Icon + label + current value, opening a menu of choices. Reads better than a bare
/// `Picker` and keeps every row the same height.
private struct SelectorRow<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    @ViewBuilder var menu: () -> Content

    var body: some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .fill(LoomTheme.rowFill))
            .overlay(
                RoundedRectangle(cornerRadius: LoomTheme.rowCorner, style: .continuous)
                    .strokeBorder(LoomTheme.rowStroke))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(title): \(value)")
    }
}
