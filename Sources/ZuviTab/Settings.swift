import Foundation

/// The ONLY thing Zuvi Tab persists: a handful of preferences in UserDefaults.
/// No window titles, no history, no thumbnails ever touch disk.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Apps whose windows are never previewed and whose titles are never shown.
    static let defaultExcluded = [
        "com.1password.1password",      // 1Password 8
        "com.agilebits.onepassword7",   // 1Password 7
        "com.bitwarden.desktop",        // Bitwarden
        "org.keepassxc.keepassxc",      // KeePassXC
        "com.apple.keychainaccess",     // Keychain Access
        "com.apple.Passwords",          // Apple Passwords
    ]

    /// Best-effort markers some browsers put in private-window titles.
    static let privateMarkers = ["private browsing", "incognito", "inprivate", "private window"]

    private init() {
        d.register(defaults: [
            "showTitles": true,
            "thumbnails": true,           // previews; need Screen Recording, captured only while open
            "maskPrivateWindows": true,
            "includeWindowlessApps": false,
            "excludedBundleIDs": Settings.defaultExcluded,
            "didPromptAX": false,
            "didPromptSR": false,
            "useCommandTab": true,        // take over Cmd+Tab (needs Accessibility), else Option+Tab
            "stickyMode": false,
            "revealOnRest": false,        // resting on a tile brings the real window forward behind the switcher
            "liveDelay": 1.0,             // seconds resting on a window before its preview goes live; 0 = off
            "currentDesktopOnly": false,
            "showEmptyDesktops": true,    // empty desktops as tiles at the end of the grid  // like Windows: "show windows open on: only the desktop I'm using"          // releasing the modifier keeps the switcher open
            "bringToCurrentSpace": false, // move windows from other desktops here instead of jumping there
        ])
    }

    var showTitles: Bool { get { d.bool(forKey: "showTitles") } set { d.set(newValue, forKey: "showTitles") } }
    var thumbnails: Bool { get { d.bool(forKey: "thumbnails") } set { d.set(newValue, forKey: "thumbnails") } }
    var maskPrivateWindows: Bool { get { d.bool(forKey: "maskPrivateWindows") } set { d.set(newValue, forKey: "maskPrivateWindows") } }
    var includeWindowlessApps: Bool { get { d.bool(forKey: "includeWindowlessApps") } set { d.set(newValue, forKey: "includeWindowlessApps") } }
    var showEmptyDesktops: Bool { get { d.bool(forKey: "showEmptyDesktops") } set { d.set(newValue, forKey: "showEmptyDesktops") } }
    var currentDesktopOnly: Bool { get { d.bool(forKey: "currentDesktopOnly") } set { d.set(newValue, forKey: "currentDesktopOnly") } }
    var liveDelay: Double { get { d.double(forKey: "liveDelay") } set { d.set(newValue, forKey: "liveDelay") } }
    var revealOnRest: Bool { get { d.bool(forKey: "revealOnRest") } set { d.set(newValue, forKey: "revealOnRest") } }
    var stickyMode: Bool { get { d.bool(forKey: "stickyMode") } set { d.set(newValue, forKey: "stickyMode") } }
    var bringToCurrentSpace: Bool { get { d.bool(forKey: "bringToCurrentSpace") } set { d.set(newValue, forKey: "bringToCurrentSpace") } }
    var useCommandTab: Bool { get { d.bool(forKey: "useCommandTab") } set { d.set(newValue, forKey: "useCommandTab") } }
    var didPromptSR: Bool { get { d.bool(forKey: "didPromptSR") } set { d.set(newValue, forKey: "didPromptSR") } }
    var didPromptAX: Bool { get { d.bool(forKey: "didPromptAX") } set { d.set(newValue, forKey: "didPromptAX") } }
    var excluded: Set<String> {
        get { Set(d.stringArray(forKey: "excludedBundleIDs") ?? []) }
        set { d.set(newValue.sorted(), forKey: "excludedBundleIDs") }
    }

    func isPrivateTitle(_ title: String) -> Bool {
        let l = title.lowercased()
        return Settings.privateMarkers.contains { l.contains($0) }
    }
}
