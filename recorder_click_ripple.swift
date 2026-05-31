// Trove — Recorder click ripple + keystroke overlay (power-user items #5 + #4).
//
// Two HUD overlays driven by a shared CGEventTap, kept in one file so the
// tap lifecycle is easy to reason about and only one tap exists at a time:
//
//   • #5 Click ripple — a fading concentric circle at every mouse click,
//        so viewers of the recording can SEE where the user clicked
//        without trying to follow a tiny cursor at 60fps.
//   • #4 Keystroke overlay — a small HUD showing the last chord pressed
//        (e.g. "⌘⇧K"), fading out after ~1.5s. Essential for tutorial
//        recordings where the cursor doesn't reveal what was typed.
//
// Privacy / red-team:
//   • Both overlays only render WHILE RECORDING and only when the
//     corresponding pref is on. The CGEventTap installs lazily and
//     uninstalls when the last consumer turns off — no tap when no
//     overlay is wanted.
//   • Secure-input fields (Touch ID, password boxes) set a system flag
//     that suppresses key events at the kCGEventTapEnableInterception
//     layer. We additionally filter out the chord rendering when
//     `IsSecureEventInputEnabled()` is true, so a password typed during
//     a recording never lands in the overlay buffer.
//   • The overlays are borderless transparent NSPanels with the
//     accessory window collection behavior; they do NOT capture mouse
//     events themselves (`ignoresMouseEvents = true`) and stay above
//     fullscreen windows so they're visible in the recording.

import AppKit
import SwiftUI
import Carbon

// =============================================================================
// MARK: - User preferences
// =============================================================================

enum RecOverlayPosition: String, CaseIterable, Codable, Identifiable {
    case bottomCenter, bottomLeading, bottomTrailing, topTrailing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter:   return "Bottom center"
        case .bottomLeading:  return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        case .topTrailing:    return "Top right"
        }
    }
}

// =============================================================================
// MARK: - Shared CGEventTap manager
// =============================================================================
//
// One process-wide tap with two consumers (click ripple + keystroke
// overlay). The tap is created on the first consumer enable + torn down
// on the last consumer disable, so we don't pay event-tap overhead when
// neither overlay is in use.

@MainActor
final class RecOverlayTap {
    static let shared = RecOverlayTap()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var clickRippleEnabled = false
    private var keystrokeOverlayEnabled = false

    func setClickRipple(_ on: Bool) {
        clickRippleEnabled = on
        rebuildIfNeeded()
    }
    func setKeystrokeOverlay(_ on: Bool) {
        keystrokeOverlayEnabled = on
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        let want = clickRippleEnabled || keystrokeOverlayEnabled
        if want && tap == nil { installTap() }
        if !want && tap != nil { teardownTap() }
    }

    private func installTap() {
        // Mask: leftMouseDown, rightMouseDown, otherMouseDown for clicks;
        // keyDown + flagsChanged for keystrokes. We do NOT request
        // mouseMoved or mouseDragged — too high-rate, no reason to.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        // Listen-only tap — we never modify or drop events. headInsertEventTap
        // is fine for observation.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // CGEventTap fires off-main; hop back onto MainActor
                // before any AppKit work.
                let isMouse = (type == .leftMouseDown
                            || type == .rightMouseDown
                            || type == .otherMouseDown)
                if isMouse {
                    let location = event.location
                    let typeCopy = type
                    Task { @MainActor in
                        RecOverlayDispatcher.shared.handleMouseDown(
                            type: typeCopy, location: location)
                    }
                } else if type == .keyDown {
                    let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags
                    Task { @MainActor in
                        RecOverlayDispatcher.shared.handleKeyDown(
                            keyCode: kc, flags: flags)
                    }
                } else if type == .flagsChanged {
                    let flags = event.flags
                    Task { @MainActor in
                        RecOverlayDispatcher.shared.handleFlagsChanged(flags: flags)
                    }
                }
                // Listen-only: pass the event through unchanged.
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil) else {
            // Most likely cause on first run: Accessibility permission
            // hasn't been granted yet. The user sees the overlay simply
            // not work; the per-pane toggle handles the "ask first"
            // flow before flipping pref to on, so we don't loop forever.
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
    }

    private func teardownTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            tap = nil
        }
    }
}

// =============================================================================
// MARK: - Dispatcher — routes events to active overlay panels
// =============================================================================

@MainActor
final class RecOverlayDispatcher {
    static let shared = RecOverlayDispatcher()

    var clickRippleOn  = false   // gated on pref + active recording
    var keystrokeOn    = false   // gated on pref + active recording

    private let ripplePanel = RecRipplePanel()
    private let keystrokePanel = RecKeystrokePanel()

    // Modifier-key state for keystroke overlay — we track flagsChanged
    // so the chord rendering reflects current modifiers when a keyDown
    // arrives, without having to ask the system on each event.
    private var currentFlags: CGEventFlags = []

    func handleMouseDown(type: CGEventType, location: CGPoint) {
        guard clickRippleOn else { return }
        ripplePanel.showRipple(at: location)
    }

    func handleKeyDown(keyCode: Int, flags: CGEventFlags) {
        guard keystrokeOn else { return }
        // Privacy: skip when secure input is active (password field).
        if IsSecureEventInputEnabled() { return }
        let chord = RecChordFormatter.format(keyCode: keyCode, flags: flags)
        guard !chord.isEmpty else { return }
        keystrokePanel.showChord(chord)
    }

    func handleFlagsChanged(flags: CGEventFlags) {
        currentFlags = flags
    }
}

// =============================================================================
// MARK: - Click ripple panel
// =============================================================================

private final class RecRipplePanel: NSPanel {
    private var hosting: NSHostingView<RecRippleView>?
    private var content = RecRippleContent()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                   .fullScreenAuxiliary, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RecRippleView(content: content))
        host.frame = NSRect(x: 0, y: 0, width: 96, height: 96)
        self.contentView = host
        self.hosting = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Render one ripple at the global screen point. CGEventTap gives us
    /// flipped coordinates (origin top-left); NSWindow wants origin
    /// bottom-left. The conversion is per-screen because each display
    /// has its own coordinate space.
    func showRipple(at flippedGlobal: CGPoint) {
        let s = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: flippedGlobal.x, y: $0.frame.maxY - flippedGlobal.y)) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = s else { return }
        let yFlipped = screen.frame.maxY - flippedGlobal.y
        let center = NSPoint(x: flippedGlobal.x, y: yFlipped)
        let origin = NSPoint(x: center.x - 48, y: center.y - 48)
        self.setFrame(NSRect(origin: origin, size: NSSize(width: 96, height: 96)),
                      display: false)
        self.orderFrontRegardless()
        content.tick &+= 1   // triggers a fresh ripple animation
    }
}

private final class RecRippleContent: ObservableObject {
    @Published var tick: Int = 0
}

private struct RecRippleView: View {
    @ObservedObject var content: RecRippleContent
    @State private var animating: Set<Int> = []

    var body: some View {
        ZStack {
            ForEach(Array(animating), id: \.self) { id in
                RecRippleRing(id: id) { animating.remove($0) }
            }
        }
        .frame(width: 96, height: 96)
        .allowsHitTesting(false)
        .onChange(of: content.tick) { _, new in
            animating.insert(new)
        }
    }
}

private struct RecRippleRing: View {
    let id: Int
    let onDone: (Int) -> Void
    @State private var progress: Double = 0

    var body: some View {
        Circle()
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .scaleEffect(0.3 + progress * 0.9)
            .opacity(1.0 - progress)
            .frame(width: 96, height: 96)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) {
                    progress = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    onDone(id)
                }
            }
            .accessibilityHidden(true)
    }
}

// =============================================================================
// MARK: - Keystroke overlay panel
// =============================================================================

private final class RecKeystrokePanel: NSPanel {
    private let content = RecKeystrokeContent()
    private var hosting: NSHostingView<RecKeystrokeView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                   .fullScreenAuxiliary, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RecKeystrokeView(content: content))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 64)
        self.contentView = host
        self.hosting = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showChord(_ chord: String) {
        // Position bottom-center of the main screen. The recorder pane
        // will eventually expose per-recording position config; for
        // batch 2 the bottom-center placement matches the convention.
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else { return }
        let pSize = NSSize(width: 280, height: 64)
        let origin = NSPoint(x: s.visibleFrame.midX - pSize.width / 2,
                              y: s.visibleFrame.minY + 36)
        self.setFrame(NSRect(origin: origin, size: pSize), display: false)
        content.pushChord(chord)
        self.orderFrontRegardless()
    }
}

private final class RecKeystrokeContent: ObservableObject {
    @Published var visibleChord: String = ""
    @Published var visible: Bool = false
    private var hideWorkItem: DispatchWorkItem?

    func pushChord(_ chord: String) {
        visibleChord = chord
        visible = true
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.visible = false
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

private struct RecKeystrokeView: View {
    @ObservedObject var content: RecKeystrokeContent

    var body: some View {
        ZStack {
            if content.visible {
                Text(content.visibleChord)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .transition(.opacity)
                    .accessibilityLabel("Keystroke overlay: \(content.visibleChord)")
            }
        }
        .frame(width: 280, height: 64)
        .animation(.easeInOut(duration: 0.18), value: content.visible)
        .allowsHitTesting(false)
    }
}

// =============================================================================
// MARK: - Chord formatter
// =============================================================================
//
// Renders a CGEvent keyCode + flags into a human-readable chord string
// like "⌘⇧K", "fn↑", "⌥⌘Space". Unknown keys render as their hex code
// rather than nothing, so the overlay never goes silent on weird keys.

enum RecChordFormatter {
    static func format(keyCode: Int, flags: CGEventFlags) -> String {
        var modifiers = ""
        if flags.contains(.maskControl)   { modifiers += "⌃" }
        if flags.contains(.maskAlternate) { modifiers += "⌥" }
        if flags.contains(.maskShift)     { modifiers += "⇧" }
        if flags.contains(.maskCommand)   { modifiers += "⌘" }

        let key = keyName(keyCode: keyCode, flags: flags)
        // Plain alphanumerics without any modifier aren't worth overlaying —
        // they're just somebody typing prose. Skip unless there's at least
        // one modifier.
        if modifiers.isEmpty && key.count == 1 {
            // ...unless it's a function/arrow key (already handled above with
            // a non-letter name). Otherwise skip.
            return ""
        }
        return modifiers + key
    }

    private static func keyName(keyCode: Int, flags: CGEventFlags) -> String {
        // Carbon-style virtual key codes. Limited set of common keys —
        // we don't try to cover every international keyboard layout.
        switch keyCode {
        case kVK_Return:           return "↩"
        case kVK_Tab:              return "⇥"
        case kVK_Space:            return "Space"
        case kVK_Delete:           return "⌫"
        case kVK_ForwardDelete:    return "⌦"
        case kVK_Escape:           return "⎋"
        case kVK_UpArrow:          return "↑"
        case kVK_DownArrow:        return "↓"
        case kVK_LeftArrow:        return "←"
        case kVK_RightArrow:       return "→"
        case kVK_Home:             return "Home"
        case kVK_End:              return "End"
        case kVK_PageUp:           return "PgUp"
        case kVK_PageDown:         return "PgDn"
        case kVK_F1:               return "F1"
        case kVK_F2:               return "F2"
        case kVK_F3:               return "F3"
        case kVK_F4:               return "F4"
        case kVK_F5:               return "F5"
        case kVK_F6:               return "F6"
        case kVK_F7:               return "F7"
        case kVK_F8:               return "F8"
        case kVK_F9:               return "F9"
        case kVK_F10:              return "F10"
        case kVK_F11:              return "F11"
        case kVK_F12:              return "F12"
        default: break
        }
        // Fall through to the UCKeyTranslate path via TIS to get the
        // character the keypress would produce given the current layout.
        return Self.character(forKeyCode: keyCode) ?? String(format: "0x%02X", keyCode)
    }

    private static func character(forKeyCode keyCode: Int) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let layoutDataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        guard let dataPtr = layoutDataPtr else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress else { return nil }
            let keyLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len: Int = 0
            let status = UCKeyTranslate(
                keyLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,                                  // modifier state — uppercase via separate ⇧
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &len,
                &chars)
            guard status == noErr, len > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: len).uppercased()
        }
    }
}
