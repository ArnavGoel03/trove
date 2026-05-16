// ===========================================================================
// MARK: - Snip (timed screenshot capture)
// ===========================================================================
//
// A delay-based screenshot pane in the Windows Snipping Tool spirit. The
// native macOS Snipping Tool (i.e. screencapture) has no delay, and the
// Windows version only offers 3 / 5 / 10s. We offer:
//
//   • Mode    : Region | Window | Full screen   (screencapture -i / -iW / -x)
//   • Delay   : None | 3s | 5s | 10s | Custom (1–60s)
//   • Action  : Stage | Clipboard | Save to file | All three
//
// At T=0:
//   1. Hide the Trove window so it doesn't sit in the shot.
//   2. Acquire InteractiveCaptureGate so we don't collide with Stage/OCR/Recorder.
//   3. Shell out to /usr/sbin/screencapture with the mode-appropriate flags.
//   4. Read the file (if it exists — Esc cancels produce no file), then
//      route the bytes into the chosen destinations.
//
// Red-team:
//   1. Gate denied              → flash + abort.
//   2. Cancel mid-countdown     → DispatchSourceTimer.cancel() + flag aborts.
//   3. screencapture Esc        → fileExists guard, release gate, no flash spam.
//   4. App crash mid-hide       → defer-based NSApp.unhide + gate release.
//   5. File-collision           → auto-append "(2)", "(3)" … to filename.
//   6. ~/Pictures denied        → fall back to ~/Downloads/Trove.
//   7. Reduce Motion            → no scale/fade animation, just the number.

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import CoreGraphics  // for CGPreflightScreenCaptureAccess (Screen Recording TCC probe)

// ===========================================================================
// MARK: - Models
// ===========================================================================

enum SnipMode: String, CaseIterable, Identifiable {
    case region, window, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .region: return "Region"
        case .window: return "Window"
        case .full:   return "Full screen"
        }
    }
    var symbol: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .full:   return "rectangle.on.rectangle"
        }
    }
    /// Arguments for `/usr/sbin/screencapture` minus the trailing destination
    /// path, which the caller appends. `-x` suppresses the camera sound on
    /// fullscreen so multi-shot bursts aren't annoying.
    func arguments(destination: String) -> [String] {
        switch self {
        case .region: return ["-i", destination]
        case .window: return ["-iW", destination]
        case .full:   return ["-x", destination]
        }
    }
}

enum SnipDelay: Hashable, Identifiable, CaseIterable {
    case none, three, five, ten, custom
    var id: String {
        switch self {
        case .none:   return "none"
        case .three:  return "three"
        case .five:   return "five"
        case .ten:    return "ten"
        case .custom: return "custom"
        }
    }
    var label: String {
        switch self {
        case .none:   return "None"
        case .three:  return "3s"
        case .five:   return "5s"
        case .ten:    return "10s"
        case .custom: return "Custom…"
        }
    }
    /// Fixed seconds, or nil if the user picks Custom… (caller substitutes).
    var fixedSeconds: Int? {
        switch self {
        case .none:   return 0
        case .three:  return 3
        case .five:   return 5
        case .ten:    return 10
        case .custom: return nil
        }
    }
    static var allCases: [SnipDelay] { [.none, .three, .five, .ten, .custom] }
}

enum SnipDestination: String, CaseIterable, Identifiable {
    case stage, clipboard, file, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stage:     return "Stage"
        case .clipboard: return "Clipboard"
        case .file:      return "Save to file"
        case .all:       return "All three"
        }
    }
    var symbol: String {
        switch self {
        case .stage:     return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        case .file:      return "folder"
        case .all:       return "square.stack.3d.up"
        }
    }
}

/// One row in the Snip "recent" strip. We hold a real on-disk URL so clicking
/// a thumbnail can re-stage it without re-shooting.
struct SnipRecent: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let mode: SnipMode
    let createdAt: Date
}

// ===========================================================================
// MARK: - File destination
// ===========================================================================

/// Resolves and creates the on-disk destination folder for "Save to file".
///
/// Red-team #6: TCC for `~/Pictures` is its own bucket on modern macOS. If the
/// user has denied it (or sandbox is locked down for their Trove build), we
/// must not silently fail — fall back to `~/Downloads/Trove` which is the
/// most-likely-writable user-owned dir.
enum SnipFileDestination {
    /// Returns `(folder, didFallBack)`. `didFallBack==true` means we couldn't
    /// write to ~/Pictures and used ~/Downloads instead.
    static func resolveFolder() -> (URL, Bool) {
        let fm = FileManager.default
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let primary = pictures.appendingPathComponent("Trove", isDirectory: true)
        if (try? fm.createDirectory(at: primary, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: primary.path) {
            return (primary, false)
        }
        // Fall back to ~/Downloads/Trove — its TCC bucket is usually open.
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let fallback = downloads.appendingPathComponent("Trove", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, true)
    }

    /// Red-team #5: two snips taken in the same second would collide on the
    /// timestamped filename. Walk "(2)", "(3)", … until we find a free slot.
    /// Race window is small (we hold the URL in our own process) but cheap to
    /// close, so do it.
    static func uniqueURL(in folder: URL, basename: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(basename).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(basename) (\(n)).\(ext)")
            n += 1
            if n > 999 { break } // safety net; should never fire
        }
        return candidate
    }
}

// ===========================================================================
// MARK: - Capture engine
// ===========================================================================

/// All the platform-side state for a Snip session — countdown timer, the
/// "are we currently running a capture" flag, recents, and the actual
/// screencapture invocation. Lives on MainActor because it touches NSApp +
/// SwiftUI state.
@MainActor
final class SnipEngine: ObservableObject {
    // User-tunable settings. SnipView binds to these.
    @Published var mode: SnipMode = .region
    @Published var delay: SnipDelay = .none
    @Published var customSeconds: Int = 5
    @Published var destination: SnipDestination = .stage

    // Countdown / live-fire state.
    @Published private(set) var countdownRemaining: Int = 0
    @Published private(set) var isCountingDown: Bool = false
    @Published private(set) var isCapturing: Bool = false

    // History strip (newest first).
    @Published private(set) var recents: [SnipRecent] = []
    static let maxRecents = 5

    /// Cancellable countdown timer. We use DispatchSourceTimer not Timer
    /// because it's easier to cancel cleanly mid-flight, and it doesn't
    /// stall when the run-loop is busy. (Red-team #2.)
    private var countdownTimer: DispatchSourceTimer?

    /// On-disk staging dir for snips that don't land in Pictures/Trove
    /// (e.g. Stage-only or Clipboard-only). We need a real URL so the
    /// recents strip can re-stage later.
    let tempDir: URL

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-snip-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        // Sweep stale `trove-snip-*` siblings older than 24h in the
        // background. The original sync scan could iterate thousands of
        // `/tmp` entries on a busy machine — that's a sync directory scan
        // on the main thread during `@StateObject` init, the same shape
        // that produced the 2026-05-16 crash loop.
        let ownPath = dir.path
        Task.detached(priority: .utility) {
            let parent = FileManager.default.temporaryDirectory
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for url in items where url.lastPathComponent.hasPrefix("trove-snip-")
                                && url.path != ownPath {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantFuture
                if mtime < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // red-team: drop the per-session tmp dir on engine teardown so it doesn't
    // outlive the pane. The recents strip holds URLs into this dir, but the
    // engine outlives the SwiftUI view via @StateObject, so by the time
    // deinit runs no UI can render those thumbnails anymore. `tempDir` is
    // `let` so it's safe to capture from a nonisolated deinit; the timer
    // is intentionally not touched here (it's MainActor-isolated state and
    // the next event loop tick would cancel it anyway via cancelCountdown
    // if the engine were still alive).
    deinit {
        let dir = tempDir
        try? FileManager.default.removeItem(at: dir)
    }

    /// Resolved seconds for the current delay selection. Custom… reads the
    /// stepper-bound `customSeconds` (clamped 1–60).
    var effectiveDelaySeconds: Int {
        if let fixed = delay.fixedSeconds { return fixed }
        return max(1, min(60, customSeconds))
    }

    // MARK: - Public entry points

    /// Begin a snip. If `effectiveDelaySeconds == 0`, fires immediately;
    /// otherwise spins up the countdown.
    func startSnip() {
        guard !isCountingDown, !isCapturing else { return }
        let secs = effectiveDelaySeconds
        if secs <= 0 {
            performCapture()
            return
        }
        countdownRemaining = secs
        isCountingDown = true
        startCountdownTimer()
    }

    /// Aborts the countdown if one is running. Safe to call at any time.
    /// Red-team #2: cancel the DispatchSourceTimer, clear state, no leftover ticks.
    func cancelCountdown() {
        countdownTimer?.cancel()
        countdownTimer = nil
        isCountingDown = false
        countdownRemaining = 0
    }

    /// Re-stage a previously captured snip without re-shooting. Used by the
    /// recents strip.
    func restage(_ recent: SnipRecent) {
        guard let img = NSImage(contentsOf: recent.url) else {
            SharedStore.stage.flash("Snip file no longer exists")
            return
        }
        SharedStore.stage.addImage(img)
        SharedStore.stage.flash("Re-staged snip")
    }

    // MARK: - Countdown plumbing

    private func startCountdownTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.countdownRemaining -= 1
            if self.countdownRemaining <= 0 {
                self.countdownTimer?.cancel()
                self.countdownTimer = nil
                self.isCountingDown = false
                self.performCapture()
            }
        }
        countdownTimer = t
        t.resume()
    }

    // MARK: - Actual capture

    /// Acquires the gate, hides the window, shells out to screencapture, and
    /// routes the resulting PNG into the chosen destinations.
    ///
    /// red-team #6 (gate release): every code path out of this function
    /// passes through the `defer` block below, which always releases the
    /// gate. That covers (a) Esc-cancel from screencapture (file-missing
    /// branch), (b) Process.run() throwing, (c) successful capture
    /// dispatching back to main, and (d) any future early-return added
    /// here. The "user clicks Cancel mid-countdown" path never reaches
    /// performCapture at all — cancelCountdown() just kills the timer
    /// before the gate is ever acquired.
    private func performCapture() {
        // Red-team #1: another capture (Stage/OCR/Recorder) is already on
        // screen — bail before hiding our own window so the user doesn't
        // see Trove vanish for nothing.
        guard InteractiveCaptureGate.tryAcquire() else {
            SharedStore.stage.flash("Another capture is already in progress")
            return
        }
        isCapturing = true

        let workURL = tempDir.appendingPathComponent(
            "snip-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png"
        )
        let mode = self.mode
        let dest = self.destination

        // Red-team #2 (window mode): screencapture -iW shows an interactive
        // window picker. If we left Trove visible the user could pick a
        // Trove window and capture the snip pane itself; if we hide before
        // the picker runs, Trove windows aren't candidates (hidden windows
        // are excluded from screencapture's picker on macOS 12+). Hiding is
        // the safe choice for all three modes.
        NSApp.hide(nil)

        // 200ms breathing room so the hide animation completes — otherwise
        // the dock-shrink frames sneak into the corner of the screenshot.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            // Red-team #4: bring the window back and release the gate no
            // matter how we exit this block — including hard crashes inside
            // the try/run code path.
            defer {
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    // Fix 20: switch to Snip pane after capture returns focus.
                    UserDefaults.standard.set(Pane.snip.rawValue, forKey: "trove.selectedPane")
                    InteractiveCaptureGate.release()
                    self?.isCapturing = false
                }
            }
            // red-team: `launchPath` is deprecated since 10.13 — switched to
            // `executableURL` to silence the warning. Same launch semantics.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = mode.arguments(destination: workURL.path)
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    SharedStore.stage.flash("Couldn't launch screencapture",
                                            kind: .error)
                }
                return
            }
            p.waitUntilExitOffMain()

            // Red-team #3: Esc-cancel from the user — screencapture exits 0
            // but writes no file. Surface gracefully, don't treat as error.
            // Red-team #6: same "exit 0, no file" symptom happens when Screen
            // Recording TCC is denied. Probe CGPreflight after the fact: if
            // permission is missing, surface the deep-link toast instead of
            // the misleading "cancelled" message.
            let fm = FileManager.default
            guard fm.fileExists(atPath: workURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: workURL.path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                DispatchQueue.main.async {
                    if !CGPreflightScreenCaptureAccess() {
                        SharedStore.stage.flash("Screen Recording permission required",
                                                kind: .warning,
                                                actionLabel: "Open Settings") {
                            TCCDeepLink.screenRecording.open()
                        }
                    } else {
                        SharedStore.stage.flash("Snip cancelled")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self?.routeCapturedFile(at: workURL, mode: mode, destination: dest)
            }
        }
    }

    /// Fan the captured PNG out to one or more destinations.
    private func routeCapturedFile(at workURL: URL, mode: SnipMode, destination: SnipDestination) {
        guard let img = NSImage(contentsOf: workURL) else {
            SharedStore.stage.flash("Couldn't read the captured image — try again.")
            return
        }

        var didStage = false
        var didClip  = false
        var savedURL: URL? = nil
        var fellBack = false

        if destination == .stage || destination == .all {
            SharedStore.stage.addImage(img)
            didStage = true
        }
        if destination == .clipboard || destination == .all {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
            // The Stage's pasteboard observer uses this to avoid auto-grabbing
            // back the image we just wrote — match the rest of the app.
            NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
            didClip = true
        }
        if destination == .file || destination == .all {
            let (folder, didFallBack) = SnipFileDestination.resolveFolder()
            fellBack = didFallBack
            let stamp = Self.timestampFormatter.string(from: Date())
            let target = SnipFileDestination.uniqueURL(in: folder,
                                                       basename: "Snip \(stamp)",
                                                       ext: "png")
            do {
                try FileManager.default.copyItem(at: workURL, to: target)
                savedURL = target
                OutputsLibrary.shared.record(
                    url: target,
                    producer: "snip",
                    sourceLabel: target.lastPathComponent,
                    kind: "image"
                )
            } catch {
                SharedStore.stage.flash("Snip save failed: \(error.localizedDescription)")
            }
        }

        // Recents strip — always remember, regardless of destination, so the
        // user can re-stage even an "only clipboard" shot without re-shooting.
        // If we saved to file we point at that path (more durable than tmp).
        let recentURL = savedURL ?? workURL
        let entry = SnipRecent(url: recentURL, mode: mode, createdAt: Date())
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents {
            recents.removeLast(recents.count - Self.maxRecents)
        }

        // User-facing summary.
        var parts: [String] = []
        if didStage { parts.append("staged") }
        if didClip  { parts.append("copied") }
        if let u = savedURL {
            parts.append("saved → \((u.path as NSString).abbreviatingWithTildeInPath)")
        }
        var msg = parts.isEmpty ? "Snip captured" : "Snip " + parts.joined(separator: " · ")
        if fellBack {
            msg += " (Pictures unavailable, used Downloads)"
        }
        SharedStore.stage.flash(msg)
    }

    /// "2025-01-31 at 14.03.07" — mirrors macOS's own screenshot naming so
    /// files saved via "All three" sort alongside system shots in Finder.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct SnipView: View {
    @StateObject private var engine = SnipEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SnipModeCard(engine: engine)
                    SnipDelayCard(engine: engine)
                    SnipDestinationCard(engine: engine)
                    SnipPrimaryButtonRow(engine: engine, reduceMotion: reduceMotion)
                    SnipRecentsCard(engine: engine)
                }
                .padding(16)
            }
            .disabled(engine.isCountingDown)

            if engine.isCountingDown {
                SnipCountdownOverlay(remaining: engine.countdownRemaining,
                                     reduceMotion: reduceMotion,
                                     onCancel: { engine.cancelCountdown() })
                    .transition(.opacity)
            }
        }
        .navigationTitle("Snip")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
    }

    private var subtitle: String {
        let delayLabel: String
        if engine.delay == .none {
            delayLabel = "no delay"
        } else {
            delayLabel = "\(engine.effectiveDelaySeconds)s delay"
        }
        return "\(engine.mode.label) · \(delayLabel) · → \(engine.destination.label)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if engine.isCountingDown {
                Button(role: .destructive) {
                    engine.cancelCountdown()
                } label: {
                    Label("Cancel (\(engine.countdownRemaining))",
                          systemImage: "xmark.circle")
                }
                .help("Stop the countdown before it fires")
            } else {
                Button {
                    engine.startSnip()
                } label: {
                    Label("Snip", systemImage: "scissors")
                }
                // red-team: the toolbar button used plain `.return` while
                // the primary button used `⌘↩`, leaving two bindings on
                // Return. Plain Return on a Stepper focus (customSeconds)
                // or any future text field in this pane would silently
                // trigger a capture. Match the primary button's `⌘↩` so
                // there's exactly one shortcut and it always requires a
                // modifier.
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(engine.isCapturing)
                .help("Take the screenshot \(engine.effectiveDelaySeconds > 0 ? "after \(engine.effectiveDelaySeconds)s" : "now") (⌘↩)")
            }
        }
    }
}

// ===========================================================================
// MARK: - Mode card
// ===========================================================================

private struct SnipModeCard: View {
    @ObservedObject var engine: SnipEngine
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Capture mode")
                    .font(.headline)
                Picker("", selection: $engine.mode) {
                    ForEach(SnipMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var modeHint: String {
        switch engine.mode {
        case .region: return "Drag a rectangle. Esc to cancel."
        case .window: return "Click a window. Space toggles the dropshadow."
        case .full:   return "Captures every connected display silently."
        }
    }
}

// ===========================================================================
// MARK: - Delay card
// ===========================================================================

private struct SnipDelayCard: View {
    @ObservedObject var engine: SnipEngine
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Delay")
                        .font(.headline)
                    Spacer()
                    Text("Windows Snipping Tool tops out at 10s — we go to 60s.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Picker("", selection: $engine.delay) {
                    ForEach(SnipDelay.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if engine.delay == .custom {
                    HStack(spacing: 10) {
                        Stepper(value: $engine.customSeconds, in: 1...60) {
                            Text("\(engine.customSeconds)s")
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 44, alignment: .leading)
                        }
                        .fixedSize()
                        Slider(value: Binding(
                            get: { Double(engine.customSeconds) },
                            set: { engine.customSeconds = Int($0.rounded()) }
                        ), in: 1...60, step: 1)
                    }
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Destination card
// ===========================================================================

private struct SnipDestinationCard: View {
    @ObservedObject var engine: SnipEngine
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("After capture")
                    .font(.headline)
                Picker("", selection: $engine.destination) {
                    ForEach(SnipDestination.allCases) { d in
                        Label(d.label, systemImage: d.symbol).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(destinationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var destinationHint: String {
        switch engine.destination {
        case .stage:     return "Adds the image to the Stage pane."
        case .clipboard: return "Writes the PNG to the system pasteboard."
        case .file:      return "Saves to ~/Pictures/Trove (falls back to ~/Downloads/Trove)."
        case .all:       return "Stages, copies to clipboard, and saves to disk in one shot."
        }
    }
}

// ===========================================================================
// MARK: - Primary button row
// ===========================================================================

private struct SnipPrimaryButtonRow: View {
    @ObservedObject var engine: SnipEngine
    let reduceMotion: Bool
    var body: some View {
        Card {
            HStack(spacing: 14) {
                Button {
                    engine.startSnip()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "scissors")
                            .font(.system(size: 18, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Snip")
                                .font(.title3.weight(.semibold))
                            Text(buttonSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.isCountingDown || engine.isCapturing)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Run the capture (⌘↩)")

                if engine.isCountingDown {
                    Button(role: .destructive) {
                        engine.cancelCountdown()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .controlSize(.large)
                }
            }
        }
    }
    private var buttonSubtitle: String {
        let secs = engine.effectiveDelaySeconds
        if secs == 0 {
            return "\(engine.mode.label) → \(engine.destination.label)"
        }
        return "in \(secs)s · \(engine.mode.label) → \(engine.destination.label)"
    }
}

// ===========================================================================
// MARK: - Countdown overlay
// ===========================================================================

/// Big translucent overlay that shows the seconds remaining. Honors Reduce
/// Motion (red-team #7) by switching off the scale/pulse animation and just
/// re-rendering the number.
private struct SnipCountdownOverlay: View {
    let remaining: Int
    let reduceMotion: Bool
    let onCancel: () -> Void
    // Fix 24: solid fill fallback when Reduce Transparency is enabled.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Snipping in")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Group {
                    if reduceMotion {
                        Text("\(remaining)")
                            .font(.system(size: 140, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Text("\(remaining)")
                            .font(.system(size: 140, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .id(remaining) // re-trigger animation each tick
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: remaining)
                    }
                }
                .accessibilityLabel("\(remaining) seconds remaining")

                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(40)
        }
    }
}

// ===========================================================================
// MARK: - Recents strip
// ===========================================================================

private struct SnipRecentsCard: View {
    @ObservedObject var engine: SnipEngine
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent snips")
                        .font(.headline)
                    Spacer()
                    if engine.recents.count > 1 {
                        Button {
                            SnipRecentSaver.saveAll(engine.recents)
                        } label: {
                            Label("Save All…", systemImage: "square.and.arrow.down.on.square")
                        }
                        .help("Pick a folder and save every recent snip into it")
                    }
                    Text("\(engine.recents.count) of \(SnipEngine.maxRecents)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if engine.recents.isEmpty {
                    Text("Nothing yet. Your last 5 snips show up here — click one to re-stage it without re-shooting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(engine.recents) { recent in
                                // Only the latest recent (first in the list)
                                // gets keyboard shortcuts. SwiftUI logs
                                // warnings about duplicate shortcut bindings
                                // and the most-recent is the obvious primary.
                                SnipRecentThumb(
                                    recent: recent,
                                    isPrimary: recent.id == engine.recents.first?.id
                                ) {
                                    engine.restage(recent)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

private struct SnipRecentThumb: View {
    let recent: SnipRecent
    var isPrimary: Bool = false
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onSelect) {
                Group {
                    if let img = OCREngine.fastThumbnail(url: recent.url, maxPixel: 256) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFill()
                    } else {
                        // The on-disk file may have been pruned from /tmp.
                        // Show a placeholder so the strip doesn't crash.
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 130, height: 84)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hover ? Color.accentColor.opacity(0.7)
                                            : Color.secondary.opacity(0.35),
                                      lineWidth: hover ? 1.2 : 0.5)
                )
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Click to re-stage this snip")
            // The thumbnail is draggable into Finder, Mail, Slack, etc.
            // NSItemProvider(contentsOf:) creates a file-URL representation
            // receivers accept as a real file drop.
            .onDrag {
                NSItemProvider(contentsOf: recent.url) ?? NSItemProvider()
            }
            .contextMenu {
                Button { SnipRecentSaver.save(recent) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                Button { SnipRecentSaver.quickSaveToDownloads(recent) } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                Button {
                    SharedStore.stage.addFile(recent.url)
                    SharedStore.stage.flash("Sent \(recent.url.lastPathComponent) to Stage")
                } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
                Divider()
                Button { SnipRecentSaver.copyImageToClipboard(recent) } label: { Label("Copy image to clipboard", systemImage: "photo.on.rectangle") }
                Button { SnipRecentSaver.copyPath(recent) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            }

            HStack(spacing: 4) {
                Image(systemName: recent.mode.symbol)
                    .font(.caption2)
                Text(Self.timeFormatter.string(from: recent.createdAt))
                    .font(.caption2.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    SnipRecentSaver.save(recent)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .modifier(SnipPrimaryShortcut(isPrimary: isPrimary, key: "s"))
                .help(isPrimary ? "Save… (⌘S)" : "Save…")

                Menu {
                    Button {
                        SnipRecentSaver.quickSaveToDownloads(recent)
                    } label: {
                        Label("Save to Downloads", systemImage: "arrow.down.circle")
                    }
                    .modifier(SnipPrimaryShortcut(isPrimary: isPrimary, key: "d"))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([recent.url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "magnifyingglass")
                    }
                    .modifier(SnipPrimaryShortcut(isPrimary: isPrimary, key: "r"))
                    Button {
                        SharedStore.stage.addFile(recent.url)
                        SharedStore.stage.flash("Sent \(recent.url.lastPathComponent) to Stage")
                    } label: {
                        Label("Send to Stage", systemImage: "tray.and.arrow.down")
                    }
                    Divider()
                    Button {
                        SnipRecentSaver.copyImageToClipboard(recent)
                    } label: {
                        Label("Copy image to clipboard", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        SnipRecentSaver.copyPath(recent)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")

                Spacer(minLength: 0)
            }
            .frame(width: 130, alignment: .leading)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// ===========================================================================
// MARK: - Primary-row keyboard shortcut helper
// ===========================================================================

/// Apply ⌘<key> only to the latest snip thumb. SwiftUI logs warnings about
/// duplicate shortcut bindings within the same scope; older thumbs still get
/// the same actions via right-click / their own action buttons.
private struct SnipPrimaryShortcut: ViewModifier {
    let isPrimary: Bool
    let key: KeyEquivalent
    init(isPrimary: Bool, key: Character) {
        self.isPrimary = isPrimary
        self.key = KeyEquivalent(key)
    }
    func body(content: Content) -> some View {
        if isPrimary {
            content.keyboardShortcut(key, modifiers: [.command])
        } else {
            content
        }
    }
}

// ===========================================================================
// MARK: - Recent-snip save helpers (statics so closures don't capture self)
// ===========================================================================

/// Save / drag / clipboard helpers for SnipRecent rows. Mirrors the pdf.swift
/// outputRow affordance set: Save…, Save to Downloads, Reveal, Stage, Copy
/// Path, Copy image to clipboard, Save All….
enum SnipRecentSaver {
    private static let kSaveDirKey = "snip.captures.saveDir.last"

    /// Save As… with NSSavePanel. Remembers the last-used directory so the
    /// user doesn't have to re-navigate; pre-fills the filename so a single
    /// Return keeps the original name.
    static func save(_ recent: SnipRecent) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recent.url.lastPathComponent
        if let ut = UTType(filenameExtension: recent.url.pathExtension) {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                // NSSavePanel itself confirmed overwrite consent. Use an
                // atomic write pattern: copy to a sibling tmp, then replace
                // atomically so a crash mid-copy never leaves a partial file.
                let tmp = dest.deletingLastPathComponent()
                    .appendingPathComponent(".\(dest.lastPathComponent).tmp")
                if FileManager.default.fileExists(atPath: tmp.path) {
                    try FileManager.default.removeItem(at: tmp)
                }
                try FileManager.default.copyItem(at: recent.url, to: tmp)
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp,
                                                          backupItemName: nil,
                                                          options: .usingNewMetadataOnly)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-click save into ~/Downloads. Collision-safe — never overwrites.
    static func quickSaveToDownloads(_ recent: SnipRecent) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = collisionFreeURL(in: downloads, name: recent.url.lastPathComponent)
        do {
            try fm.copyItem(at: recent.url, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    static func copyPath(_ recent: SnipRecent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recent.url.path, forType: .string)
        SharedStore.stage.flash("Copied path")
    }

    /// Copy the PNG bytes onto NSPasteboard as both .png and .tiff so the
    /// destination app can pick whichever flavor it prefers. Mirrors the
    /// pattern qr.swift uses for QR clipboard support.
    static func copyImageToClipboard(_ recent: SnipRecent) {
        guard let img = NSImage(contentsOf: recent.url) else {
            SharedStore.stage.flash("Couldn't read image — file may be missing")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let data = try? Data(contentsOf: recent.url) {
            _ = pb.setData(data, forType: .png)
        }
        if let tiff = img.tiffRepresentation {
            _ = pb.setData(tiff, forType: .tiff)
        }
        SharedStore.stage.flash("Copied image to clipboard")
    }

    /// Bulk save — pick a folder, dump every recent snip with collision-safe
    /// naming. Reveals the folder afterwards.
    static func saveAll(_ recents: [SnipRecent]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Save All Here"
        panel.message = "Choose a destination folder for \(recents.count) snips."
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dir = panel.url else { return }
            setLastSaveDir(dir)
            let fm = FileManager.default
            var copied = 0
            for r in recents {
                let dest = collisionFreeURL(in: dir, name: r.url.lastPathComponent)
                if (try? fm.copyItem(at: r.url, to: dest)) != nil { copied += 1 }
            }
            if copied > 0 {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                SharedStore.stage.flash("Saved \(copied) of \(recents.count) to \(dir.lastPathComponent)")
            } else {
                SharedStore.stage.flash("Save All failed — couldn't copy any snips")
            }
        }
    }

    // ---- shared save helpers --------------------------------------------

    static func lastSaveDir() -> URL? {
        guard let p = UserDefaults.standard.string(forKey: kSaveDirKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    static func setLastSaveDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: kSaveDirKey)
    }

    static func downloadsDir() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Append " (2)", " (3)"… before the extension until the destination
    /// doesn't exist. Cap at 99 — past that, return the last candidate and
    /// let the copy fail with a sane error (don't loop forever).
    static func collisionFreeURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: dest.path) { return dest }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...99 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(stem) (\(n))")
                : dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            dest = candidate
        }
        return dest
    }
}
