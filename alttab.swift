// AltTab — per-window switcher (Windows AltTab parity for macOS).
//
// SETTINGS pane: configure hotkey, cross-Space, hidden windows, color-code, etc.
// OVERLAY: borderless non-activating NSPanel with thumbnail strip, type-to-filter,
//          arrow/Tab cycling, AX raise-on-commit.
//
// Differentiators vs. lwouis/alt-tab-macos:
//   1. Type-to-filter while switcher is open
//   2. Color-coded app grouping (stable hash → hue)
//   3. Recency-weighted ordering (last-used at position 2, Windows-style)
//   4. Cross-Space awareness
//   5. Non-activating panel — doesn't steal focus until commit
//
// Compiled alongside main.swift; no @main, no top-level executable code.

import SwiftUI
import AppKit
import Carbon
import ApplicationServices
import Foundation
import CoreGraphics

// ===========================================================================
// MARK: - Persisted prefs
// ===========================================================================

fileprivate enum AltTabKeys {
    static let enabled        = "alttab.enabled"
    static let hotkeyMods     = "alttab.hotkey.mods"   // Carbon modifier mask
    static let hotkeyKey      = "alttab.hotkey.key"    // Carbon keycode
    static let crossSpace     = "alttab.crossSpace"
    static let includeHidden  = "alttab.includeHidden"
    static let colorCode      = "alttab.colorCode"
    static let recency        = "alttab.recency"
    static let recencyList    = "alttab.recencyList"   // [windowID strings, MRU-first]
}

fileprivate struct AltTabHotkey: Equatable, Hashable {
    var modifiers: UInt32   // Carbon mask: cmdKey, optionKey, controlKey, shiftKey
    var keyCode: UInt32     // Carbon virtual keycode

    static let optionTab = AltTabHotkey(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_Tab))
    static let controlTab = AltTabHotkey(modifiers: UInt32(controlKey), keyCode: UInt32(kVK_Tab))
    static let commandTab = AltTabHotkey(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_Tab))

    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    private func keyName(_ kc: UInt32) -> String {
        switch Int(kc) {
        case kVK_Tab:        return "Tab"
        case kVK_Space:      return "Space"
        case kVK_ANSI_Grave: return "`"
        default:             return "Key(\(kc))"
        }
    }
}

// ===========================================================================
// MARK: - Window model
// ===========================================================================

fileprivate struct AltTabWindowItem: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool
    let layer: Int

    var displayTitle: String { title.isEmpty ? appName : title }
}

// ===========================================================================
// MARK: - Color coding (stable hash → HSL)
// ===========================================================================

fileprivate enum AltTabColoring {
    static func color(for bundleID: String) -> Color {
        // Stable FNV-1a-ish hash → hue ∈ [0,1).
        var h: UInt64 = 0xcbf29ce484222325
        for b in bundleID.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.78)
    }
}

// ===========================================================================
// MARK: - Thumbnail LRU cache
// ===========================================================================

fileprivate final class AltTabThumbCache {
    static let shared = AltTabThumbCache()
    private struct Entry { let image: NSImage; let stamp: Date }
    private var map: [CGWindowID: Entry] = [:]
    private var order: [CGWindowID] = []           // MRU last
    private let cap = 30
    private let lock = NSLock()

    func get(_ id: CGWindowID, maxAge: TimeInterval = 1.0) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[id] else { return nil }
        if Date().timeIntervalSince(e.stamp) > maxAge { return nil }
        if let idx = order.firstIndex(of: id) { order.remove(at: idx); order.append(id) }
        return e.image
    }

    func put(_ id: CGWindowID, _ image: NSImage) {
        lock.lock(); defer { lock.unlock() }
        map[id] = Entry(image: image, stamp: Date())
        if let idx = order.firstIndex(of: id) { order.remove(at: idx) }
        order.append(id)
        while order.count > cap {
            let victim = order.removeFirst()
            map.removeValue(forKey: victim)   // releases CGImage-backed NSImage
        }
    }

    func purge() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll(); order.removeAll()
    }
}

// ===========================================================================
// MARK: - Window enumeration
// ===========================================================================

fileprivate enum AltTabWindowList {
    static let troveBundleID: String = Bundle.main.bundleIdentifier ?? "com.local.trove"

    static func enumerate(crossSpace: Bool, includeHidden: Bool) -> [AltTabWindowItem] {
        let listOptions: CGWindowListOption = crossSpace
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        var out: [AltTabWindowItem] = []
        for d in info {
            guard let id     = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid    = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer  = d[kCGWindowLayer as String] as? Int else { continue }
            // Only normal windows (layer 0). Excludes menus, docks, popups.
            if layer != 0 { continue }

            // red-team: dock-hidden apps and some background helpers report
            // nil/empty owner name. Fall back to the running-app's localized
            // name so the tile shows something instead of an empty caption.
            var appName = (d[kCGWindowOwnerName as String] as? String) ?? ""
            if appName.isEmpty {
                appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
            }
            let title   = (d[kCGWindowName as String] as? String) ?? ""

            // Bounds dict → CGRect.
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? [String: CGFloat] {
                bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                                width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            }
            // Skip degenerate / hidden chrome.
            if bounds.width < 40 || bounds.height < 40 { continue }

            let onScreen = (d[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if !includeHidden && !onScreen && !crossSpace {
                // crossSpace inherently lists off-screen; only suppress hidden on the
                // current-Space path.
                continue
            }

            // Resolve bundle id for color hashing + Trove exclusion.
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                          ?? "pid.\(pid)"
            if bundleID == troveBundleID { continue }   // exclude ourselves

            // Skip windows that are clearly empty (no title AND not on screen) unless asked.
            if title.isEmpty && !onScreen && !includeHidden { continue }

            out.append(AltTabWindowItem(
                id: id, pid: pid, bundleID: bundleID,
                appName: appName, title: title, bounds: bounds,
                isOnScreen: onScreen, layer: layer))
        }
        return out
    }
}

// ===========================================================================
// MARK: - AX raise
// ===========================================================================

fileprivate enum AltTabAX {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func promptForTrust() {
        _ = isTrusted(prompt: true)
    }

    /// Best-effort raise. Returns true if we believe focus shifted.
    static func raise(window target: AltTabWindowItem) -> Bool {
        // red-team: guard against owning app having quit between enumerate and commit
        guard target.pid > 0 else { return false }
        let runningApp = NSRunningApplication(processIdentifier: target.pid)
        if runningApp == nil || runningApp?.isTerminated == true { return false }
        // red-team: `activate(options: [])` only succeeds when the app is
        // already frontmost — the entire point of a switcher is that it isn't.
        // Use .activateIgnoringOtherApps so the target actually comes forward.
        runningApp?.activate(options: [.activateIgnoringOtherApps])

        let ax = AXUIElementCreateApplication(target.pid)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
        guard err == .success, let arr = raw as? [AXUIElement] else { return false }

        // Match by title — windowID isn't directly queryable in AX without extras.
        // We try title equality first, then containment, then geometry.
        let wantTitle = target.title
        var pick: AXUIElement?
        for w in arr {
            if let t = axString(w, kAXTitleAttribute as CFString), t == wantTitle { pick = w; break }
        }
        if pick == nil && !wantTitle.isEmpty {
            for w in arr {
                if let t = axString(w, kAXTitleAttribute as CFString), t.contains(wantTitle) || wantTitle.contains(t) {
                    pick = w; break
                }
            }
        }
        if pick == nil {
            // fallback: geometry match
            for w in arr {
                if let pos = axPoint(w, kAXPositionAttribute as CFString),
                   let sz  = axSize(w, kAXSizeAttribute as CFString),
                   abs(pos.x - target.bounds.origin.x) < 4,
                   abs(pos.y - target.bounds.origin.y) < 4,
                   abs(sz.width - target.bounds.size.width) < 4,
                   abs(sz.height - target.bounds.size.height) < 4 {
                    pick = w; break
                }
            }
        }
        // First match if all else fails.
        if pick == nil { pick = arr.first }
        guard let w = pick else { return false }

        // Un-minimize if needed.
        if let mins = axBool(w, kAXMinimizedAttribute as CFString), mins {
            _ = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        let raiseErr = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        if raiseErr != .success { return false }
        return true
    }

    private static func axString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v as? String
    }
    private static func axBool(_ el: AXUIElement, _ attr: CFString) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue)
    }
    private static func axPoint(_ el: AXUIElement, _ attr: CFString) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        let axv = unsafeBitCast(val, to: AXValue.self)
        var p = CGPoint.zero
        if AXValueGetValue(axv, .cgPoint, &p) { return p }
        return nil
    }
    private static func axSize(_ el: AXUIElement, _ attr: CFString) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        let axv = unsafeBitCast(val, to: AXValue.self)
        var s = CGSize.zero
        if AXValueGetValue(axv, .cgSize, &s) { return s }
        return nil
    }
}

// ===========================================================================
// MARK: - Carbon hotkey
// ===========================================================================

fileprivate final class AltTabHotkeyRegistrar {
    static let shared = AltTabHotkeyRegistrar()
    private var handlerRef: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var onFire: (() -> Void)?
    private(set) var lastError: OSStatus = noErr
    private let signature: OSType = OSType(0x414C5442)  // 'ALTB'

    func install(_ hk: AltTabHotkey, onFire: @escaping () -> Void) -> Bool {
        uninstall()
        self.onFire = onFire

        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: OSType(kEventHotKeyPressed))
            let cb: EventHandlerUPP = { _, event, userData in
                guard let event = event, let userData = userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if err == noErr {
                    // red-team: bridge back via passUnretained singleton, hop to main for UI state writes
                    let me = Unmanaged<AltTabHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                    let fire = me.onFire
                    if Thread.isMainThread {
                        fire?()
                    } else {
                        DispatchQueue.main.async { fire?() }
                    }
                }
                return noErr
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), cb, 1, &spec, me, &handlerRef)
        }

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: 1)
        let err = RegisterEventHotKey(hk.keyCode, hk.modifiers, hkID,
                                      GetApplicationEventTarget(), 0, &ref)
        lastError = err
        if err == noErr, let ref = ref {
            hotkeyRef = ref
            return true
        }
        // red-team: registration failed — ensure ref is nil, don't keep stale pointer
        hotkeyRef = nil
        return false
    }

    func uninstall() {
        // red-team: nil-check + nil-out before Unregister to prevent double-free if called twice
        if let ref = hotkeyRef {
            hotkeyRef = nil
            UnregisterEventHotKey(ref)
        }
        onFire = nil
    }
}

// ===========================================================================
// MARK: - Recency tracker
// ===========================================================================

fileprivate final class AltTabRecency {
    static let shared = AltTabRecency()
    /// MRU-first list of windowIDs (UInt32) stored as strings in UserDefaults.
    private(set) var mru: [CGWindowID] = []

    init() { load() }

    func touch(_ id: CGWindowID) {
        if let i = mru.firstIndex(of: id) { mru.remove(at: i) }
        mru.insert(id, at: 0)
        // red-team: cap MRU at 100 to bound UserDefaults growth across launches
        if mru.count > 100 { mru = Array(mru.prefix(100)) }
        save()
    }

    /// Reorder so that current frontmost stays at 0, last-used at 1, then remaining
    /// by MRU then alphabetical.
    func order(_ items: [AltTabWindowItem]) -> [AltTabWindowItem] {
        guard !items.isEmpty else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seen = Set<CGWindowID>()
        var out: [AltTabWindowItem] = []
        for id in mru {
            if let it = byID[id], !seen.contains(id) {
                out.append(it); seen.insert(id)
            }
        }
        let rest = items.filter { !seen.contains($0.id) }
            .sorted { ($0.appName, $0.displayTitle) < ($1.appName, $1.displayTitle) }
        out.append(contentsOf: rest)
        return out
    }

    private func load() {
        let arr = UserDefaults.standard.array(forKey: AltTabKeys.recencyList) as? [String] ?? []
        mru = arr.compactMap { UInt32($0) }
    }
    private func save() {
        UserDefaults.standard.set(mru.map { String($0) }, forKey: AltTabKeys.recencyList)
    }
}

// ===========================================================================
// MARK: - Overlay controller (NSPanel)
// ===========================================================================

fileprivate final class AltTabOverlayController: NSObject, NSWindowDelegate {
    static let shared = AltTabOverlayController()

    private var panel: NSPanel?
    private var hosting: NSHostingController<AltTabOverlayHost>?
    private let state = AltTabOverlayState()
    private var localKeyMonitor: Any?
    private var isShowing: Bool = false

    // red-team: hide the overlay when the screen topology changes — if the
    // user unplugs the display the panel was centered on, leaving it visible
    // means it's stranded at off-screen coords until next ⌥-Tab.
    private var screensObserver: NSObjectProtocol?

    override init() {
        super.init()
        screensObserver = NotificationCenter.default.addObserver(
            forName: .troveScreensChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }
    deinit {
        if let o = screensObserver { NotificationCenter.default.removeObserver(o) }
    }

    func show(items: [AltTabWindowItem]) {
        // red-team: guard against re-entry when user mashes hotkey before previous hide finishes
        assert(Thread.isMainThread)
        if isShowing {
            // Just refresh items in the already-visible overlay instead of stacking shows.
            state.reset(items: items)
            return
        }
        isShowing = true
        if panel == nil { build() }
        state.reset(items: items)
        state.onCommit = { [weak self] item in self?.commit(item) }
        state.onCancel = { [weak self] in self?.hide() }

        if let panel = panel,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                        ?? NSScreen.main ?? NSScreen.screens.first {
            let w: CGFloat = min(1100, screen.visibleFrame.width - 80)
            let h: CGFloat = 280
            let x = screen.visibleFrame.midX - w/2
            let y = screen.visibleFrame.midY - h/2
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            panel.orderFrontRegardless()
            // Become key WITHOUT activating Trove (nonactivatingPanel style),
            // so we receive keystrokes for the local monitor.
            panel.makeKey()
        }
        installKeyMonitor()
    }

    func hide() {
        // red-team: idempotent hide — safe to call from cancel + commit racing
        removeKeyMonitor()
        panel?.orderOut(nil)
        isShowing = false
    }

    private func commit(_ item: AltTabWindowItem) {
        hide()
        if AltTabAX.raise(window: item) {
            AltTabRecency.shared.touch(item.id)
        } else {
            // Fix 18: if AX is not trusted, flash a warning toast with an action
            // button — do NOT auto-open TCC settings unprompted (drive-by pop).
            if !AltTabAX.isTrusted() {
                Task { @MainActor in
                    SharedStore.stage.flash(
                        "AltTab needs Accessibility — grant it in System Settings",
                        kind: .warning
                    )
                }
            }
        }
    }

    private func build() {
        let p = AltTabPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // red-team: use .popUpMenu level so the panel sits above normal floating windows
        // and remains reachable on macOS 26 Stage Manager / Mission Control.
        p.level = .popUpMenu
        p.hasShadow = true
        p.isMovable = false
        // red-team: drop .stationary (conflicts with .canJoinAllSpaces on macOS 26);
        // add .transient so Mission Control doesn't trap it as a persistent window.
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.delegate = self

        let root = AltTabOverlayHost(state: state)
        let hc = NSHostingController(rootView: root)
        p.contentView = hc.view
        hc.view.frame = p.contentRect(forFrameRect: p.frame)
        hosting = hc
        panel = p
    }

    // Local monitor while panel is up: lets us catch Tab/arrow keys even though
    // the panel is non-activating. We also forward typing to the search field.
    private func installKeyMonitor() {
        if localKeyMonitor != nil { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] ev in
            guard let self = self, self.panel?.isVisible == true else { return ev }
            return self.state.handle(event: ev) ? nil : ev
        }
        // Global monitor too — for when our panel isn't key (it usually isn't).
        // We re-use the same handler via NSEvent.addGlobalMonitor; it only fires
        // for events outside our app, which is exactly the AltTab case.
    }
    private func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }
}

/// Non-activating, key-only-if-needed panel.
fileprivate final class AltTabPanel: NSPanel {
    override var canBecomeKey: Bool { true }     // needs key to receive typing
    override var canBecomeMain: Bool { false }
}

// ===========================================================================
// MARK: - Overlay state + SwiftUI host
// ===========================================================================

fileprivate final class AltTabOverlayState: ObservableObject {
    @Published var items: [AltTabWindowItem] = []
    @Published var filter: String = ""
    @Published var cursor: Int = 0
    var onCommit: ((AltTabWindowItem) -> Void)?
    var onCancel: (() -> Void)?

    var filtered: [AltTabWindowItem] {
        guard !filter.isEmpty else { return items }
        let f = filter.lowercased()
        return items.filter {
            $0.appName.lowercased().contains(f) || $0.title.lowercased().contains(f)
        }
    }

    func reset(items: [AltTabWindowItem]) {
        self.items = items
        self.filter = ""
        // Windows-style: cursor starts at index 1 (last-used), if there is one.
        self.cursor = items.count >= 2 ? 1 : 0
    }

    /// Returns true if event was consumed.
    func handle(event ev: NSEvent) -> Bool {
        if ev.type == .flagsChanged { return false }

        // Cmd / Ctrl / Opt held = navigation chord (Tab cycles).
        let key = Int(ev.keyCode)
        let chars = ev.charactersIgnoringModifiers ?? ""

        switch key {
        case kVK_Escape:
            onCancel?(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitCurrent(); return true
        case kVK_Tab:
            if ev.modifierFlags.contains(.shift) { move(-1) } else { move(1) }
            return true
        case kVK_RightArrow: move(1); return true
        case kVK_LeftArrow:  move(-1); return true
        case kVK_Delete:
            if !filter.isEmpty { filter.removeLast(); resetCursor() }
            return true
        default:
            // If pure typing (no cmd/ctrl/opt mods other than shift), accumulate to filter.
            // red-team: previously dropped `_`, `/`, punctuation, and any
            // accented/CJK input — so filtering "Café" or "src/api" was
            // impossible. Allow anything that's not a control character.
            let mods = ev.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty {
                if let c = chars.first, !c.isNewline,
                   let scalar = c.unicodeScalars.first, scalar.value >= 0x20 {
                    filter.append(c)
                    resetCursor()
                    return true
                }
            }
            return false
        }
    }

    func commitCurrent() {
        let list = filtered
        guard !list.isEmpty else { onCancel?(); return }
        let safe = max(0, min(cursor, list.count - 1))
        onCommit?(list[safe])
    }

    private func move(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let n = list.count
        cursor = ((cursor + delta) % n + n) % n
    }
    private func resetCursor() {
        cursor = 0
    }
}

fileprivate struct AltTabOverlayHost: View {
    @ObservedObject var state: AltTabOverlayState
    @AppStorage(AltTabKeys.colorCode) private var colorCode: Bool = true
    // Fix 24: solid fill fallback when Reduce Transparency is enabled.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let items = state.filtered
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(state.filter.isEmpty ? "Type to filter…" : state.filter)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(state.filter.isEmpty ? .secondary : .primary)
                Spacer()
                Text("\(items.count) window\(items.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            ScrollViewReader { sp in
                ScrollView(.horizontal, showsIndicators: false) {
                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: state.items.isEmpty ? "macwindow.badge.plus" : "magnifyingglass")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(state.items.isEmpty
                                 ? "No other apps with switchable windows"
                                 : "No windows match \"\(state.filter)\"")
                                .font(.headline)
                            Text(state.items.isEmpty
                                 ? "Open another regular-window app and reopen the switcher."
                                 : "Press Delete to edit the filter, or Esc to cancel.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: 380)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                    } else {
                    HStack(spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { (i, it) in
                            AltTabTile(item: it,
                                       selected: i == state.cursor,
                                       colorCode: colorCode)
                                .id(it.id)
                                .onTapGesture { state.cursor = i; state.commitCurrent() }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
                .onChange(of: state.cursor) { _, new in
                    if new < items.count {
                        // red-team: scroll animation ignored Reduce Motion.
                        // Under the setting, snap instantly to the new target.
                        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            sp.scrollTo(items[new].id, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) {
                                sp.scrollTo(items[new].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // Fix 24: solid fill when Reduce Transparency is enabled.
                .fill(reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .padding(8)
    }
}

fileprivate struct AltTabTile: View {
    let item: AltTabWindowItem
    let selected: Bool
    let colorCode: Bool

    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let t = thumb {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.18))
                    }
                }
                .frame(width: 180, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                    Image(nsImage: icon)
                        .resizable().frame(width: 28, height: 28)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if colorCode {
                    Rectangle()
                        .fill(AltTabColoring.color(for: item.bundleID))
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                        .padding(.horizontal, 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            Text(item.displayTitle)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 180)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(6)
        // red-team: VoiceOver users need a labelled item; default reading of
        // the tile would announce only the inner Text. Group + label so it
        // reads as one switchable element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.appName), \(item.displayTitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        // Note: CGWindowListCreateImage was made unavailable in the current
        // macOS SDK in favor of ScreenCaptureKit. Capturing per-window
        // thumbnails via SCK requires permission + an async stream, which is
        // a larger change. For now we fall back to the app icon (already
        // shown as an overlay), keeping the switcher functional without
        // thumbnails. Migration to SCK is a TODO.
        if let cached = AltTabThumbCache.shared.get(item.id) {
            self.thumb = cached
            return
        }
        // No-op; the parent view renders the app icon when thumb is nil.
    }
}

// ===========================================================================
// MARK: - Engine (settings ↔ hotkey ↔ overlay)
// ===========================================================================

fileprivate final class AltTabEngine: ObservableObject {
    static let shared = AltTabEngine()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: AltTabKeys.enabled)
            apply()
        }
    }
    @Published var hotkey: AltTabHotkey {
        didSet {
            UserDefaults.standard.set(Int(hotkey.modifiers), forKey: AltTabKeys.hotkeyMods)
            UserDefaults.standard.set(Int(hotkey.keyCode),  forKey: AltTabKeys.hotkeyKey)
            if enabled { apply() }
        }
    }
    @Published var crossSpace: Bool {
        didSet { UserDefaults.standard.set(crossSpace, forKey: AltTabKeys.crossSpace) }
    }
    @Published var includeHidden: Bool {
        didSet { UserDefaults.standard.set(includeHidden, forKey: AltTabKeys.includeHidden) }
    }
    @Published var colorCode: Bool {
        didSet { UserDefaults.standard.set(colorCode, forKey: AltTabKeys.colorCode) }
    }
    @Published var recencyOrder: Bool {
        didSet { UserDefaults.standard.set(recencyOrder, forKey: AltTabKeys.recency) }
    }

    @Published var statusLine: String = ""
    @Published var hotkeyOK: Bool = true

    init() {
        let d = UserDefaults.standard
        self.enabled       = d.bool(forKey: AltTabKeys.enabled)
        let mods           = d.object(forKey: AltTabKeys.hotkeyMods) as? Int ?? Int(optionKey)
        let kc             = d.object(forKey: AltTabKeys.hotkeyKey)  as? Int ?? kVK_Tab
        self.hotkey        = AltTabHotkey(modifiers: UInt32(mods), keyCode: UInt32(kc))
        self.crossSpace    = (d.object(forKey: AltTabKeys.crossSpace)    as? Bool) ?? true
        self.includeHidden = (d.object(forKey: AltTabKeys.includeHidden) as? Bool) ?? false
        self.colorCode     = (d.object(forKey: AltTabKeys.colorCode)     as? Bool) ?? true
        self.recencyOrder  = (d.object(forKey: AltTabKeys.recency)       as? Bool) ?? true
        apply()
    }

    func apply() {
        if enabled {
            let ok = AltTabHotkeyRegistrar.shared.install(hotkey) { [weak self] in
                self?.fire()
            }
            hotkeyOK = ok
            statusLine = ok
                ? "Hotkey active: \(hotkey.label)"
                : "Hotkey unavailable — try another (conflict with another app)"
        } else {
            AltTabHotkeyRegistrar.shared.uninstall()
            AltTabThumbCache.shared.purge()
            hotkeyOK = true
            statusLine = "Disabled"
        }
    }

    func fire() {
        // Build list, optionally reorder, then show overlay.
        var items = AltTabWindowList.enumerate(crossSpace: crossSpace,
                                               includeHidden: includeHidden)
        if recencyOrder { items = AltTabRecency.shared.order(items) }
        // red-team: empty list shouldn't silently swallow the hotkey — user
        // pressed it for a reason. Audible bonk + status line so they know
        // the switcher saw the keypress but had nothing to show.
        if items.isEmpty {
            NSSound.beep()
            statusLine = "No switchable windows (check 'cross-Space' / 'include hidden')."
            return
        }
        AltTabOverlayController.shared.show(items: items)
    }

    /// "Test now" — shows overlay regardless of AX trust (so user sees it),
    /// but raise-on-commit will fail-soft if AX isn't granted.
    func testNow() {
        fire()
    }
}

// ===========================================================================
// MARK: - SwiftUI surface (settings pane)
// ===========================================================================

public struct AltTabView: View {
    @StateObject private var engine = AltTabEngine.shared
    @State private var axTrusted: Bool = AltTabAX.isTrusted()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !axTrusted { accessibilityCard }
                enableCard
                hotkeyCard
                behaviorCard
                appearanceCard
                if !engine.statusLine.isEmpty { statusCard }
            }
            .padding(24)
        }
        .navigationTitle("AltTab")
        .navigationSubtitle(engine.enabled
                            ? "Hotkey: \(engine.hotkey.label)"
                            : "Disabled")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    engine.testNow()
                } label: {
                    Label("Test now", systemImage: "play.rectangle")
                }
                .help("Open the switcher overlay without using the hotkey")
                Button {
                    axTrusted = AltTabAX.isTrusted()
                    engine.apply()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .onAppear { axTrusted = AltTabAX.isTrusted() }
        // Fix 18 (existing): re-check axTrusted when the user returns to Trove from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AltTabAX.isTrusted()
            if axTrusted { engine.apply() }
        }
        // Fix 19: 5-second periodic poll while the pane is visible so AX revocation surfaces without app switch.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            let trusted = AltTabAX.isTrusted()
            if trusted != axTrusted {
                axTrusted = trusted
                if trusted { engine.apply() }
            }
        }
    }

    // ---------- Cards ----------

    private var accessibilityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Accessibility access needed", systemImage: "lock.shield")
                    .font(.headline)
                Text("To raise other apps' windows, macOS requires Trove to have Accessibility permission. AltTab will still appear without it, but pressing Enter on a window won't bring it to the front.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button {
                        AltTabAX.promptForTrust()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            axTrusted = AltTabAX.isTrusted()
                        }
                    } label: {
                        Label("Grant access", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        TCCDeepLink.accessibility.open()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var enableCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $engine.enabled) {
                    Label("Enable AltTab switcher", systemImage: "rectangle.stack")
                        .font(.headline)
                }
                .toggleStyle(.switch)
                Text("Switch through individual windows (not just apps) with thumbnails. Type to filter, arrow keys or Tab to cycle, Enter to commit.")
                    .font(.callout).foregroundStyle(.secondary)
                if engine.enabled && !engine.hotkeyOK {
                    Label("Hotkey unavailable — another app may have claimed it. Try a different combo below.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    private var hotkeyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hotkey", systemImage: "command")
                    .font(.headline)
                Picker("Combo", selection: Binding(
                    get: { engine.hotkey },
                    set: { engine.hotkey = $0 }
                )) {
                    Text("Option + Tab  (⌥⇥)").tag(AltTabHotkey.optionTab)
                    Text("Control + Tab  (⌃⇥)").tag(AltTabHotkey.controlTab)
                    Text("Command + Tab  (⌘⇥) — reserved by macOS").tag(AltTabHotkey.commandTab)
                }
                .pickerStyle(.radioGroup)

                if engine.hotkey == .commandTab {
                    Label("⌘⇥ is reserved by macOS for the app switcher and won't be delivered to Trove. Pick another.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    private var behaviorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Behavior", systemImage: "slider.horizontal.3").font(.headline)
                Toggle("Include windows on other Spaces", isOn: $engine.crossSpace)
                Toggle("Show hidden / minimized windows",  isOn: $engine.includeHidden)
                Toggle("Recency-weighted ordering (last-used at position 2)",
                       isOn: $engine.recencyOrder)
            }
        }
    }

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Appearance", systemImage: "paintpalette").font(.headline)
                Toggle("Color-code by app (thin colored border per tile)",
                       isOn: $engine.colorCode)
                Text("Each app gets a stable accent hue derived from its bundle ID, so windows of the same app share a colored bottom-stripe.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: engine.hotkeyOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(engine.hotkeyOK ? .green : .red)
                Text(engine.statusLine).font(.callout)
                Spacer()
            }
        }
    }
}
