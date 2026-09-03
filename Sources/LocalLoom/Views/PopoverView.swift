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

            pickers
                .disabled(coordinator.state.isBusy)

            if let error = catalog.lastError, catalog.sources.isEmpty {
                Label(error, systemImage: "display.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = coordinator.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case .failed(let message) = coordinator.state {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recordButton

            Divider()

            HStack {
                Text("Stop with \(HotKeyMonitor.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { await coordinator.refreshSources() }
    }

    private var header: some View {
        HStack {
            Text("LocalLoom").font(.headline)
            Spacer()
            if coordinator.state.isBusy {
                Text(timeString(coordinator.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var pickers: some View {
        Picker("Source", selection: $coordinator.selectedSourceID) {
            if catalog.sources.isEmpty {
                Text("No sources").tag(SourceID?.none)
            }
            ForEach(catalog.sources) { source in
                Text(source.name).tag(SourceID?.some(source.id))
            }
        }

        Picker("Camera", selection: $coordinator.selectedCameraID) {
            Text("None").tag(String?.none)
            ForEach(catalog.cameras) { device in
                Text(device.name).tag(String?.some(device.id))
            }
        }

        Picker("Microphone", selection: $coordinator.selectedMicrophoneID) {
            Text("None").tag(String?.none)
            ForEach(catalog.microphones) { device in
                Text(device.name).tag(String?.some(device.id))
            }
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch Permissions.screenStatus() {
        case .granted:
            EmptyView()
        case .notDetermined:
            VStack(alignment: .leading, spacing: 6) {
                Text("LocalLoom needs Screen Recording permission.")
                    .font(.caption)
                Button("Grant Access…") {
                    Permissions.requestScreenAccess()
                    coordinator.notice = "Quit and reopen LocalLoom after granting access."
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording is turned off for LocalLoom.")
                    .font(.caption)
                Text("Enable it, then quit and reopen LocalLoom — macOS only re-reads the setting at launch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Open System Settings…") { Permissions.openScreenRecordingSettings() }
            }
        }
    }

    private var recordButton: some View {
        Button {
            coordinator.toggleRecording()
        } label: {
            Label(
                coordinator.isRecording ? "Stop Recording" : "Record",
                systemImage: coordinator.isRecording ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(coordinator.selectedSourceID == nil || coordinator.state == .finalizing)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
