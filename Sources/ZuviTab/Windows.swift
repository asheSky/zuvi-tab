import AppKit
import ApplicationServices

struct SwitchItem {
    let app: NSRunningApplication
    let axWindow: AXUIElement?
    let windowID: CGWindowID?
    var title: String        // already privacy-filtered; raw titles never leave WindowProvider
    let appName: String
    var isMinimized: Bool
    let isAppHidden: Bool
    let isSensitive: Bool    // excluded app or private window: never captured, title masked
    var isOtherSpace = false // lives on another desktop Space or full-screen Space
    var captureBlocked = false // the app asked macOS not to let its window be captured: never previewed
    var spaceLabel: String?  // "Desktop 2" / "full screen" for windows on other Spaces
    // Empty desktops appear as ordinary tiles at the end of the grid.
    var isDesktopEntry = false
    var isCurrentDesktop = false
    var desktopID: UInt64?
    var desktopUUID: String?  // for per-desktop wallpapers
    var isEmptyDesktop = false
    var rank = 0             // lower = used more recently; windows and desktops share one timeline
    var pid: pid_t { app.processIdentifier }
}

/// In-memory most-recently-used order. Holds only numeric IDs, never titles. Lost on quit.
/// Windows and desktops share one timeline, so an empty desktop you just left comes right back up.
final class MRUTracker {
    private enum Key: Hashable { case window(CGWindowID), desktop(UInt64) }
    private var recent: [Key] = []
    private var apps: [pid_t] = []
    /// True while "bring forward" peeks are happening: looking at a window isn't using it.
    var paused = false

    init() {
        if let f = NSWorkspace.shared.frontmostApplication { apps = [f.processIdentifier] }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self?.bumpApp(pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.bumpFocusedWindow(of: pid) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.apps.removeAll { $0 == app.processIdentifier }
            self?.detach(app.processIdentifier)
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            // New apps need a moment before they answer Accessibility requests.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.attach(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let sid = Spaces.activeSpaceID() { self?.bumpDesktop(sid) }
        }
        DispatchQueue.main.async { [weak self] in self?.attachFocusObservers() }
    }

    func bumpApp(_ pid: pid_t) {
        guard !paused else { return }
        apps.removeAll { $0 == pid }; apps.insert(pid, at: 0)
    }
    func bumpWindow(_ id: CGWindowID) { bump(.window(id)) }
    func bumpDesktop(_ id: UInt64) { bump(.desktop(id)) }
    private func bump(_ key: Key) {
        guard !paused else { return }
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        if recent.count > 300 { recent.removeLast(recent.count - 300) }
    }
    func appRank(_ pid: pid_t) -> Int { apps.firstIndex(of: pid) ?? 999 }
    func windowRank(_ id: CGWindowID) -> Int? { recent.firstIndex(of: .window(id)) }
    func desktopRank(_ id: UInt64) -> Int? { recent.firstIndex(of: .desktop(id)) }

    /// Bumps the app's focused window, but only if it's on the desktop you're looking at. On an empty desktop
    /// macOS keeps the previous app active; its window is elsewhere and must not count as "where you are".
    func bumpFocusedWindow(of pid: pid_t) {
        guard Permissions.accessibility else { return }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let w = AX.element(ax, kAXFocusedWindowAttribute), let id = AX.windowID(w) else { return }
        if let current = Spaces.activeSpaceID(), !Spaces.spaces(of: id).isEmpty, !Spaces.spaces(of: id).contains(current) { return }
        bumpWindow(id)
    }

    // MARK: Live focus tracking
    // Each app tells us when its focused window changes, so the recent-first order stays right even when you
    // click between two windows of the same app. We only ever read the window's number, never its contents.

    private var observers: [pid_t: AXObserver] = [:]

    func attachFocusObservers() {
        guard Permissions.accessibility else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app.processIdentifier)
        }
    }

    private func attach(_ pid: pid_t) {
        guard observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier, Permissions.accessibility else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, mruFocusCallback, &observer) == .success, let observer else { return }
        let ax = AXUIElementCreateApplication(pid)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, ax, kAXFocusedWindowChangedNotification as CFString, ctx)
        AXObserverAddNotification(observer, ax, kAXMainWindowChangedNotification as CFString, ctx)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Only the app you're actually using counts: a background app opening a window doesn't jump the queue.
    fileprivate func focusChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = AX.windowID(element) else { return }
        bumpWindow(id)
    }

    /// Called as the switcher opens: records the desktop you're on, then the window you're in (if it's here).
    func captureFrontmost() {
        if observers.isEmpty { attachFocusObservers() }   // e.g. Accessibility was granted after launch
        if let sid = Spaces.activeSpaceID() { bumpDesktop(sid) }
        guard let f = NSWorkspace.shared.frontmostApplication else { return }
        bumpApp(f.processIdentifier)
        bumpFocusedWindow(of: f.processIdentifier)
    }
}

private let mruFocusCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    Unmanaged<MRUTracker>.fromOpaque(refcon).takeUnretainedValue().focusChanged(element)
}

/// Asks the window server which Spaces a window belongs to. Lets us find windows on other
/// desktops and full-screen Spaces, which the Accessibility API does not report.
enum Spaces {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let mainConn: MainConn? = sym("CGSMainConnectionID")
    private static let copySpaces: CopySpaces? = sym("CGSCopySpacesForWindows")

    static var available: Bool { mainConn != nil && copySpaces != nil }

    static func isOnAnySpace(_ wid: CGWindowID) -> Bool { !spaces(of: wid).isEmpty }

    static func spaces(of wid: CGWindowID) -> [UInt64] {
        guard let mainConn, let copySpaces else { return [] }
        let ids = [NSNumber(value: wid)] as CFArray
        guard let spaces = copySpaces(mainConn(), 7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return spaces.map(\.uint64Value)
    }

    struct Desktop {
        let id: UInt64
        let uuid: String?
        let label: String
        let isFullscreen: Bool
        let isCurrent: Bool
        let display: Int
        let position: Int   // order within its display, as in Mission Control
    }

    private typealias CopyManaged = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let copyManaged: CopyManaged? = sym("CGSCopyManagedDisplaySpaces")

    /// Every desktop and full-screen Space, in Mission Control order, numbered like Mission Control
    /// (numbering restarts on each display when displays have separate Spaces).
    static func desktops() -> [Desktop] {
        guard let mainConn, let copyManaged,
              let displays = copyManaged(mainConn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out: [Desktop] = []
        for (index, display) in displays.enumerated() {
            let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            var number = 0
            for (position, space) in (display["Spaces"] as? [[String: Any]] ?? []).enumerated() {
                guard let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
                let fullscreen = ((space["type"] as? NSNumber)?.intValue ?? 0) != 0
                if !fullscreen { number += 1 }
                var label = fullscreen ? "Full screen" : "Desktop \(number)"
                if displays.count > 1 && index > 0 { label += " · Display \(index + 1)" }
                out.append(Desktop(id: id, uuid: space["uuid"] as? String, label: label, isFullscreen: fullscreen, isCurrent: id == current,
                                   display: index, position: position))
            }
        }
        return out
    }

    /// Goes to a desktop that has no windows by pressing macOS's own "Move a space left/right" shortcut
    /// (Control+Arrow, on by default) the right number of times. Returns false if it can't work out the route.
    static func step(to target: UInt64) -> Bool {
        let all = desktops()
        guard let t = all.first(where: { $0.id == target }),
              let cur = all.first(where: { $0.display == t.display && $0.isCurrent }) else { return false }
        let steps = t.position - cur.position
        guard steps != 0 else { return true }
        let key: CGKeyCode = steps > 0 ? 124 : 123   // right / left arrow
        for n in 0..<abs(steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(n) * 0.12) { pressControl(key) }
        }
        return true
    }

    private static func pressControl(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = [.maskControl, .maskSecondaryFn]   // arrow keys carry the fn flag in the shortcut definition
            e?.post(tap: .cghidEventTap)
        }
    }

    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private static let activeSpace: ActiveSpace? = sym("CGSGetActiveSpace")
    private static let spaceType: SpaceType? = sym("CGSSpaceGetType")
    private static let moveWindows: MoveWindows? = sym("CGSMoveWindowsToManagedSpace")

    static func activeSpaceID() -> UInt64? {
        guard let mainConn, let activeSpace else { return nil }
        let id = activeSpace(mainConn())
        return id == 0 ? nil : id
    }

    /// Moves a window from another desktop onto the current one. Returns false, leaving it untouched, when the
    /// current or source Space is full screen, the API is missing, or macOS refuses the move.
    static func moveToCurrentSpace(_ wid: CGWindowID) -> Bool {
        guard let mainConn, let activeSpace, let spaceType, let moveWindows else { return false }
        let cid = mainConn()
        let current = activeSpace(cid)
        guard current != 0, spaceType(cid, current) == 0 else { return false }       // 0 = normal desktop, 4 = full screen
        let from = spaces(of: wid)
        guard from.count == 1, let source = from.first, source != current,
              spaceType(cid, source) == 0 else { return false }                          // never pull a window out of full screen
        moveWindows(cid, [NSNumber(value: wid)] as CFArray, current)
        return spaces(of: wid) == [current]
    }
}

/// Accessibility only reports windows on the current Space. This private (but long-stable) call builds an
/// AX handle for any window of a process, so windows on other Spaces can be verified as real, titled windows.
enum RemoteAX {
    private typealias CreateFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let create: CreateFn? = {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let p = dlsym(h, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(p, to: CreateFn.self)
    }()
    /// In-memory only: window id -> AX handle, so the brute-force search runs once per window.
    private static var cache: [CGWindowID: AXUIElement] = [:]
    /// Window ids that turned out not to be real windows (invisible helpers some apps keep on a Space).
    /// Remembered for 5 minutes so every Cmd+Tab doesn't pay for searching them again.
    private static var misses: [CGWindowID: Date] = [:]

    static var available: Bool { create != nil }

    /// Returns AX handles for as many of `wanted` as can be found, searching at most ~150 ms per app.
    static func windows(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        if cache.count > 400 { cache = cache.filter { AX.windowID($0.value) == $0.key } }   // drop closed windows
        for id in wanted { if let el = cache[id], AX.windowID(el) == id { found[id] = el } }
        let now = Date()
        misses = misses.filter { now.timeIntervalSince($0.value) < 300 }
        let search = wanted.filter { found[$0] == nil && misses[$0] == nil }
        guard let create, !search.isEmpty else { return found }
        defer { for id in search where found[id] == nil { misses[id] = now } }

        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0)) { token.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: Int32(0x636f_636f)) { token.replaceSubrange(8..<12, with: $0) }
        let deadline = Date().addingTimeInterval(0.15)
        for elementID: UInt64 in 0..<2000 {
            if search.allSatisfy({ found[$0] != nil }) || Date() > deadline { break }
            withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
            guard let el = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            guard let id = AX.windowID(el), search.contains(id), found[id] == nil,
                  // Electron apps (Cursor, VS Code) expose a hidden AXUnknown element with the same window
                  // number just before the real window; taking that one would drop the window.
                  AX.string(el, kAXRoleAttribute) == kAXWindowRole else { continue }
            found[id] = el
            cache[id] = el
        }
        return found
    }
}

final class WindowProvider {
    func items(mru: MRUTracker, onlyPid: pid_t?, allSpaces: Bool = false) -> [SwitchItem] {
        let s = Settings.shared
        let excluded = s.excluded
        let trusted = Permissions.accessibility
        let me = ProcessInfo.processInfo.processIdentifier
        var ranked: [(Int, SwitchItem)] = []
        var axIDs = Set<CGWindowID>()
        let cgList = trusted ? (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                                as? [[String: Any]] ?? []) : []
        // Apps like password managers, banking apps and DRM video mark their windows "don't capture".
        // We honour that: those windows are never previewed.
        // Without Screen Recording macOS reports every window as "don't capture", so only judge when we have it.
        var noCapture = Set<CGWindowID>()
        for w in cgList where Permissions.screenRecording && (w[kCGWindowSharingState as String] as? Int) == 0 {
            if let n = w[kCGWindowNumber as String] as? Int { noCapture.insert(CGWindowID(n)) }
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        for app in apps {
            let pid = app.processIdentifier
            if let onlyPid, pid != onlyPid { continue }
            let name = app.localizedName ?? "App"
            let isExcluded = app.bundleIdentifier.map { excluded.contains($0) } ?? false
            let appRank = mru.appRank(pid)
            var count = 0

            if trusted {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.25)   // never hang on a frozen app
                for (i, w) in AX.elements(axApp, kAXWindowsAttribute).enumerated() {
                    guard AX.string(w, kAXRoleAttribute) == kAXWindowRole else { continue }
                    let sub = AX.string(w, kAXSubroleAttribute)
                    guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { continue }
                    if let sz = AX.size(w), sz.width < 60 || sz.height < 40 { continue }

                    let raw = AX.string(w, kAXTitleAttribute) ?? ""
                    let minimized = AX.bool(w, kAXMinimizedAttribute) ?? false
                    let wid = AX.windowID(w)
                    if let wid { axIDs.insert(wid) }
                    let isPrivate = s.maskPrivateWindows && s.isPrivateTitle(raw)

                    let title: String
                    if isExcluded { title = "\(name) (hidden)" }
                    else if isPrivate { title = "Private window" }
                    else if !s.showTitles || raw.isEmpty { title = name }
                    else { title = raw }

                    var rank = wid.flatMap { mru.windowRank($0) } ?? (10_000 + appRank * 100 + i)
                    if minimized { rank += 1_000_000 }
                    var item = SwitchItem(app: app, axWindow: w, windowID: wid, title: title,
                                          appName: name, isMinimized: minimized,
                                          isAppHidden: app.isHidden, isSensitive: isExcluded || isPrivate)
                    item.captureBlocked = wid.map { noCapture.contains($0) } ?? false
                    item.rank = rank
                    ranked.append((rank, item))
                    count += 1
                }
            }

            // Without Accessibility we can only switch apps, like Cmd+Tab.
            if count == 0 && (!trusted || s.includeWindowlessApps) {
                let rank = trusted ? 2_000_000 + appRank : appRank
                var item = SwitchItem(app: app, axWindow: nil, windowID: nil, title: name, appName: name,
                                      isMinimized: false, isAppHidden: app.isHidden, isSensitive: isExcluded)
                item.rank = rank
                ranked.append((rank, item))
            }
        }
        if trusted && Spaces.available && (allSpaces || !s.currentDesktopOnly) {
            ranked += otherSpaceWindows(apps: apps, known: axIDs, onlyPid: onlyPid, mru: mru, list: cgList)
            // Name the desktop each of those windows lives on.
            var byID: [UInt64: Spaces.Desktop] = [:]
            for d in Spaces.desktops() { byID[d.id] = d }
            for k in ranked.indices where ranked[k].1.isOtherSpace {
                if let wid = ranked[k].1.windowID, let sid = Spaces.spaces(of: wid).first, let d = byID[sid] {
                    ranked[k].1.spaceLabel = d.isFullscreen ? "full screen" : d.label
                }
            }
        }
        return ranked.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Empty desktops, as tiles placed by when you last used them. Desktops that have windows don't need a tile:
    /// their windows are already in the grid, labelled with the desktop, and picking one goes there.
    /// `windows` must include every desktop's windows, even if the grid only shows the current one.
    func emptyDesktops(besides windows: [SwitchItem], mru: MRUTracker) -> [SwitchItem] {
        guard Spaces.available, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return [] }
        var occupied = Set<UInt64>()
        for w in windows { if let id = w.windowID, let sid = Spaces.spaces(of: id).first { occupied.insert(sid) } }
        return Spaces.desktops().filter { !$0.isFullscreen && !occupied.contains($0.id) }.map { d in
            var item = SwitchItem(app: finder, axWindow: nil, windowID: nil, title: d.label, appName: d.label,
                                  isMinimized: false, isAppHidden: false, isSensitive: false)
            item.isDesktopEntry = true
            item.isEmptyDesktop = true
            item.isCurrentDesktop = d.isCurrent
            item.isOtherSpace = !d.isCurrent
            item.desktopID = d.id
            item.desktopUUID = d.uuid
            item.rank = mru.desktopRank(d.id) ?? 3_000_000   // never visited: after everything else
            return item
        }
    }

    /// Windows on other desktops / full-screen Spaces. Titles come from the window server only if
    /// Screen Recording is already granted; otherwise we show just the app name (no extra permission asked).
    private func otherSpaceWindows(apps: [NSRunningApplication], known: Set<CGWindowID>,
                                   onlyPid: pid_t?, mru: MRUTracker, list: [[String: Any]]) -> [(Int, SwitchItem)] {
        let s = Settings.shared
        let excluded = s.excluded
        let canReadTitles = Permissions.screenRecording
        var byPid: [pid_t: NSRunningApplication] = [:]
        for a in apps { byPid[a.processIdentifier] = a }
        // Candidates: layer-0, reasonably sized windows that sit on some Space but not the current one.
        var candidates: [pid_t: [(CGWindowID, [String: Any])]] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pidNum = w[kCGWindowOwnerPID as String] as? Int,
                  let app = byPid[pid_t(pidNum)],
                  let widNum = w[kCGWindowNumber as String] as? Int else { continue }
            let wid = CGWindowID(widNum)
            let pid = app.processIdentifier
            if known.contains(wid) { continue }
            if let onlyPid, pid != onlyPid { continue }
            if (w[kCGWindowIsOnscreen as String] as? Bool) == true { continue } // current Space: AX already decided
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width >= 120, r.height >= 80 else { continue }
            guard Spaces.isOnAnySpace(wid) else { continue }  // ordered-out/closed windows belong to no Space
            candidates[pid, default: []].append((wid, w))
        }

        var out: [(Int, SwitchItem)] = []
        for (pid, cands) in candidates {
            guard let app = byPid[pid] else { continue }
            let name = app.localizedName ?? "App"
            let isExcluded = app.bundleIdentifier.map { excluded.contains($0) } ?? false
            // Only keep windows Accessibility confirms as real windows. Apps like Cursor keep invisible
            // helper windows on a Space; the window server lists them, AX does not call them standard windows.
            let confirmed = RemoteAX.available ? RemoteAX.windows(pid: pid, wanted: Set(cands.map { $0.0 })) : [:]

            for (i, (wid, w)) in cands.enumerated() {
                let el = confirmed[wid]
                if RemoteAX.available {
                    guard let el else { continue }
                    let sub = AX.string(el, kAXSubroleAttribute)
                    guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { continue }
                }
                let axTitle = el.flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
                let cgTitle = canReadTitles ? (w[kCGWindowName as String] as? String ?? "") : ""
                let raw = axTitle.isEmpty ? cgTitle : axTitle
                let minimized = el.flatMap { AX.bool($0, kAXMinimizedAttribute) } ?? false
                let isPrivate = s.maskPrivateWindows && s.isPrivateTitle(raw)
                let title: String
                if isExcluded { title = "\(name) (hidden)" }
                else if isPrivate { title = "Private window" }
                else if !s.showTitles || raw.isEmpty { title = name }
                else { title = raw }

                var rank = mru.windowRank(wid) ?? (20_000 + mru.appRank(pid) * 100 + i)
                if minimized { rank += 1_000_000 }
                var item = SwitchItem(app: app, axWindow: el, windowID: wid, title: title, appName: name,
                                      isMinimized: minimized, isAppHidden: app.isHidden,
                                      isSensitive: isExcluded || isPrivate)
                item.isOtherSpace = true
                item.captureBlocked = canReadTitles && (w[kCGWindowSharingState as String] as? Int) == 0
                item.rank = rank
                out.append((rank, item))
            }
        }
        return out
    }
}

/// Precise focus: brings forward one exact window, even on another Space, the way the Dock does.
/// Uses the same private window-server calls as AltTab and yabai. Loaded at runtime, so if a future
/// macOS removes them Zuvi Tab falls back to the public Accessibility route instead of crashing.
enum SkyFocus {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let setFront: SetFront? = sym(sky, "_SLPSSetFrontProcessWithOptions")
    private static let post: PostRecord? = sym(sky, "SLPSPostEventRecordTo")
    private static let getPSN: GetPSN? = sym(appServices, "GetProcessForPID")

    static func focus(pid: pid_t, wid: CGWindowID) -> Bool {
        guard let setFront, let post, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        guard setFront(&psn, wid, 0x200) == .success else { return false }   // 0x200 = user generated
        // Make it the key window of its app (event record layout as used by yabai / AltTab).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { for (k, b) in $0.enumerated() { bytes[0x3c + k] = b } }
        for k in 0x20..<0x30 { bytes[k] = 0xff }
        bytes[0x08] = 0x01; _ = post(&psn, &bytes)
        bytes[0x08] = 0x02; _ = post(&psn, &bytes)
        return true
    }
}

enum Focuser {
    /// Brings a window forward for a peek: same as switching, but not recorded as used and never moves it.
    static func reveal(_ item: SwitchItem, mru: MRUTracker) { focus(item, mru: mru, isPeek: true) }

    static func focus(_ item: SwitchItem, mru: MRUTracker, isPeek: Bool = false) {
        let app = item.app
        if app.isHidden { app.unhide() }
        if let w = item.axWindow, item.isMinimized {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        var movedHere = false
        if !isPeek, item.isOtherSpace, Settings.shared.bringToCurrentSpace, let wid = item.windowID {
            movedHere = Spaces.moveToCurrentSpace(wid)
        }

        var precise = false
        if let wid = item.windowID { precise = SkyFocus.focus(pid: item.pid, wid: wid) }

        if let w = item.axWindow {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }

        if !precise {
            // Public fallback: activate the app, then raise the window once AX can reach it.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(item.pid),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [])
            if item.isOtherSpace, !movedHere, let wid = item.windowID { raiseAfterSpaceSwitch(pid: item.pid, wid: wid, attempt: 0) }
        }
        if let w = item.axWindow {
            // Some apps re-order windows on activation; raise once more after it settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
        }
        guard !isPeek else { return }
        if let id = item.windowID { mru.bumpWindow(id) }
        mru.bumpApp(item.pid)
    }

    /// The Space-switch animation takes a moment; poll briefly until the window is reachable, then raise it.
    private static func raiseAfterSpaceSwitch(pid: pid_t, wid: CGWindowID, attempt: Int) {
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            if let w = AX.elements(ax, kAXWindowsAttribute).first(where: { AX.windowID($0) == wid }) {
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            } else {
                raiseAfterSpaceSwitch(pid: pid, wid: wid, attempt: attempt + 1)
            }
        }
    }
}
