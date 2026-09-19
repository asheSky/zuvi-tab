import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey.
/// Needs NO permissions: the system only tells us when our exact combo is pressed.
/// We never see any other keystroke (unlike an event tap, which is a keylogger-class API).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            HotKeyCenter.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ id: UInt32, key: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        unregister(id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5054_4142), id: id) // 'PTAB'
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers.removeValue(forKey: id)
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }
}
