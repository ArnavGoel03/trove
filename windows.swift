// Trove — Window Snapping pane.
//
// Move/resize the frontmost macOS window with keyboard or a tile palette.
// Differentiators over Rectangle/Loop/Magnet/Swish:
//   • Smart presets: per-app-bundle suggestion table (Xcode → 65% left,
//     Terminal → 35% right, browsers paired with editors side-by-side).
//   • Multi-window "Layout": stamp 2–4 currently-open windows into halves
//     or thirds in one click — no per-window dragging.
//   • Animation is ≤120 ms ease-out and respects macOS Reduce Motion.
//
// Implementation rides on the Accessibility (AX) API: AXUIElement queries on
// the frontmost app give us the window, AXFrame/AXPosition/AXSize move it.
// This requires Accessibility permission. We never auto-prompt on appear —
// only when the user clicks the explicit "Grant access" button.

import SwiftUI
import AppKit
import ApplicationServices
import Foundation

// ===========================================================================
// MARK: - Geometry primitives
// ===========================================================================

/// A target frame expressed in fractions of the screen's visibleFrame.
/// Storing fractions (not points) means a preset survives display-rotation,
/// resolution changes, and snapping to a different display without rework.
struct WinSnapFraction: Hashable {
    var x: CGFloat   // 0…1
    var y: CGFloat   // 0…1 — top-down from visibleFrame.minY
    var w: CGFloat   // 0…1
    var h: CGFloat   // 0…1

    static let full        = WinSnapFraction(x: 0,     y: 0,     w: 1,     h: 1)
    static let leftHalf    = WinSnapFraction(x: 0,     y: 0,     w: 0.5,   h: 1)
    static let rightHalf   = WinSnapFraction(x: 0.5,   y: 0,     w: 0.5,   h: 1)
    static let topHalf     = WinSnapFraction(x: 0,     y: 0,     w: 1,     h: 0.5)
    static let bottomHalf  = WinSnapFraction(x: 0,     y: 0.5,   w: 1,     h: 0.5)
    static let topLeft     = WinSnapFraction(x: 0,     y: 0,     w: 0.5,   h: 0.5)
    static let topRight    = WinSnapFraction(x: 0.5,   y: 0,     w: 0.5,   h: 0.5)
    static let botLeft     = WinSnapFraction(x: 0,     y: 0.5,   w: 0.5,   h: 0.5)
    static let botRight    = WinSnapFraction(x: 0.5,   y: 0.5,   w: 0.5,   h: 0.5)
    static let leftThird   = WinSnapFraction(x: 0,         y: 0, w: 1.0/3, h: 1)
    static let middleThird = WinSnapFraction(x: 1.0/3,     y: 0, w: 1.0/3, h: 1)
    static let rightThird  = WinSnapFraction(x: 2.0/3,     y: 0, w: 1.0/3, h: 1)
    static let leftTwoThirds  = WinSnapFraction(x: 0,      y: 0, w: 2.0/3, h: 1)
    static let rightTwoThirds = WinSnapFraction(x: 1.0/3,  y: 0, w: 2.0/3, h: 1)
    static let leftSixty   = WinSnapFraction(x: 0,     y: 0,     w: 0.6,   h: 1)
    static let rightForty  = WinSnapFraction(x: 0.6,   y: 0,     w: 0.4,   h: 1)
    static let leftSixtyFive  = WinSnapFraction(x: 0,         y: 0, w: 0.65, h: 1)
    static let rightThirtyFive = WinSnapFraction(x: 0.65,     y: 0, w: 0.35, h: 1)
}

/// Convert a fraction to an AX-coordinate CGRect on a given display.
/// AX uses top-left-origin global coordinates, NOT NSScreen's bottom-left.
/// We translate using the primary screen's frame so multi-display works.
func winSnapAXRect(fraction f: WinSnapFraction, on screen: NSScreen) -> CGRect {
    let vf = screen.visibleFrame
    // Primary screen for AX origin translation. NSScreen.screens[0] is always
    // the screen with the menu bar, which AX treats as origin.
    let primary = NSScreen.screens.first?.frame ?? vf
    let axY = primary.maxY - vf.maxY + f.y * vf.height
    return CGRect(
        x: vf.minX + f.x * vf.width,
        y: axY,
        width: f.w * vf.width,
        height: f.h * vf.height
    )
}

// ===========================================================================
// MARK: - Accessibility bridge
// ===========================================================================

/// Errors surfaced from AX operations, mapped to one-line user messages.
enum WinSnapAXError: Error, CustomStringConvertible {
    case notTrusted
    case noFrontmostApp
    case noFocusedWindow
    case isFullScreen
    case isMinimized
    case refused(AXError)
    case displayUnavailable

    var description: String {
        switch self {
        case .notTrusted:         return "Accessibility access not granted."
        case .noFrontmostApp:     return "No frontmost app to target."
        case .noFocusedWindow:    return "Frontmost app has no focused window."
        case .isFullScreen:       return "Window is in fullscreen — exit fullscreen first."
        case .isMinimized:        return "Window is minimized — un-minimize first."
        case .refused(let e):     return "App refused resize (AX error \(e.rawValue))."
        case .displayUnavailable: return "Target display is offline."
        }
    }
}

enum WinSnapAX {

    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Prompts the OS to surface the standard "App wants accessibility" dialog.
    /// Called only on explicit user click — never on view appear.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns (app PID, bundle ID) of the frontmost non-Trove app, or nil.
    /// We deliberately skip our own process — snapping the Trove window from
    /// the Trove UI would be a confusing footgun.
    static func frontmostExternalApp() -> (pid_t, String?)? {
        let ws = NSWorkspace.shared
        guard let app = ws.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Trove is frontmost; look at the next app underneath.
            let others = ws.runningApplications.filter {
                $0.activationPolicy == .regular
                && $0.processIdentifier != app.processIdentifier
            }
            if let n = others.first { return (n.processIdentifier, n.bundleIdentifier) }
            return nil
        }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    static func axApp(for pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref)
        // Some buggy apps (older Electron builds) return junk for
        // AXFocusedWindow; `as?` returns nil and the caller falls back, which
        // is the only safe behavior — a force-cast would crash Trove.
        guard err == .success, let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(r, to: AXUIElement.self)
    }

    static func boolAttr(_ el: AXUIElement, _ name: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success,
              let b = ref as? Bool else { return false }
        return b
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posCF = posRef, let sizeCF = sizeRef
        else { return nil }
        // red-team: AX should hand back AXValue here, but a misbehaving app
        // can return something else and a force-cast would crash. Guard via
        // CFGetTypeID and bail to nil so the caller can fall back.
        guard CFGetTypeID(posCF) == AXValueGetTypeID(),
              CFGetTypeID(sizeCF) == AXValueGetTypeID() else { return nil }
        let posV = unsafeBitCast(posCF, to: AXValue.self)
        let sizeV = unsafeBitCast(sizeCF, to: AXValue.self)
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posV, .cgPoint, &pos),
              AXValueGetValue(sizeV, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Returns true iff the window will let us write position+size. AX exposes
    /// kAXSizeAttribute even on windows that can't actually be resized (Calculator,
    /// some Stage Manager-managed shells, mini-player windows). The settable
    /// query is the only reliable gate before we burn an animation on a no-op.
    static func canResize(_ window: AXUIElement) -> Bool {
        var posSettable: DarwinBoolean = false
        var sizeSettable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &posSettable)
        _ = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        return posSettable.boolValue && sizeSettable.boolValue
    }

    /// Apply a CGRect to the window. Sets position first then size — some apps
    /// clamp size against current screen, so re-applying position last gives
    /// the most predictable result.
    @discardableResult
    static func setFrame(_ window: AXUIElement, to rect: CGRect) -> AXError {
        var pos = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return .failure }
        let e1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let e2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let e3 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        // Surface the first failing code; apps like Calculator return
        // .cannotComplete or .attributeUnsupported on size sets.
        if e2 != .success { return e2 }
        if e1 != .success { return e1 }
        return e3
    }

    /// Find the NSScreen whose visibleFrame contains the largest area of `rect`
    /// (in NSScreen coords). AX rect comes in flipped-top-left; convert it.
    static func screenFor(axRect: CGRect) -> NSScreen? {
        let primary = NSScreen.screens.first?.frame ?? .zero
        // Convert AX rect → NSScreen rect.
        let nsRect = CGRect(
            x: axRect.minX,
            y: primary.maxY - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let inter = s.frame.intersection(nsRect)
            let a = inter.width * inter.height
            if a > bestArea { bestArea = a; best = s }
        }
        return best ?? NSScreen.main
    }

    /// Resolve the frontmost target. Returns the AX window plus a description
    /// of why it can't be moved, if any.
    static func resolveTarget() -> Result<(AXUIElement, NSScreen, String?), WinSnapAXError> {
        guard isTrusted() else { return .failure(.notTrusted) }
        guard let (pid, bid) = frontmostExternalApp() else { return .failure(.noFrontmostApp) }
        let app = axApp(for: pid)
        guard let win = focusedWindow(of: app) else { return .failure(.noFocusedWindow) }
        if boolAttr(win, "AXFullScreen") { return .failure(.isFullScreen) }
        if boolAttr(win, kAXMinimizedAttribute as String) { return .failure(.isMinimized) }
        // red-team: Stage Manager-stripped shells and some web-app wrappers
        // expose a focused "window" that's actually not resizable. Bail with
        // a refusal rather than animating into a no-op the user can't see.
        if !canResize(win) { return .failure(.refused(.attributeUnsupported)) }
        let frame = frame(of: win) ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        guard let screen = screenFor(axRect: frame) else { return .failure(.displayUnavailable) }
        return .success((win, screen, bid))
    }
}

// ===========================================================================
// MARK: - Smart presets (per-app suggestion table)
// ===========================================================================

struct WinSnapSuggestion {
    let label: String          // human description, e.g. "65% left"
    let fraction: WinSnapFraction
    let pairBundleID: String?  // optional second app to snap into the complementary slot
    let pairFraction: WinSnapFraction?
}

enum WinSnapSmart {
    /// Built-in suggestion table for ~12 common apps. The pairing column lets
    /// a browser snap 35% right with an editor (if open) taking 65% left.
    /// Bundle IDs here are the canonical macOS identifiers — keep them lowercase.
    static let table: [String: WinSnapSuggestion] = [
        "com.apple.dt.Xcode": .init(
            label: "65% left (more code, sidebar room)",
            fraction: .leftSixtyFive,
            pairBundleID: nil, pairFraction: nil),
        "com.microsoft.VSCode": .init(
            label: "65% left (editor wide, browser right)",
            fraction: .leftSixtyFive,
            pairBundleID: "com.apple.Safari", pairFraction: .rightThirtyFive),
        "com.todesktop.230313mzl4w4u92": .init(  // Cursor
            label: "65% left (editor wide)",
            fraction: .leftSixtyFive,
            pairBundleID: "com.apple.Safari", pairFraction: .rightThirtyFive),
        "com.apple.Terminal": .init(
            label: "35% right (logs on the side)",
            fraction: .rightThirtyFive,
            pairBundleID: nil, pairFraction: nil),
        "com.googlecode.iterm2": .init(
            label: "35% right (logs on the side)",
            fraction: .rightThirtyFive,
            pairBundleID: nil, pairFraction: nil),
        "com.mitchellh.ghostty": .init(
            label: "35% right",
            fraction: .rightThirtyFive,
            pairBundleID: nil, pairFraction: nil),
        "com.apple.Safari": .init(
            label: "35% right (pair with editor)",
            fraction: .rightThirtyFive,
            pairBundleID: "com.apple.dt.Xcode", pairFraction: .leftSixtyFive),
        "com.google.Chrome": .init(
            label: "Right half (browser + editor)",
            fraction: .rightHalf,
            pairBundleID: "com.microsoft.VSCode", pairFraction: .leftHalf),
        "company.thebrowser.Browser": .init(  // Arc
            label: "Right half (Arc + editor)",
            fraction: .rightHalf,
            pairBundleID: "com.microsoft.VSCode", pairFraction: .leftHalf),
        "com.tinyspeck.slackmacgap": .init(
            label: "Right third (chat on the side)",
            fraction: .rightThird,
            pairBundleID: nil, pairFraction: nil),
        "com.hnc.Discord": .init(
            label: "Right third (chat on the side)",
            fraction: .rightThird,
            pairBundleID: nil, pairFraction: nil),
        "com.apple.Notes": .init(
            label: "Left third (reference column)",
            fraction: .leftThird,
            pairBundleID: nil, pairFraction: nil),
        "com.apple.mail": .init(
            label: "Right half",
            fraction: .rightHalf,
            pairBundleID: nil, pairFraction: nil),
    ]

    static func suggestion(forBundleID bid: String?) -> WinSnapSuggestion? {
        guard let bid = bid else { return nil }
        return table[bid]
    }
}

// ===========================================================================
// MARK: - Tile catalogue (palette grid)
// ===========================================================================

struct WinSnapTile: Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String
    let fraction: WinSnapFraction
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers

    static func == (a: WinSnapTile, b: WinSnapTile) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WinSnapPalette {
    /// Eleven tiles laid out in 3 rows: halves, quarters, thirds. These match
    /// the keyboard shortcuts we register in the SwiftUI command tree.
    static let tiles: [WinSnapTile] = [
        .init(id: "full",   label: "Full",        symbol: "rectangle.fill",
              fraction: .full,
              shortcut: .return, modifiers: [.command, .control]),
        .init(id: "lh",     label: "Left half",   symbol: "rectangle.lefthalf.fill",
              fraction: .leftHalf,
              shortcut: .leftArrow, modifiers: [.command, .control]),
        .init(id: "rh",     label: "Right half",  symbol: "rectangle.righthalf.fill",
              fraction: .rightHalf,
              shortcut: .rightArrow, modifiers: [.command, .control]),
        .init(id: "th",     label: "Top half",    symbol: "rectangle.tophalf.fill",
              fraction: .topHalf,
              shortcut: .upArrow, modifiers: [.command, .control]),
        .init(id: "bh",     label: "Bottom half", symbol: "rectangle.bottomhalf.fill",
              fraction: .bottomHalf,
              shortcut: .downArrow, modifiers: [.command, .control]),
        .init(id: "tl",     label: "Top-left",     symbol: "rectangle.inset.topleft.filled",
              fraction: .topLeft, shortcut: nil, modifiers: []),
        .init(id: "tr",     label: "Top-right",    symbol: "rectangle.inset.topright.filled",
              fraction: .topRight, shortcut: nil, modifiers: []),
        .init(id: "bl",     label: "Bot-left",     symbol: "rectangle.inset.bottomleft.filled",
              fraction: .botLeft, shortcut: nil, modifiers: []),
        .init(id: "br",     label: "Bot-right",    symbol: "rectangle.inset.bottomright.filled",
              fraction: .botRight, shortcut: nil, modifiers: []),
        .init(id: "l3",     label: "Left third",   symbol: "rectangle.split.3x1.fill",
              fraction: .leftThird,
              shortcut: KeyEquivalent("1"), modifiers: [.command, .control, .shift]),
        .init(id: "m3",     label: "Middle third", symbol: "rectangle.split.3x1",
              fraction: .middleThird,
              shortcut: KeyEquivalent("2"), modifiers: [.command, .control, .shift]),
        .init(id: "r3",     label: "Right third",  symbol: "rectangle.split.3x1.fill",
              fraction: .rightThird,
              shortcut: KeyEquivalent("3"), modifiers: [.command, .control, .shift]),
        .init(id: "l23",    label: "Left 2/3",     symbol: "rectangle.lefthalf.inset.filled",
              fraction: .leftTwoThirds,
              shortcut: KeyEquivalent("4"), modifiers: [.command, .control, .shift]),
        .init(id: "r23",    label: "Right 2/3",    symbol: "rectangle.righthalf.inset.filled",
              fraction: .rightTwoThirds,
              shortcut: KeyEquivalent("5"), modifiers: [.command, .control, .shift]),
    ]
}

// ===========================================================================
// MARK: - Window listing for the multi-window composer
// ===========================================================================

/// Lightweight handle to an open window we can re-target via AX.
struct WinSnapWindowHandle: Identifiable, Hashable {
    let id = UUID()
    let pid: pid_t
    let title: String
    let appName: String
    let bundleID: String?
    let index: Int  // order in the app's AXWindows array

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum WinSnapWindowList {
    /// Enumerate visible, non-minimized, non-fullscreen windows across regular
    /// running apps. Skips Trove itself and anything AX refuses to introspect.
    static func enumerate() -> [WinSnapWindowHandle] {
        guard WinSnapAX.isTrusted() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [WinSnapWindowHandle] = []
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != me {
            let pid = app.processIdentifier
            let axApp = WinSnapAX.axApp(for: pid)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement] else { continue }
            for (i, w) in wins.enumerated() {
                if WinSnapAX.boolAttr(w, kAXMinimizedAttribute as String) { continue }
                if WinSnapAX.boolAttr(w, "AXFullScreen") { continue }
                var titleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? "Untitled"
                if title.isEmpty && i > 0 { continue }  // skip the inevitable empty helper
                out.append(WinSnapWindowHandle(
                    pid: pid,
                    title: title,
                    appName: app.localizedName ?? "App",
                    bundleID: app.bundleIdentifier,
                    index: i
                ))
            }
        }
        return out
    }

    /// Resolve a handle back to a live AXUIElement. Returns nil if the window
    /// has since closed or the app exited.
    static func resolve(_ h: WinSnapWindowHandle) -> AXUIElement? {
        let axApp = WinSnapAX.axApp(for: h.pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement], h.index < wins.count else { return nil }
        return wins[h.index]
    }
}

// ===========================================================================
// MARK: - Snap engine (does the actual move, with optional animation)
// ===========================================================================

enum WinSnapEngine {

    /// Quick check that mirrors NSWorkspace's accessibility setting.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Apply a fraction to the frontmost window. Returns a user-facing status.
    @MainActor
    static func applyToFrontmost(_ f: WinSnapFraction) async -> String {
        switch WinSnapAX.resolveTarget() {
        case .failure(let err):
            return err.description
        case .success(let (win, screen, _)):
            let target = winSnapAXRect(fraction: f, on: screen)
            return await apply(window: win, to: target, screen: screen)
        }
    }

    /// Apply to a specific (handle, fraction) pair — used by the multi-window
    /// "Layout" stamp. Returns a per-window status line.
    @MainActor
    static func applyToHandle(_ h: WinSnapWindowHandle, _ f: WinSnapFraction) async -> String {
        guard WinSnapAX.isTrusted() else { return "\(h.title): no AX access" }
        guard let win = WinSnapWindowList.resolve(h) else { return "\(h.title): window gone" }
        if WinSnapAX.boolAttr(win, "AXFullScreen") {
            return "\(h.title): fullscreen — skipped"
        }
        // red-team: a window enumerated a few hundred ms ago can be minimized
        // by the user mid-layout. Skip rather than yanking it back open.
        if WinSnapAX.boolAttr(win, kAXMinimizedAttribute as String) {
            return "\(h.title): minimized — skipped"
        }
        // red-team: Stage Manager / unresizable shells — bail before animating.
        if !WinSnapAX.canResize(win) {
            return "\(h.title): refused (not resizable)"
        }
        let frame = WinSnapAX.frame(of: win) ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        // red-team: NSScreen.main can be nil on a headless box (Mac mini with
        // no monitor, or all displays asleep). Force-unwrap would crash. Fall
        // back to any first screen, and if even that's empty, surface a status.
        guard let screen = WinSnapAX.screenFor(axRect: frame) ?? NSScreen.screens.first else {
            return "\(h.title): no display available"
        }
        let target = winSnapAXRect(fraction: f, on: screen)
        return await apply(window: win, to: target, screen: screen, label: h.title)
    }

    /// The shared rect-applier. Animates if the user hasn't requested reduce-
    /// motion; otherwise jumps instantly. Animation interpolates pos+size
    /// over 6 frames @ ~120ms (≈50 fps target — generous on 60 Hz, fine on 120 Hz).
    @MainActor
    private static func apply(window: AXUIElement, to target: CGRect, screen: NSScreen, label: String? = nil) async -> String {
        let start = WinSnapAX.frame(of: window) ?? target
        let displayName = label ?? "Window"
        if reduceMotion {
            let err = WinSnapAX.setFrame(window, to: target)
            if err != .success { return "\(displayName): refused (AX \(err.rawValue))" }
            return "\(displayName): snapped"
        }
        // 6-step ease-out interpolation. Total ≤120 ms.
        // red-team: previously this used Thread.sleep on the @MainActor, which
        // froze the run loop for the full animation — menu-bar interactions,
        // SwiftUI redraws, and other shortcut presses all paused for ~120 ms.
        // Switched to Task.sleep (cooperative) so the main run loop keeps
        // pumping in default + event-tracking modes.
        let steps = 6
        let totalMs: Double = 110
        let stepMs = totalMs / Double(steps)
        // Capture the target display's identity so we can detect mid-animation
        // disconnects and bail rather than write coordinates that no longer
        // map to a live display.
        let targetScreenID: CGDirectDisplayID? =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            // cubic ease-out: 1 - (1-t)^3
            let eased = 1 - pow(1 - t, 3)
            let r = CGRect(
                x: start.minX + (target.minX - start.minX) * eased,
                y: start.minY + (target.minY - start.minY) * eased,
                width: start.width + (target.width - start.width) * eased,
                height: start.height + (target.height - start.height) * eased
            )
            // red-team: if the user yanks an external display mid-animation,
            // the captured screen coordinates point at a phantom space and
            // the window would shoot off into limbo. Detect by checking the
            // display ID is still present.
            if let id = targetScreenID {
                let live = NSScreen.screens.contains {
                    let n = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    return n == id
                }
                if !live { return "\(displayName): display disconnected" }
            }
            let err = WinSnapAX.setFrame(window, to: r)
            if err != .success {
                // Some apps refuse the very first set; bail with a friendly note.
                return "\(displayName): refused (AX \(err.rawValue))"
            }
            if i < steps {
                // Fix 31: use typed duration to avoid silent overflow on large stepMs.
                try? await Task.sleep(for: .milliseconds(stepMs))
            }
        }
        return "\(displayName): snapped"
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

@MainActor
final class WinSnapModel: ObservableObject {
    @Published var trusted: Bool = WinSnapAX.isTrusted()
    @Published var status: String = ""
    @Published var frontmostName: String = "—"
    @Published var frontmostBundleID: String? = nil
    @Published var suggestion: WinSnapSuggestion? = nil
    @Published var openWindows: [WinSnapWindowHandle] = []
    @Published var selection: Set<UUID> = []
    private var statusClear: DispatchWorkItem?

    /// Recompute "what's the frontmost app + its smart suggestion".
    func refreshFrontmost() {
        trusted = WinSnapAX.isTrusted()
        if let (_, bid) = WinSnapAX.frontmostExternalApp() {
            frontmostBundleID = bid
            if let bid = bid,
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                frontmostName = app.localizedName ?? bid
            } else {
                frontmostName = bid ?? "—"
            }
            suggestion = WinSnapSmart.suggestion(forBundleID: bid)
        } else {
            frontmostBundleID = nil
            frontmostName = "—"
            suggestion = nil
        }
    }

    func refreshOpenWindows() {
        openWindows = WinSnapWindowList.enumerate()
        // Drop selections that no longer correspond to a real window.
        let live = Set(openWindows.map(\.id))
        selection = selection.intersection(live)
    }

    func flash(_ s: String) {
        status = s
        statusClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.status = "" }
        statusClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    func apply(_ f: WinSnapFraction) {
        // red-team: animation is now async (cooperative sleep), so kick it off
        // in a Task and update status when it completes. Snapping the picks
        // up the live window from the AX query at call time.
        Task { @MainActor in
            let msg = await WinSnapEngine.applyToFrontmost(f)
            flash(msg)
        }
    }

    /// Apply the smart suggestion for the frontmost app, and if it has a pair
    /// configured AND that pair's app is currently running, snap it too.
    func applySmart() {
        guard let s = suggestion else { flash("No suggestion for this app yet."); return }
        Task { @MainActor in
            let first = await WinSnapEngine.applyToFrontmost(s.fraction)
            var lines = [first]
            if let pairBID = s.pairBundleID, let pairF = s.pairFraction {
                // Pull windows of the pair app and snap the first eligible one.
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: pairBID).first {
                    let axApp = WinSnapAX.axApp(for: app.processIdentifier)
                    var winsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                       let wins = winsRef as? [AXUIElement] {
                        // red-team: prior code blindly took wins.first, which could
                        // be a fullscreen, minimized, or Stage-Manager-stripped
                        // window — yielding either a silent no-op or AX errors.
                        // Pick the first window we can actually move.
                        let pick = wins.first {
                            !WinSnapAX.boolAttr($0, "AXFullScreen")
                            && !WinSnapAX.boolAttr($0, kAXMinimizedAttribute as String)
                            && WinSnapAX.canResize($0)
                        }
                        if let pairWin = pick {
                            let frame = WinSnapAX.frame(of: pairWin) ?? CGRect(x: 0, y: 0, width: 800, height: 600)
                            if let screen = WinSnapAX.screenFor(axRect: frame) {
                                let target = winSnapAXRect(fraction: pairF, on: screen)
                                let err = WinSnapAX.setFrame(pairWin, to: target)
                                if err == .success {
                                    lines.append("Paired \(app.localizedName ?? pairBID): snapped")
                                } else {
                                    lines.append("Paired \(app.localizedName ?? pairBID): refused")
                                }
                            }
                        } else {
                            lines.append("Paired \(app.localizedName ?? pairBID): no moveable window")
                        }
                    }
                }
            }
            flash(lines.joined(separator: " · "))
        }
    }

    /// Stamp the selected windows into halves / thirds. Strategy:
    ///   2 windows → leftHalf, rightHalf
    ///   3 windows → leftThird, middleThird, rightThird
    ///   4 windows → quadrants
    func applyLayout() {
        // red-team: snapshot the picks at call time. If a window quits between
        // now and the animation, `applyToHandle` returns a benign "window gone"
        // status instead of crashing.
        let picks = openWindows.filter { selection.contains($0.id) }
        guard !picks.isEmpty else { flash("Pick 2–4 windows first."); return }
        let plan: [WinSnapFraction]
        switch picks.count {
        case 1: plan = [.full]
        case 2: plan = [.leftHalf, .rightHalf]
        case 3: plan = [.leftThird, .middleThird, .rightThird]
        case 4: plan = [.topLeft, .topRight, .botLeft, .botRight]
        default:
            flash("Layout supports up to 4 windows; got \(picks.count).")
            return
        }
        Task { @MainActor in
            var lines: [String] = []
            for (i, h) in picks.enumerated() {
                lines.append(await WinSnapEngine.applyToHandle(h, plan[i]))
            }
            flash(lines.joined(separator: " · "))
        }
    }
}

// ===========================================================================
// MARK: - SwiftUI surface
// ===========================================================================

public struct WinSnapView: View {
    @StateObject private var m = WinSnapModel()
    @State private var hoveredTile: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !m.trusted { grantCard }
                frontmostCard
                paletteCard
                layoutCard
                if !m.status.isEmpty { statusCard }
            }
            .padding(24)
        }
        .navigationTitle("Windows")
        .navigationSubtitle(m.trusted
                            ? "Frontmost: \(m.frontmostName)"
                            : "Accessibility access required")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    m.refreshFrontmost()
                    m.refreshOpenWindows()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Re-detect frontmost app and open windows")
            }
        }
        .onAppear {
            // Read current state, but DO NOT call AXIsProcessTrustedWithOptions.
            // We never surprise-prompt — only the explicit Grant button does that.
            m.refreshFrontmost()
            m.refreshOpenWindows()
        }
        // Fix 19: re-check AX trust when app becomes active so granting AX in
        // System Settings reflects without requiring a manual Refresh.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            m.refreshFrontmost()
        }
        .background(keyboardShortcutSink)
    }

    // ---------- Accessibility grant card ----------

    private var grantCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Accessibility access needed", systemImage: "lock.shield")
                    .font(.headline)
                Text("To move and resize other apps' windows, macOS requires Trove to have Accessibility permission. We never read keystrokes — only move/resize the focused window when you ask.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        WinSnapAX.requestTrust()
                        // Re-check shortly after; user may have accepted in the alert.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            m.refreshFrontmost()
                        }
                    } label: {
                        Label("Grant access", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        TCCDeepLink.accessibility.open()
                    } label: {
                        Label("Open System Settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        m.refreshFrontmost()
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // ---------- Smart-preset / frontmost card ----------

    private var frontmostCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Smart layout for frontmost app", systemImage: "sparkles.rectangle.stack")
                        .font(.headline)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.frontmostName).font(.body.weight(.medium))
                        if let bid = m.frontmostBundleID {
                            Text(bid).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if let s = m.suggestion {
                        Button {
                            m.applySmart()
                        } label: {
                            Label(s.label, systemImage: "wand.and.stars")
                        }
                        .disabled(!m.trusted)
                    } else {
                        Text("No suggestion in the built-in table.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let s = m.suggestion, let pid = s.pairBundleID,
                   NSRunningApplication.runningApplications(withBundleIdentifier: pid).first != nil {
                    Text("Pairs with \(pid) (currently running) on the other side.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ---------- Tile palette ----------

    /// 3×5 grid spans halves / quarters / thirds. Click to apply to frontmost.
    private var paletteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tile palette").font(.headline)
                    Spacer()
                    Text("⌘⌃← halves · ⌘⌃⇧1-5 thirds")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                          spacing: 10) {
                    ForEach(WinSnapPalette.tiles) { tile in
                        Button {
                            m.apply(tile.fraction)
                        } label: {
                            tileFace(tile)
                        }
                        .buttonStyle(.plain)
                        .disabled(!m.trusted)
                        .onHover { hoveredTile = $0 ? tile.id : (hoveredTile == tile.id ? nil : hoveredTile) }
                        .help(tile.label)
                    }
                }
            }
        }
    }

    private func tileFace(_ tile: WinSnapTile) -> some View {
        let hover = hoveredTile == tile.id
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1)
                    .frame(height: 44)
                // Visual representation of the fraction inside the tile.
                GeometryReader { g in
                    let f = tile.fraction
                    Rectangle()
                        .fill(hover ? Color.accentColor.opacity(0.65) : Color.accentColor.opacity(0.32))
                        .frame(width: g.size.width * f.w, height: g.size.height * f.h)
                        .offset(x: g.size.width * f.x, y: g.size.height * f.y)
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(tile.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .background((hover ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.10)), in: RoundedRectangle(cornerRadius: 8))
    }

    // ---------- Multi-window layout composer ----------

    private var layoutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Multi-window Layout", systemImage: "square.grid.2x2")
                        .font(.headline)
                    Spacer()
                    Button {
                        m.refreshOpenWindows()
                    } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                    Button {
                        m.applyLayout()
                    } label: { Label("Stamp \(m.selection.count) window\(m.selection.count == 1 ? "" : "s")",
                                     systemImage: "rectangle.3.group") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!m.trusted || m.selection.isEmpty || m.selection.count > 4)
                }
                Text("Pick 2–4 windows and stamp them into halves, thirds, or quadrants in one click.")
                    .font(.caption).foregroundStyle(.secondary)
                if m.openWindows.isEmpty {
                    if !m.trusted {
                        VStack(spacing: 12) {
                            Image(systemName: "xmark.octagon")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.orange)
                            Text("Accessibility permission required")
                                .font(.headline)
                            Text("Trove uses the Accessibility API to move and resize other apps' windows. macOS won't let it enumerate or move anything until you grant access in System Settings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 440)
                                .multilineTextAlignment(.center)
                            Button {
                                TCCDeepLink.accessibility.open()
                            } label: {
                                Label("Open System Settings", systemImage: "gearshape")
                            }
                            .controlSize(.regular)
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "macwindow.badge.plus")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("No moveable windows found")
                                .font(.headline)
                            Text("Trove couldn't enumerate windows from any visible app. Open something with a regular window (Safari, Notes, a Finder window) and rescan.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 440)
                                .multilineTextAlignment(.center)
                            Button {
                                m.refreshFrontmost()
                                m.refreshOpenWindows()
                            } label: {
                                Label("Rescan", systemImage: "arrow.clockwise")
                            }
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(m.openWindows) { w in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { m.selection.contains(w.id) },
                                    set: { on in
                                        if on { m.selection.insert(w.id) }
                                        else { m.selection.remove(w.id) }
                                    }
                                )).labelsHidden()
                                Image(systemName: "macwindow").foregroundStyle(.tint).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.title).font(.body).lineLimit(1)
                                    Text(w.appName).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            if w.id != m.openWindows.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // ---------- Status flash ----------

    private var statusCard: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.tint)
                Text(m.status).font(.callout).textSelection(.enabled)
                Spacer()
            }
        }
    }

    // ---------- Keyboard shortcuts (pane-foreground only) ----------

    /// Hidden button row that owns the keyboard shortcuts. SwiftUI's keyboard-
    /// shortcut system fires these when the pane is foreground, satisfying the
    /// "no global hotkeys" constraint. Buttons are 0-size so they don't render.
    private var keyboardShortcutSink: some View {
        ZStack {
            ForEach(WinSnapPalette.tiles) { tile in
                if let key = tile.shortcut {
                    Button("") { m.apply(tile.fraction) }
                        .keyboardShortcut(key, modifiers: tile.modifiers)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 0, height: 0)
    }
}
