import AppKit
import Carbon.HIToolbox

/// Keyboard filter used ONLY to take over Command+Tab, which macOS reserves and a normal hotkey cannot claim.
/// Privacy: it reads just the key code and modifier flags, never the typed character, and it stores nothing.
/// It only reacts while Command is held; every other keystroke passes straight through untouched.
final class KeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Return true to swallow the event.
    var onKey: ((_ type: CGEventType, _ keyCode: Int, _ flags: CGEventFlags) -> Bool)?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, ctx in
            guard let ctx else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyTap>.fromOpaque(ctx).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if me.onKey?(type, code, event.flags) == true { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: ctx) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }
}
