// Trove — Recorder floating stop panel (power-user items #7 + #8 + #16).
//
// Three pro features that share the same NSPanel + Carbon hotkey plumbing,
// kept in one file so the lifecycle is easy to reason about:
//
//   • #7  Floating Stop button — a small always-on-top, draggable, non-
//          focus-stealing panel showing the elapsed time + Pause + Stop.
//          Essential when you're recording fullscreen (a game, an IDE,
//          a presentation) and can't reach the Trove window.
//   • #8  Global hotkey to stop — ⌘⇧. by default, user-configurable in
//          Settings → Hotkeys. Registers via the existing Carbon-based
//          hotkey manager that other panes share, so it works while any
//          app is frontmost.
//   • #16 Menu-bar status item during recording — a discreet record
//          dot in the menu bar that doubles as a one-click stop. Opt-in
//          via the same pref dropdown as the floating stop panel.
//
// All three are opt-in. None of them touches RecEngine internals; they
// observe `engine.isRecording` and call the existing `stop()` / `pause()`
// public methods. The HUD inside the Recorder pane stays the primary
// affordance — these are escape hatches for when the pane isn't visible.

import SwiftUI
import AppKit
import Combine

// =============================================================================
// MARK: - User preferences
// =============================================================================

enum RecFloatingStopPref: String, CaseIterable, Identifiable, Codable {
    case off            // never show
    case whileRecording // show when a recording starts, hide on stop
    case always         // show whenever Trove is running (handy for repeat takes)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:            return "Off"
        case .whileRecording: return "While recording"
        case .always:         return "Always"
        }
    }
}

// =============================================================================
// MARK: - The floating panel
// =============================================================================

/// Borderless `NSPanel` that floats above other apps without stealing focus.
/// Draggable from anywhere; click-through-clear background. Auto-positions
/// to the bottom-center of the active screen on first show, then remembers
/// its last frame across launches.
private final class RecStopPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
        // Stay above every regular window, including fullscreen apps —
        // .statusBar is high enough without being modal-blocking.
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
                                   .ignoresCycle]
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
    }

    /// Don't steal focus — clicks on the panel act on it, but the
    /// currently-frontmost app keeps key/main status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// =============================================================================
// MARK: - SwiftUI content
// =============================================================================

private struct RecStopPanelContent: View {
    @ObservedObject var engine: RecEngine
    var onStop: () -> Void
    var onClose: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing dot — same red as the in-pane HUD. Reduce-motion safe.
            Circle()
                .fill(engine.isPaused ? Color.orange : Color.red)
                .frame(width: 11, height: 11)
                .opacity(reducedMotion
                         ? 1.0
                         : (engine.isPaused ? 1.0 : (pulse ? 0.4 : 1.0)))
                .animation(reducedMotion
                           ? nil
                           : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: pulse)
                .onAppear { if !reducedMotion { pulse = true } }
                .accessibilityHidden(true)

            // Elapsed time — monospaced so digits don't dance.
            Text(timecode(engine.elapsed))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .accessibilityLabel("Recording elapsed \(Int(engine.elapsed)) seconds")

            Spacer(minLength: 4)

            // Pause / Resume — same pattern as the in-pane HUD.
            Button {
                if engine.isPaused { engine.resume() } else { engine.pause() }
            } label: {
                Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(engine.isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(engine.isPaused ? "Resume recording" : "Pause recording")

            // Stop — the headline button. Borderless prominent red so it
            // reads as the primary action even at this tiny size.
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 22)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Stop recording (⌘⇧. or Esc)")
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
        )
        // Esc inside the panel cancels through to stop — same as the in-pane HUD.
        .background(
            Button("") { onStop() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(engine.isPaused
                            ? "Recording paused — \(timecode(engine.elapsed))"
                            : "Recording — \(timecode(engine.elapsed))")
    }

    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func timecode(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, ss = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, ss)
            : String(format: "%02d:%02d", m, ss)
    }
}

// =============================================================================
// MARK: - Controller (one per app lifetime)
// =============================================================================

@MainActor
final class RecFloatingStopController: ObservableObject {
    static let shared = RecFloatingStopController()

    private let panel = RecStopPanel()
    private var hosting: NSHostingView<RecStopPanelContent>?
    private var observer: AnyCancellable?
    private var positionedOnce = false
    private weak var engine: RecEngine?
    private weak var onStopRouter: AnyObject?
    private var stopAction: (() -> Void)?

    /// Wire up. The Recorder pane calls this once with its engine + the
    /// async stop closure the HUD already uses; the controller then
    /// shows/hides the panel based on the pref + recording state.
    func attach(engine: RecEngine, stop: @escaping () -> Void) {
        self.engine = engine
        self.stopAction = stop
        rebuildHosting()
        observer?.cancel()
        observer = engine.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
        syncVisibility()
    }

    /// User pref changed → re-evaluate visibility immediately.
    func prefDidChange() { syncVisibility() }

    private func rebuildHosting() {
        guard let engine = self.engine, let stop = self.stopAction else { return }
        let content = RecStopPanelContent(
            engine: engine,
            onStop: { [weak self] in
                self?.stopAction?()
            },
            onClose: { [weak self] in
                self?.panel.orderOut(nil)
            })
        if let host = hosting {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
            panel.contentView = host
            self.hosting = host
        }
    }

    private func syncVisibility() {
        guard let engine = self.engine else { return }
        let raw = UserDefaults.standard.string(forKey: "rec.floatingStop")
            ?? RecFloatingStopPref.whileRecording.rawValue
        let pref = RecFloatingStopPref(rawValue: raw) ?? .whileRecording
        let shouldShow: Bool
        switch pref {
        case .off:            shouldShow = false
        case .whileRecording: shouldShow = engine.isRecording
        case .always:         shouldShow = true
        }
        if shouldShow {
            if !positionedOnce {
                positionToDefault()
                positionedOnce = true
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Bottom-center of the screen Trove's main window is on. Adequate
    /// default; the user can drag from there and the panel remembers
    /// its frame via NSPanel autosaving.
    private func positionToDefault() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else { return }
        let pSize = panel.frame.size
        let x = s.visibleFrame.midX - pSize.width / 2
        let y = s.visibleFrame.minY + 32
        panel.setFrame(NSRect(x: x, y: y, width: pSize.width, height: pSize.height),
                       display: true)
        panel.setFrameAutosaveName("trove.rec.floatingStop")
    }
}

// =============================================================================
// MARK: - Menu-bar status item during recording (#16)
// =============================================================================
//
// Mirrors the Mirror pane's opt-in menu-bar item but with a record-dot
// icon and a single click → stop. We don't bother with a popover — the
// click does the work directly, matching what Loom and QuickTime do.

@MainActor
final class RecMenuBarController: ObservableObject {
    static let shared = RecMenuBarController()

    private var statusItem: NSStatusItem?
    private var observer: AnyCancellable?
    private var pulseTimer: Timer?
    private var pulseOn = true
    private weak var engine: RecEngine?
    private var stopAction: (() -> Void)?

    func attach(engine: RecEngine, stop: @escaping () -> Void) {
        self.engine = engine
        self.stopAction = stop
        observer?.cancel()
        observer = engine.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
        syncVisibility()
    }

    func prefDidChange() { syncVisibility() }

    private func syncVisibility() {
        let on = UserDefaults.standard.bool(forKey: "rec.menuBarWhileRecording")
        guard let engine = self.engine else { return }
        if on && engine.isRecording {
            ensureStatusItem()
            startPulse()
        } else {
            stopPulse()
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = s.button {
            btn.image = NSImage(systemSymbolName: "record.circle.fill",
                                 accessibilityDescription: "Recording")
            btn.toolTip = "Trove is recording — click to stop"
            btn.target = self
            btn.action = #selector(menuBarClicked(_:))
        }
        statusItem = s
    }

    private func removeStatusItem() {
        if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
            statusItem = nil
        }
    }

    @objc private func menuBarClicked(_ sender: Any?) {
        stopAction?()
    }

    private func startPulse() {
        pulseTimer?.invalidate()
        // 1 Hz pulse — opacity dimming on the icon. Skipped under Reduce
        // Motion to avoid drawing attention away from real recording UI.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseOn.toggle()
                self.statusItem?.button?.alphaValue = self.pulseOn ? 1.0 : 0.55
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem?.button?.alphaValue = 1.0
    }
}
