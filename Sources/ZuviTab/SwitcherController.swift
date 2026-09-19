import AppKit
import Carbon.HIToolbox

/// Windows-style flow: hold the modifier, tap Tab to cycle, release to switch.
/// A quick tap switches straight to the previous window without flashing the UI.
/// Cmd+F (or Option+F) turns the switcher into a search box that stays open after you let go.
final class SwitcherController: NSObject, NSTextFieldDelegate {
    let mru = MRUTracker()
    private let provider = WindowProvider()
    private let thumbnailer = Thumbnailer()
    private lazy var panel = SwitcherPanel()
    private lazy var peek = PreviewWindow()
    private let live = LivePeek()
    private var dwellWork: DispatchWorkItem?
    // "Bring window forward when resting": where you started, so Esc can take you back.
    private var originWindow: (pid: pid_t, wid: CGWindowID)?
    private var originSpace: UInt64?
    private var didReveal = false
    private var revealedIndexKey: String?

    private var allItems: [SwitchItem] = []
    private var items: [SwitchItem] = []          // allItems after the search filter
    private var selected = 0
    private var active = false
    private var searching = false
    private var thumbsOn = false
    private var previousFront: NSRunningApplication?
    private var showWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var pollTimer: Timer?
    /// Refreshes previews every 1.5 s, but only while the switcher is open.
    private var liveTimer: Timer?
    private var generation = 0
    /// Full-size captures for the peek preview. Memory only, emptied when the switcher closes.
    private var largeCache: [CGWindowID: (CGImage, CGRect)] = [:]

    /// Which modifier must stay held; releasing it commits. Set by AppDelegate.
    var holdModifier: CGEventFlags = .maskCommand
    /// Option mode uses temporary Carbon hotkeys; Command mode gets keys from KeyTap instead.
    var useCarbonNavKeys = false
    var isActive: Bool { active }
    var isSearching: Bool { searching }

    private enum NavKey: UInt32, CaseIterable { case esc = 20, left, right, up, down, ret, find }

    override init() {
        super.init()
        panel.view.onHover = { [weak self] i in self?.select(i) }
        panel.view.onClick = { [weak self] i in self?.select(i); self?.commit() }
        panel.view.onAction = { [weak self] i, a in self?.perform(a, at: i) }
        panel.searchField.delegate = self
        live.onFrame = { [weak self] id, pixels, frame, tile in
            guard let self, self.active, self.items.indices.contains(self.selected),
                  self.items[self.selected].windowID == id else { return }
            self.peek.showLive(pixels, cgFrame: frame)
            if let tile { self.panel.view.thumbnails[id] = tile }
        }
        // Searching makes Zuvi Tab the active app. If you click into another app instead, close quietly
        // (without yanking focus back), so the switcher can never be left stuck open.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self, self.active, self.searching else { return }
            self.close()
        }
    }

    // MARK: Session

    func trigger(reverse: Bool, sameApp: Bool = false) {
        if active { move(reverse ? -1 : 1); return }
        open(reverse: reverse, sameApp: sameApp)
    }

    private func open(reverse: Bool, sameApp: Bool) {
        mru.paused = false
        mru.captureFrontmost()
        let front = NSWorkspace.shared.frontmostApplication
        let s = Settings.shared
        let windows = provider.items(mru: mru, onlyPid: sameApp ? front?.processIdentifier : nil)
        var desktops: [SwitchItem] = []
        if s.showEmptyDesktops && !sameApp && Permissions.accessibility {
            // Emptiness must be judged from every desktop's windows, even when the grid shows only this one.
            let everyWindow = s.currentDesktopOnly ? provider.items(mru: mru, onlyPid: nil, allSpaces: true) : windows
            desktops = provider.emptyDesktops(besides: everyWindow, mru: mru)
        }
        // One list, most recent first: an empty desktop you just left sits right where you'd expect it.
        allItems = (windows + desktops).enumerated()
            .sorted { $0.element.rank != $1.element.rank ? $0.element.rank < $1.element.rank : $0.offset < $1.offset }
            .map(\.element)
        items = allItems
        guard !items.isEmpty else { NSSound.beep(); return }

        // If the first entry is where you are right now (your window here, or the empty desktop you're on),
        // start on the second one, exactly like Windows Alt+Tab.
        let first = items[0]
        let firstIsHere = first.isDesktopEntry ? first.isCurrentDesktop
                                               : (first.pid == front?.processIdentifier && !first.isOtherSpace)
        if reverse { selected = items.count - 1 }
        else { selected = (firstIsHere && items.count > 1) ? 1 : 0 }

        previousFront = front
        originSpace = Spaces.activeSpaceID()
        originWindow = nil
        if let f = front, Permissions.accessibility {
            let ax = AXUIElementCreateApplication(f.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            if let w = AX.element(ax, kAXFocusedWindowAttribute), let wid = AX.windowID(w),
               originSpace.map({ Spaces.spaces(of: wid).contains($0) }) ?? true {
                originWindow = (f.processIdentifier, wid)
            }
        }
        active = true
        searching = false
        generation += 1
        if useCarbonNavKeys { registerNavKeys() }
        startReleasePolling()

        // Like Windows: don't draw anything for a quick tap.
        let work = DispatchWorkItem { [weak self] in self?.show() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func show() {
        guard active else { return }
        showWork?.cancel(); showWork = nil
        thumbsOn = Settings.shared.thumbnails && Permissions.screenRecording
        panel.view.thumbnails = [:]
        redraw()
        guard thumbsOn else { return }
        captureTiles()
        schedulePeek()
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.active, self.panel.isVisible else { return }
            self.captureTiles(liveOnly: true)
            self.refreshPeek()
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    /// `liveOnly`: refresh just the windows on this desktop. Windows on other desktops and minimized ones
    /// can't change while you're not looking at them, so re-capturing them would be wasted work.
    private func captureTiles(liveOnly: Bool = false) {
        let gen = generation
        let ids = allItems
            .filter { !$0.isSensitive && !$0.captureBlocked && (!liveOnly || (!$0.isOtherSpace && !$0.isMinimized)) }
            .compactMap(\.windowID)
        thumbnailer.capture(ids, maxPixel: 520) { [weak self] id, img in
            guard let self, self.active, self.generation == gen, self.live.windowID != id else { return }
            self.panel.view.thumbnails[id] = img
        }
    }

    private func redraw() {
        panel.present(items, selected: selected, thumbnailsOn: thumbsOn, searching: searching)
    }

    func commit() {
        guard active else { return }
        let item = items.indices.contains(selected) ? items[selected] : nil
        let prev = previousFront, wasSearching = searching, revealed = didReveal
        close()
        if let item, item.isEmptyDesktop, let id = item.desktopID {
            if !Spaces.step(to: id) { NSSound.beep() }
        } else if let item {
            Focuser.focus(item, mru: mru)
        } else if wasSearching {
            prev?.activate()   // nothing matched: hand focus back
        }
        if revealed, let item { recordAfterPeeks { mru in
            if item.isEmptyDesktop, let d = item.desktopID { mru.bumpDesktop(d) }
            else { if let id = item.windowID { mru.bumpWindow(id) }; mru.bumpApp(item.pid) }
        } }
    }

    func cancel() {
        let prev = previousFront, wasSearching = searching
        let revealed = didReveal, origin = originWindow, space = originSpace
        close()
        if revealed {
            // A peek brought other windows forward: take you back to exactly where you started.
            if let origin, SkyFocus.focus(pid: origin.pid, wid: origin.wid) {
            } else if let space, Spaces.step(to: space) {
            } else { prev?.activate() }
            recordAfterPeeks { mru in
                if let origin { mru.bumpWindow(origin.wid); mru.bumpApp(origin.pid) }
                else if let space { mru.bumpDesktop(space) }
            }
        } else if wasSearching {
            // Searching made Zuvi Tab the active app; give focus back to where you were.
            prev?.activate()
        }
    }

    private func close() {
        active = false
        searching = false
        showWork?.cancel(); showWork = nil
        peekWork?.cancel(); peekWork = nil
        dwellWork?.cancel(); dwellWork = nil
        live.stop()
        if !didReveal { mru.paused = false }   // after peeks, commit/cancel un-pause once macOS settles
        didReveal = false
        revealedIndexKey = nil
        pollTimer?.invalidate(); pollTimer = nil
        liveTimer?.invalidate(); liveTimer = nil
        if useCarbonNavKeys { unregisterNavKeys() }
        panel.dismiss()
        peek.clear()
        // Privacy: drop every captured pixel, title and search term the moment the switcher closes.
        panel.view.thumbnails = [:]
        panel.view.items = []
        largeCache = [:]
        thumbnailer.reset()
        items = []
        allItems = []
        previousFront = nil
        generation += 1
        // Idle moment: pick up a changed wallpaper now, so the next open doesn't pay for loading it.
        DispatchQueue.main.async { _ = Wallpaper.image() }
    }

    // MARK: Selection

    private func select(_ i: Int) {
        guard items.indices.contains(i), i != selected || !panel.isVisible else { return }
        selected = i
        panel.view.selected = i
        schedulePeek()
    }
    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
        panel.view.selected = selected
        schedulePeek()
    }
    private func moveRow(_ d: Int) {
        let n = selected + d * panel.view.columns
        if items.indices.contains(n) { selected = n; panel.view.selected = n; schedulePeek() }
    }

    // MARK: Peek preview of the selected window

    private func schedulePeek() {
        scheduleLive()
        peekWork?.cancel()
        if didReveal, items.indices.contains(selected), revealKey(items[selected]) == revealedIndexKey {
            peek.clear(); return
        }
        guard active, thumbsOn, panel.isVisible, items.indices.contains(selected) else { peek.clear(); return }
        let item = items[selected]
        guard !item.isDesktopEntry, !item.isSensitive, !item.captureBlocked, !item.isMinimized,
              let wid = item.windowID else { peek.clear(); return }
        if let (img, frame) = largeCache[wid] { peek.show(img, cgFrame: frame); return }
        peek.clear()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            self?.thumbnailer.captureLarge(wid) { img, frame in
                guard let self, self.active, self.generation == gen else { return }
                self.largeCache[wid] = (img, frame)
                if self.items.indices.contains(self.selected), self.items[self.selected].windowID == wid {
                    self.peek.show(img, cgFrame: frame)
                }
            }
        }
        peekWork = work
        // Short delay so flicking through with Tab doesn't capture every window on the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Rest on a window for the chosen delay and its preview goes live (video, calls, progress bars).
    /// Quick flicks never start a stream.
    private func scheduleLive() {
        dwellWork?.cancel(); dwellWork = nil
        let wid = items.indices.contains(selected) ? items[selected].windowID : nil
        if live.windowID != nil && live.windowID != wid { live.stop() }
        if Settings.shared.revealOnRest && !searching { scheduleReveal(); return }
        let delay = Settings.shared.liveDelay
        guard delay > 0, active, thumbsOn, items.indices.contains(selected) else { return }
        let item = items[selected]
        guard !item.isDesktopEntry, !item.isSensitive, !item.captureBlocked, !item.isMinimized,
              let id = item.windowID, live.windowID != id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.items.indices.contains(self.selected),
                  self.items[self.selected].windowID == id else { return }
            self.live.start(id)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// "Bring window forward when resting": after the delay the real window comes forward behind the switcher
    /// (switching desktops if needed), so it's truly live, even apps that stop drawing when hidden.
    private func scheduleReveal() {
        guard active, items.indices.contains(selected) else { return }
        let item = items[selected]
        guard !item.isMinimized, item.windowID != nil || item.isEmptyDesktop else { return }
        let key = revealKey(item)
        guard key != revealedIndexKey else { return }
        let delay = Settings.shared.liveDelay > 0 ? Settings.shared.liveDelay : 1.0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.searching, self.items.indices.contains(self.selected),
                  self.revealKey(self.items[self.selected]) == key else { return }
            self.reveal(self.items[self.selected])
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// macOS reports the peeks' activations a moment later; ignore those, then record only where you ended up.
    private func recordAfterPeeks(_ record: @escaping (MRUTracker) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.active else { return }
            self.mru.paused = false
            record(self.mru)
        }
    }

    private func revealKey(_ item: SwitchItem) -> String {
        if let id = item.desktopID, item.isEmptyDesktop { return "d\(id)" }
        return "w\(item.windowID ?? 0)"
    }

    private func reveal(_ item: SwitchItem) {
        mru.paused = true            // looking isn't using: keep the recent-first order untouched
        didReveal = true
        revealedIndexKey = revealKey(item)
        peek.clear()                 // the real window is in front now; no overlay on top of it
        live.stop()
        if item.isEmptyDesktop, let id = item.desktopID { _ = Spaces.step(to: id) }
        else { Focuser.reveal(item, mru: mru) }
    }

    /// Live refresh of the peek for the selected window.
    private func refreshPeek() {
        guard items.indices.contains(selected) else { return }
        if didReveal, revealKey(items[selected]) == revealedIndexKey { return }
        let item = items[selected]
        guard !item.isDesktopEntry, !item.isSensitive, !item.captureBlocked, !item.isMinimized,
              let wid = item.windowID, live.windowID != wid else { return }   // live frames already cover it
        let gen = generation
        thumbnailer.captureLarge(wid) { [weak self] img, frame in
            guard let self, self.active, self.generation == gen else { return }
            self.largeCache[wid] = (img, frame)
            if self.items.indices.contains(self.selected), self.items[self.selected].windowID == wid {
                self.peek.show(img, cgFrame: frame)
            }
        }
    }

    // MARK: Search

    private func enterSearch() {
        guard active, !searching else { return }
        searching = true
        pollTimer?.invalidate(); pollTimer = nil    // stays open after the modifier is released
        if !panel.isVisible { show() }
        NSApp.activate()
        panel.allowsKey = true
        panel.searchField.placeholderString = Settings.shared.stickyMode ? "Type to search" : "Search windows"
        redraw()
        panel.makeKey()
        panel.makeFirstResponder(panel.searchField)
    }

    func controlTextDidChange(_ note: Notification) {
        let words = panel.searchField.stringValue.lowercased().split(separator: " ").map(String.init)
        items = words.isEmpty ? allItems : allItems.filter { item in
            // Matches only what's already on screen: masked titles stay masked in search too.
            let haystack = (item.title + " " + item.appName + " " + (item.spaceLabel ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        selected = 0
        redraw()
        schedulePeek()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): move(1)
        default: return false
        }
        return true
    }

    // MARK: Actions on windows (hover buttons and keys)

    private func perform(_ action: TileAction, at i: Int) {
        guard items.indices.contains(i), !items[i].isDesktopEntry else { return }
        let item = items[i]
        switch action {
        case .close:
            guard let w = item.axWindow, let button = AX.element(w, kAXCloseButtonAttribute) else { NSSound.beep(); return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            removeItems { $0.pid == item.pid && $0.windowID == item.windowID }
        case .minimize:
            guard let w = item.axWindow else { NSSound.beep(); return }
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            for k in allItems.indices where allItems[k].windowID == item.windowID && allItems[k].pid == item.pid {
                allItems[k].isMinimized = true
            }
            items[i].isMinimized = true
            redraw()
            schedulePeek()
        case .quit:
            item.app.terminate()
            removeItems { $0.pid == item.pid }
        }
    }

    private func removeItems(where match: (SwitchItem) -> Bool) {
        allItems.removeAll(where: match)
        items.removeAll(where: match)
        guard !items.isEmpty || searching else { cancel(); return }
        selected = min(selected, max(0, items.count - 1))
        redraw()
        schedulePeek()
    }

    /// Keys pressed while the switcher is open in Command mode (delivered by KeyTap).
    /// Mirrors macOS Cmd+Tab: Q quits, H hides; plus W closes, M minimizes, F searches.
    func handleKey(_ code: Int, shift: Bool) {
        guard active else { return }
        switch code {
        case kVK_Escape: cancel()
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_UpArrow: moveRow(-1)
        case kVK_DownArrow: moveRow(1)
        case kVK_Return: commit()
        case kVK_ANSI_Grave: move(shift ? -1 : 1)
        case kVK_ANSI_F: enterSearch()
        case kVK_ANSI_Q: perform(.quit, at: selected)
        case kVK_ANSI_W: perform(.close, at: selected)
        case kVK_ANSI_M: perform(.minimize, at: selected)
        case kVK_ANSI_H: if items.indices.contains(selected), !items[selected].isDesktopEntry { items[selected].app.hide() }
        default: break
        }
    }

    // MARK: Modifier release and Option-mode keys

    /// Detects modifier release by reading modifier state. Needs no permission and sees no keystrokes.
    private func startReleasePolling() {
        let t = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            guard let self, !self.searching else { return }
            guard !CGEventSource.flagsState(.combinedSessionState).contains(self.holdModifier) else { return }
            // Sticky mode keeps the switcher open after release; a quick tap still just switches.
            if Settings.shared.stickyMode && self.panel.isVisible { self.enterSearch() } else { self.commit() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Esc / arrows / Return / F are hotkeys only while the switcher is open, then released again.
    private func registerNavKeys() {
        let hk = HotKeyCenter.shared, opt = optionKey
        hk.register(NavKey.esc.rawValue, key: kVK_Escape, modifiers: opt) { [weak self] in self?.cancel() }
        hk.register(NavKey.left.rawValue, key: kVK_LeftArrow, modifiers: opt) { [weak self] in self?.move(-1) }
        hk.register(NavKey.right.rawValue, key: kVK_RightArrow, modifiers: opt) { [weak self] in self?.move(1) }
        hk.register(NavKey.up.rawValue, key: kVK_UpArrow, modifiers: opt) { [weak self] in self?.moveRow(-1) }
        hk.register(NavKey.down.rawValue, key: kVK_DownArrow, modifiers: opt) { [weak self] in self?.moveRow(1) }
        hk.register(NavKey.ret.rawValue, key: kVK_Return, modifiers: opt) { [weak self] in self?.commit() }
        hk.register(NavKey.find.rawValue, key: kVK_ANSI_F, modifiers: opt) { [weak self] in self?.enterSearch() }
    }
    private func unregisterNavKeys() {
        NavKey.allCases.forEach { HotKeyCenter.shared.unregister($0.rawValue) }
    }
}
