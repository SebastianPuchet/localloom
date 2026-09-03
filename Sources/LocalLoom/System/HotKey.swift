import Carbon.HIToolbox
import Foundation

/// Global ⌘⇧8 hotkey via Carbon `RegisterEventHotKey`.
///
/// Carbon hot keys need no TCC grant at all. `NSEvent.addGlobalMonitorForEvents` would
/// silently never fire without an Accessibility grant, and `CGEventTap` needs Input
/// Monitoring, so Carbon is the only zero-friction option for a stop hotkey.
final class HotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4C4C4D31  // 'LLM1'
    private let identifier: UInt32 = 1

    /// Called on the main thread when the hotkey fires.
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers ⌘⇧8. Returns false if another app already owns the combination.
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == monitor.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { monitor.action() }
                return noErr
            },
            1, &eventType, context, &handlerRef)
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_8), UInt32(cmdKey | shiftKey), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    deinit { unregister() }

    /// Human-readable form for the UI.
    static let displayName = "⌘⇧8"
}
