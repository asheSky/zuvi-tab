import AppKit
import ApplicationServices

/// Maps an AX window to its CGWindowID. Private but long-stable; used by most window managers.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (value(el, attr) as? NSNumber)?.boolValue }
    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(el, attr) as? [AXUIElement]) ?? []
    }
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = value(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
    static func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
