import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let switcher = SwitcherController()
    private let keyTap = KeyTap()
    private var swallowedKeyDowns = Set<Int>()
    private var permissionWatch: Timer?
    private var activeShortcut = "Option+Tab"
    private var shortcutProblem: String?
    private var glassSetting = AppDelegate.readGlassSetting()
    private var pendingGlassSetting: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Only one Zuvi Tab at a time: two copies would both grab Cmd+Tab and handle every key twice.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        HotKeyCenter.shared.install()
        keyTap.onKey = { [weak self] type, code, flags in self?.handleTap(type, code, flags) ?? false }
        setupShortcuts()
        DispatchQueue.main.async { _ = Wallpaper.image() }   // warm up so the first Cmd+Tab never waits on it
        // Follow permission changes both ways: switch to Command+Tab once Accessibility is granted, and fall
        // back to Option+Tab if it's revoked, instead of Cmd+Tab silently doing nothing.
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let wantCommand = Settings.shared.useCommandTab && Permissions.accessibility
            if wantCommand != (self.activeShortcut == "Command+Tab") { self.setupShortcuts() }
            self.checkGlassSetting()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        // Ask for Screen Recording once, not on every launch; the menu has a button for it after that.
        if Settings.shared.thumbnails && !Permissions.screenRecording && !Settings.shared.didPromptSR {
            Settings.shared.didPromptSR = true
            Permissions.requestScreenRecording()
        }
        if !Permissions.accessibility && !Settings.shared.didPromptAX {
            Settings.shared.didPromptAX = true
            Permissions.promptAccessibility()
        }
    }

    // MARK: Liquid Glass setting

    /// macOS reads the Liquid Glass tint (System Settings > Appearance) once, when an app launches, so a running
    /// app never sees the slider move. We watch it, and once it has stopped changing, restart quietly so the
    /// switcher matches the new setting. Never while the switcher is open.
    private static func readGlassSetting() -> String {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return ["NSGlassTintAmount", "NSGlassBuddyTintAmount"].map { key in
            (CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.stringValue ?? "-"
        }.joined(separator: "|")
    }

    private func checkGlassSetting() {
        guard #available(macOS 26.0, *) else { return }
        let now = AppDelegate.readGlassSetting()
        guard now != glassSetting else { pendingGlassSetting = nil; return }
        // Wait until two checks in a row agree, so dragging the slider doesn't cause several restarts.
        guard now == pendingGlassSetting, !switcher.isActive else { pendingGlassSetting = now; return }
        relaunch()
    }

    private func relaunch() {
        // The app path goes in as a separate argument ($1), never inside the shell code itself,
        // so no folder name can ever be interpreted as a command.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; exec /usr/bin/open -- \"$1\"", "zuvitab-relaunch", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Shortcuts

    /// Command+Tab (default) replaces the macOS switcher and needs Accessibility for the key filter.
    /// Until that is granted, or if the user prefers, Option+Tab works with zero permissions.
    private func setupShortcuts() {
        let hk = HotKeyCenter.shared
        (1...6).forEach { hk.unregister(UInt32($0)) }
        keyTap.stop()

        shortcutProblem = nil
        if Settings.shared.useCommandTab && Permissions.accessibility && keyTap.start() {
            switcher.holdModifier = .maskCommand
            switcher.useCarbonNavKeys = false
            activeShortcut = "Command+Tab"
            return
        }

        let opt = optionKey, shift = shiftKey
        let ok = hk.register(1, key: kVK_Tab, modifiers: opt) { [weak self] in self?.switcher.trigger(reverse: false) }
        if !ok { shortcutProblem = "Option+Tab is taken by another app" }
        hk.register(2, key: kVK_Tab, modifiers: opt | shift) { [weak self] in self?.switcher.trigger(reverse: true) }
        hk.register(3, key: kVK_ANSI_Grave, modifiers: opt) { [weak self] in self?.switcher.trigger(reverse: false, sameApp: true) }
        hk.register(4, key: kVK_ANSI_Grave, modifiers: opt | shift) { [weak self] in self?.switcher.trigger(reverse: true, sameApp: true) }

        switcher.holdModifier = .maskAlternate
        switcher.useCarbonNavKeys = true
        activeShortcut = "Option+Tab"
    }

    /// Runs for every key event while the filter is on, so it must stay tiny and never block.
    private func handleTap(_ type: CGEventType, _ code: Int, _ flags: CGEventFlags) -> Bool {
        if type == .keyUp { return swallowedKeyDowns.remove(code) != nil }
        guard type == .keyDown, flags.contains(.maskCommand) else { return false }

        if code == kVK_Tab && !flags.contains(.maskControl) {
            swallowedKeyDowns.insert(code)
            let reverse = flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in self?.switcher.trigger(reverse: reverse) }
            return true
        }
        if switcher.isActive && !switcher.isSearching {
            // While the switcher is open, Command+key belongs to it, never to the app underneath.
            // (While you type a search, Cmd+A / Cmd+V etc. go to the search box as normal.)
            swallowedKeyDowns.insert(code)
            let shift = flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in self?.switcher.handleKey(code, shift: shift) }
            return true
        }
        return false
    }

    // MARK: Menu (rebuilt each time it opens so it always reflects live permission state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if activeShortcut == "Command+Tab" {
            menu.addItem(info("Command+Tab: switch.  While open: F search, W close, M minimize, Q quit, H hide"))
        } else {
            menu.addItem(info("Option+Tab: switch.  Option+F search, Option+`: same app"))
        }
        menu.addItem(ActionItem("Use Command+Tab (replaces the macOS switcher)", checked: s.useCommandTab) { [weak self] in
            s.useCommandTab.toggle()
            if s.useCommandTab && !Permissions.accessibility {
                Permissions.promptAccessibility()
                Permissions.openPane("Privacy_Accessibility")
            }
            self?.setupShortcuts()
        })
        if s.useCommandTab && activeShortcut != "Command+Tab" {
            menu.addItem(info("Using Option+Tab until Accessibility is granted"))
        }
        if let shortcutProblem { menu.addItem(info("⚠︎ \(shortcutProblem)")) }
        menu.addItem(.separator())

        if Permissions.accessibility {
            menu.addItem(info("✓ Accessibility granted (window switching)"))
        } else {
            menu.addItem(ActionItem("Grant Accessibility for window switching…") {
                Permissions.promptAccessibility()
                Permissions.openPane("Privacy_Accessibility")
            })
        }
        if s.thumbnails {
            if Permissions.screenRecording {
                menu.addItem(info("✓ Screen Recording granted (thumbnails)"))
            } else {
                menu.addItem(ActionItem("Grant Screen Recording for thumbnails…") {
                    Permissions.requestScreenRecording()
                    Permissions.openPane("Privacy_ScreenCapture")
                })
            }
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Show window titles", checked: s.showTitles) { s.showTitles.toggle() })
        menu.addItem(ActionItem("Window previews (needs Screen Recording)", checked: s.thumbnails) {
            s.thumbnails.toggle()
            if s.thumbnails && !Permissions.screenRecording { Permissions.requestScreenRecording() }
        })
        let liveItem = NSMenuItem(title: "Live preview when resting on a window", action: nil, keyEquivalent: "")
        let liveMenu = NSMenu(); liveMenu.autoenablesItems = false
        for (label, value) in [("Off", 0.0), ("After half a second", 0.5), ("After 1 second", 1.0), ("After 2 seconds", 2.0)] {
            liveMenu.addItem(ActionItem(label, checked: s.liveDelay == value) { s.liveDelay = value })
        }
        liveItem.submenu = liveMenu
        menu.addItem(liveItem)
        menu.addItem(ActionItem("Bring window forward when resting (Esc goes back)", checked: s.revealOnRest) { s.revealOnRest.toggle() })
        menu.addItem(ActionItem("Mask private browsing windows", checked: s.maskPrivateWindows) { s.maskPrivateWindows.toggle() })
        menu.addItem(ActionItem("Include apps with no open windows", checked: s.includeWindowlessApps) { s.includeWindowlessApps.toggle() })
        menu.addItem(ActionItem("Include empty desktops", checked: s.showEmptyDesktops) { s.showEmptyDesktops.toggle() })
        menu.addItem(ActionItem("Only show windows on the current desktop", checked: s.currentDesktopOnly) { s.currentDesktopOnly.toggle() })
        menu.addItem(ActionItem("Sticky mode: stay open after releasing the key", checked: s.stickyMode) { s.stickyMode.toggle() })
        menu.addItem(ActionItem("Bring windows from other desktops here", checked: s.bringToCurrentSpace) { s.bringToCurrentSpace.toggle() })

        let ex = NSMenuItem(title: "Never preview these apps", action: nil, keyEquivalent: "")
        ex.submenu = excludedMenu()
        menu.addItem(ex)
        menu.addItem(.separator())

        let login = SMAppService.mainApp.status == .enabled
        menu.addItem(ActionItem("Open at login", checked: login) {
            do { login ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() }
            catch { self.alert("Could not change login item", error.localizedDescription) }
        })
        menu.addItem(ActionItem("How Zuvi Tab protects your privacy…") { self.showPrivacy() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Zuvi Tab") { NSApp.terminate(nil) })
    }

    private func excludedMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let s = Settings.shared
        var excluded = s.excluded
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var seen = Set<String>()
        for app in running {
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
            let item = ActionItem(app.localizedName ?? id, checked: excluded.contains(id)) {
                if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
                s.excluded = excluded
            }
            item.image = app.icon.map { i in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
            m.addItem(item)
        }
        let notRunning = excluded.subtracting(seen).sorted()
        if !notRunning.isEmpty {
            m.addItem(.separator())
            m.addItem(info("Not running:"))
            for id in notRunning {
                m.addItem(ActionItem(id, checked: true) { s.excluded.remove(id) })
            }
        }
        return m
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func showPrivacy() {
        alert("How Zuvi Tab protects your privacy", """
        • No network code. Zuvi Tab never connects to the internet: no telemetry, no updates, no crash reports.
        • Nothing written to disk except these menu preferences. Window titles and the recently-used order live only in memory and vanish when you quit.
        • Least permission. Option+Tab mode needs no permission and never sees your other keystrokes. Command+Tab mode has to filter keyboard events, like every Cmd+Tab replacement. It reads only the key code while Command is held, never the typed character, and keeps nothing. Accessibility is also used to list and raise windows. Screen Recording is only asked for if you turn on thumbnails.
        • Previews are captured only while the switcher is open, never in the background, and dropped the moment it closes. Nothing is cached between uses.
        • Live preview streams only the one window you're resting on, only while the switcher is open. Frames are shown, never stored, and macOS shows its screen-capture indicator while it runs.
        • Password managers and any app you add are never previewed and their window titles are hidden.
        • Any window whose app asks macOS not to be captured (banking, password managers, protected video) is never previewed.
        • Private browsing windows are masked when the browser marks them in the title.
        • The switcher is hidden from screenshots and screen sharing, so it can't leak window titles during a call.
        """)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = true
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}
