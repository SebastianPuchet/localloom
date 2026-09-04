import AppKit
import SwiftUI

@main
struct LocalLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = RecordingCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(coordinator: coordinator)
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKeyMonitor?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let monitor = HotKeyMonitor {
            RecordingCoordinator.shared.stop()
        }
        if !monitor.register() {
            RecordingCoordinator.shared.notice =
                "\(HotKeyMonitor.displayName) is already taken by another app, so the stop hotkey is off."
        }
        hotKey = monitor

        installSignalHandlers()

        // Belt and braces for the overlays: SwiftUI's onDisappear on the menu bar popover
        // is the primary signal, but if AppKit closes that window without SwiftUI telling
        // us, the overlays would linger.
        //
        // It matches the popover by *identity*. It used to match "any window of ours that
        // is not a FloatingPanel", which was wrong: every SwiftUI `Menu` in the popover —
        // the screen, camera and microphone pickers — puts up a window of its own, and
        // closing that menu to make a choice read as the popover closing. The overlays and
        // the camera session were torn down the instant the user picked anything.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let coordinator = RecordingCoordinator.shared
                guard window === coordinator.popoverWindow else { return }
                coordinator.popoverWindow = nil
                coordinator.popoverDisappeared()
            }
        }
    }

    /// A recording in progress must be finalized before the process dies, or the MP4 is
    /// left unplayable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecordingCoordinator.shared.state.isBusy else { return .terminateNow }
        Task { @MainActor in
            await RecordingCoordinator.shared.finalizeForTermination()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        OverlayController.shared.hideAll()
    }

    /// `swift run` and `kill` bypass AppKit's terminate path entirely.
    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await RecordingCoordinator.shared.finalizeForTermination()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
