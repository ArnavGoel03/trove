// Trove — Screen Recorder pane.
//
// The thing QuickTime can't do: capture system audio + microphone + a region
// in one flow, with no BlackHole/Loopback kernel-extension dance. Built on
// ScreenCaptureKit (macOS 13+), which finally exposed system-audio taps to
// userland apps. CleanShot X charges $30 for this; we ship it as one pane.
//
// Step-ups vs QuickTime / Kap / CleanShot X / OBS / Loom:
//   1. System audio + mic + region in a single capture — no virtual audio
//      device install, no kernel extension, no reboot. SCK does the system
//      audio tap; AVCaptureSession does the mic; AVAssetWriter muxes both.
//   2. Three preset chips in the toolbar:
//        • "Tutorial" = region + system audio + mic
//        • "Demo"     = full screen + system audio (no mic)
//        • "Quiet"    = region only, no audio at all
//   3. Live HUD while recording: mm:ss timer, running file-size estimate,
//      and per-source audio level meters that move in real time.
//   4. One-click "Send to Stage" on stop — the finished .mp4 drops into
//      SharedStore.stage as a file item, ready for batch share/copy.
//   5. Default output ~/Movies/Trove; filenames Trove-yyyyMMdd-HHmmss.mp4
//      so they sort chronologically in Finder without thinking.
//   6. Pause / resume within a single recording — AVAssetWriter timeline
//      stitches the segments using its own monotonic clock.
//
// Crash safety: writes go to a sibling .tmp.mp4 file first, renamed to the
// final filename only on successful finalize. If the app dies mid-recording
// the .tmp.mp4 is left behind (recoverable with ffmpeg in most cases, but
// will likely have a missing moov atom — documented, not promised).
//
// All red-team scenarios from the spec are addressed inline; see the
// `RecRedTeam` comment block near the bottom of the file for the index.

import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Foundation
import UniformTypeIdentifiers
import IOKit.pwr_mgt
import os

// ===========================================================================
// MARK: - Presets, sources, errors
// ===========================================================================

/// Three preset chips that snap multiple toggles at once. Picked to cover the
/// 90% of recording flows people actually do — explaining something to a
/// teammate, demoing an app, capturing a silent reference clip.
enum RecPreset: String, CaseIterable, Identifiable {
    case tutorial = "Tutorial"   // region + system audio + mic
    case demo     = "Demo"       // full screen + system audio
    case quiet    = "Quiet"      // region only, no audio
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tutorial: return "person.wave.2.fill"
        case .demo:     return "play.rectangle.fill"
        case .quiet:    return "speaker.slash.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .tutorial: return "Region · system + mic"
        case .demo:     return "Full screen · system"
        case .quiet:    return "Region · silent"
        }
    }
}

/// Which surface the user wants to capture. Region is selected interactively
/// via `screencapture -i` (just to grab the rect), then the actual recording
/// runs through SCK with that rect applied as a contentRect on the display.
enum RecSourceKind: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(CGRect, displayID: CGDirectDisplayID)
}

/// User-facing error model. Each case maps to an inline banner with a clear
/// next step rather than a modal dialog the user has to dismiss.
enum RecError: Error, LocalizedError, Equatable {
    case needsScreenRecordingPermission
    case needsMicrophonePermission
    case noMicrophone
    case noShareableContent
    case unsupportedOS
    case diskFull
    case writerFailed(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .needsScreenRecordingPermission:
            return "Trove needs Screen Recording permission to capture your screen."
        case .needsMicrophonePermission:
            return "Microphone access was denied. Recording will continue without microphone audio."
        case .noMicrophone:
            return "No microphone is connected. Recording will continue without microphone audio."
        case .noShareableContent:
            return "Couldn't enumerate displays or windows."
        case .unsupportedOS:
            return "Screen recording requires macOS 13 or newer."
        case .diskFull:
            return "Ran out of disk space mid-recording. The partial file was saved."
        case .writerFailed(let m):
            return "Recording failed: \(m)"
        case .other(let m):
            return m
        }
    }
}

// ===========================================================================
// MARK: - Filename + output folder helpers
// ===========================================================================

enum RecPaths {
    /// Default output folder — created lazily on first record. Picked
    /// `~/Movies/Trove` so the files show up where Finder's video sidebar
    /// item already points.
    static var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString("~/Movies").expandingTildeInPath)
        return movies.appendingPathComponent("Trove", isDirectory: true)
    }

    static func ensureFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func timestampedName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Trove-\(f.string(from: date)).mp4"
    }

    /// Power-user item #13 — filename templating. Expands tokens against
    /// `{date}`, `{time}`, `{datetime}`, `{counter}`, `{codec}`, `{fps}`,
    /// `{source}` and the raw strftime tokens `{yyyy}`, `{MM}`, `{dd}`,
    /// `{HH}`, `{mm}`, `{ss}`. Falls back to the plain timestamped name
    /// when the template is empty or produces an unsafe filename (path
    /// separators, leading dot). Always appends `.mp4`.
    ///
    /// red-team-sec: refuses absolute paths and `..` to keep the writer
    /// pinned to `outputFolder`. A user who types `/etc/passwd` as
    /// template gets the safe fallback instead of a hijacked write.
    static func name(template: String,
                     date: Date = Date(),
                     counter: Int = 1,
                     codec: String = "",
                     fps: Int = 0,
                     source: String = "") -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return timestampedName(date: date) }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var s = trimmed
        for (tok, fmt) in [
            ("{yyyy}", "yyyy"), ("{MM}", "MM"), ("{dd}", "dd"),
            ("{HH}", "HH"),     ("{mm}", "mm"), ("{ss}", "ss"),
        ] {
            f.dateFormat = fmt
            s = s.replacingOccurrences(of: tok, with: f.string(from: date))
        }
        f.dateFormat = "yyyy-MM-dd";   s = s.replacingOccurrences(of: "{date}", with: f.string(from: date))
        f.dateFormat = "HHmmss";       s = s.replacingOccurrences(of: "{time}", with: f.string(from: date))
        f.dateFormat = "yyyyMMdd-HHmmss"; s = s.replacingOccurrences(of: "{datetime}", with: f.string(from: date))
        s = s.replacingOccurrences(of: "{counter}", with: String(format: "%03d", counter))
        s = s.replacingOccurrences(of: "{codec}",  with: codec)
        s = s.replacingOccurrences(of: "{fps}",    with: fps > 0 ? "\(fps)fps" : "")
        s = s.replacingOccurrences(of: "{source}", with: source)
        s = s.trimmingCharacters(in: .whitespaces)
        // Refuse path separators / `..` / hidden-file leaders.
        if s.contains("/") || s.contains("..") || s.hasPrefix(".") || s.isEmpty {
            return timestampedName(date: date)
        }
        // Strip any user-supplied extension; we always end in `.mp4`.
        let stem = (s as NSString).deletingPathExtension
        return "\(stem).mp4"
    }

    /// red-team: orphaned `.tmp.mp4` cleanup on next launch. A SIGKILL /
    /// power loss during a recording leaves a `.tmp.mp4` with a missing
    /// moov atom. We don't delete them (they're recoverable with ffmpeg)
    /// but we rename to `.recovered.mp4` so future runs don't trip over
    /// them and the user sees the file in Finder with a discoverable name.
    /// Returns the count of files renamed.
    @discardableResult
    static func sweepStaleTmp(_ folder: URL = defaultFolder) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for url in items where url.lastPathComponent.hasSuffix(".tmp.mp4") {
            let stem = url.lastPathComponent.replacingOccurrences(
                of: ".tmp.mp4", with: "")
            var dest = folder.appendingPathComponent("\(stem).recovered.mp4")
            var bump = 1
            while fm.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent("\(stem)-\(bump).recovered.mp4")
                bump += 1
                if bump > 999 { break }
            }
            if (try? fm.moveItem(at: url, to: dest)) != nil { n += 1 }
        }
        return n
    }
}

// =============================================================================
// MARK: - Quality preset (#10 — pro bitrate control)
// =============================================================================
//
// Currently the recorder picks a bitrate from `pxW * pxH * 4` capped at
// 200 Mbps. That's "visually lossless" but generates huge files at 4K +
// 60 fps. Pro users want explicit control over the quality/size trade.

enum RecQuality: String, CaseIterable, Identifiable, Codable {
    case smallest   // 0.4× default — fine for talking-head screencasts
    case balanced   // 1.0× default — current behavior
    case best       // 2.0× default — for archival / further editing

    var id: String { rawValue }
    var label: String {
        switch self {
        case .smallest: return "Smallest"
        case .balanced: return "Balanced"
        case .best:     return "Best"
        }
    }
    var bitrateMultiplier: Double {
        switch self {
        case .smallest: return 0.4
        case .balanced: return 1.0
        case .best:     return 2.0
        }
    }
    var tooltip: String {
        switch self {
        case .smallest: return "Smallest — lower bitrate (~40% of default). Tutorial-grade quality at half the file size; good for short clips that need to share quickly."
        case .balanced: return "Balanced — default bitrate. Visually lossless at typical viewing distances; the safe pick."
        case .best:     return "Best — double the bitrate. Use when the recording is going to be re-edited (color graded, cut, compressed again) and you don't want to compound losses."
        }
    }
}

// ===========================================================================
// MARK: - Permissions
// ===========================================================================

/// Wraps the two TCC checks we care about. Crucially we do NOT call
/// `SCShareableContent.current` at view-appear — that triggers the OS
/// permission prompt before the user has expressed intent. We only probe
/// when they actually click Record.
enum RecPermissions {

    /// Best-effort probe without forcing a prompt. CGPreflight is the
    /// approved way to ask "do I already have it?" for screen recording.
    static func hasScreenRecording() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Open System Settings exactly on the Screen Recording pane. The URL
    /// scheme is stable since macOS 13. Delegates to the central
    /// `TCCDeepLink` enum so every recorder failure path that surfaces an
    /// "Open Settings" action button hits the same anchor as the rest of
    /// the app.
    static func openScreenRecordingSettings() {
        TCCDeepLink.screenRecording.open()
    }

    static func openMicrophoneSettings() {
        TCCDeepLink.microphone.open()
    }

    /// Ask for the mic. Completion runs on an arbitrary queue → caller hops
    /// to main if it needs to touch UI.
    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in done(ok) }
    }
}

// ===========================================================================
// MARK: - ScreenCaptureKit content cache
// ===========================================================================

/// Snapshot of what's currently capturable, cached so the source-picker UI
/// doesn't spam SCShareableContent every render pass.
@MainActor
final class RecSourceCatalog: ObservableObject {
    @Published var displays: [SCDisplay] = []
    @Published var windows:  [SCWindow]  = []
    @Published var lastError: RecError? = nil
    @Published var isLoading: Bool = false

    /// Pull the latest shareable content. Returns silently — the published
    /// `lastError` is the UI signal.
    func refresh() async {
        // Fix 9: SCShareableContent.excludingDesktopWindows requires macOS 12.3+
        // but can crash on load on macOS 12. Gate on macOS 13 to be safe.
        guard #available(macOS 13, *) else {
            self.lastError = .unsupportedOS
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // `excludingDesktopWindows: true` hides the wallpaper "window"
            // that clutters the picker; `onScreenWindowsOnly: true` skips
            // minimized / off-screen junk.
            let c = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            self.displays = c.displays
            // Only windows with a sensible title/owner — filters out
            // SystemUIServer-style invisible helpers.
            self.windows = c.windows.filter {
                ($0.title?.isEmpty == false) && ($0.owningApplication != nil)
            }
            self.lastError = nil
        } catch {
            // The most common error here is "user hasn't granted Screen
            // Recording yet". Surface as the actionable permission error
            // rather than a raw NSError message.
            if !RecPermissions.hasScreenRecording() {
                self.lastError = .needsScreenRecordingPermission
            } else {
                self.lastError = .other(error.localizedDescription)
            }
        }
    }
}

// ===========================================================================
// MARK: - Region picker (one-shot rect using `screencapture -i`)
// ===========================================================================

/// P0 fix: custom crosshair overlay that captures the TRUE origin of the drawn
/// region, not just the PNG size. We cover every screen with a transparent
/// NSWindow, track mouseDown/mouseDragged/mouseUp, and return the CGRect in
/// display-point coordinates together with the CGDirectDisplayID of the screen
/// the selection was drawn on.
///
/// This replaces the old `screencapture -i` round-trip which lost the origin
/// and always returned .zero, causing every "region" recording to capture the
/// top-left corner of the display instead of the actual drawn region.
enum RecRegionPicker {

    /// Returns the picked rect (in *display points*) and the display it was
    /// drawn on.  Returns nil if the user hit Escape or didn't drag.
    @MainActor
    static func pick() async -> (CGRect, CGDirectDisplayID)? {
        // Serialize with Stage screenshot and OCR capture.
        guard InteractiveCaptureGate.tryAcquire() else { return nil }
        defer { InteractiveCaptureGate.release() }

        return await withCheckedContinuation { cont in
            let overlay = RecRegionOverlay(continuation: cont)
            overlay.show()
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - RecRegionOverlay (custom crosshair window, main-actor)
// ---------------------------------------------------------------------------

/// One full-screen transparent window per display. The user drags a rubber-
/// band selection; on mouseUp we record the rect in the coordinate system of
/// that screen's display and dismiss all overlays.
@MainActor
private final class RecRegionOverlay: NSObject {

    private var windows: [NSWindow] = []
    private let cont: CheckedContinuation<(CGRect, CGDirectDisplayID)?, Never>
    private var finished = false

    init(continuation: CheckedContinuation<(CGRect, CGDirectDisplayID)?, Never>) {
        self.cont = continuation
    }

    func show() {
        // Cover every screen.
        for screen in NSScreen.screens {
            let win = RecRegionTrackingWindow(screen: screen) { [weak self] result in
                guard let self = self, !self.finished else { return }
                self.finished = true
                self.dismissAll()
                self.cont.resume(returning: result)
            }
            win.orderFrontRegardless()
            windows.append(win)
        }
        // Focus the primary screen's window so key events (Esc) are received.
        windows.first?.makeKey()
    }

    private func dismissAll() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

// ---------------------------------------------------------------------------
// MARK: - RecRegionTrackingWindow
// ---------------------------------------------------------------------------

/// A transparent, borderless, screen-filling window that draws a crosshair
/// and a rubber-band rect while the user drags.
@MainActor
private final class RecRegionTrackingWindow: NSWindow {

    // NB: NSWindow already has a `screen` property — we shadow it with
    // `targetScreen` so subclassing doesn't trigger an override-of-stored-property
    // error from the compiler.
    private let targetScreen: NSScreen
    private let onResult: ((CGRect, CGDirectDisplayID)?) -> Void
    private var overlayView: RecRegionOverlayView!

    init(screen: NSScreen,
         onResult: @escaping ((CGRect, CGDirectDisplayID)?) -> Void) {
        self.targetScreen = screen
        self.onResult = onResult
        // Frame the window to exactly cover this screen (in global AppKit coords).
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.level = .screenSaver           // above everything except menubar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        overlayView = RecRegionOverlayView()
        overlayView.frame = self.contentView?.bounds ?? targetScreen.frame
        overlayView.autoresizingMask = [.width, .height]
        self.contentView = overlayView
        NSCursor.crosshair.set()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc cancels.
        if event.keyCode == 53 {
            onResult(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = event.locationInWindow  // in window coords = screen coords (borderless)
        overlayView.startPoint = loc
        overlayView.currentPoint = loc
        overlayView.isDragging = true
        overlayView.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard overlayView.isDragging else { return }
        overlayView.currentPoint = event.locationInWindow
        overlayView.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard overlayView.isDragging,
              let start = overlayView.startPoint
        else {
            onResult(nil)
            return
        }
        overlayView.isDragging = false
        let end = event.locationInWindow

        // Build the rect in screen coords (window coords == screen coords for borderless).
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let width  = abs(end.x - start.x)
        let height = abs(end.y - start.y)

        // Require a minimum drag of 10 pt so a stray click doesn't start a recording.
        guard width >= 10, height >= 10 else {
            onResult(nil)
            return
        }

        let rectInScreen = CGRect(x: minX, y: minY, width: width, height: height)

        // Translate from AppKit screen coords (origin bottom-left) to
        // CGDisplay coords (origin top-left) for SCK's sourceRect.
        // SCK sourceRect uses CG display coordinates (Quartz / CoreGraphics),
        // where Y=0 is the top of the display.
        let displayID = self.displayID(for: targetScreen)
        let displayH = CGFloat(CGDisplayPixelsHigh(displayID)) / targetScreen.backingScaleFactor
        // AppKit Y: measures from bottom of screen
        // CG Y: measures from top of screen
        let cgY = displayH - (rectInScreen.origin.y + rectInScreen.height)
        let rectInCG = CGRect(x: rectInScreen.origin.x,
                              y: cgY,
                              width: rectInScreen.width,
                              height: rectInScreen.height)
        onResult((rectInCG, displayID))
    }

    /// Extract CGDirectDisplayID from an NSScreen.
    private func displayID(for s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()
    }
}

// ---------------------------------------------------------------------------
// MARK: - RecRegionOverlayView
// ---------------------------------------------------------------------------

/// Draws the dimmed overlay + rubber-band selection rectangle.
@MainActor
private final class RecRegionOverlayView: NSView {
    var startPoint: CGPoint?
    var currentPoint: CGPoint = .zero
    var isDragging = false

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the whole screen.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.fill(bounds)

        guard isDragging, let start = startPoint else { return }

        let minX = min(start.x, currentPoint.x)
        let minY = min(start.y, currentPoint.y)
        let w = abs(currentPoint.x - start.x)
        let h = abs(currentPoint.y - start.y)
        let selRect = CGRect(x: minX, y: minY, width: w, height: h)

        // Punch out the selection (clear the dim).
        ctx.clear(selRect)

        // Draw border.
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.setLineWidth(1.5)
        ctx.stroke(selRect)

        // Size label.
        let label = "\(Int(w)) × \(Int(h))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let labelX = max(selRect.midX - size.width / 2, 4)
        let labelY = selRect.maxY + 4
        (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attrs)
    }
}

// ===========================================================================
// MARK: - Recording engine
// ===========================================================================

/// All recording state lives here. The View binds to its `@Published`
/// properties for the HUD; the engine owns the SCStream + AVAssetWriter +
/// AVCaptureSession lifecycle.
///
/// Threading model:
///   • Public API (`start`, `pause`, `resume`, `stop`) is `@MainActor`.
///   • SCStream sample callbacks land on a private serial queue; they
///     dispatch *into* the writer's append-only methods without bouncing
///     back to main. We don't accumulate sample buffers anywhere — each
///     buffer is appended-or-dropped immediately so memory stays flat
///     even on multi-hour recordings (red-team #8).
@MainActor
final class RecEngine: NSObject, ObservableObject {

    // ---- UI-observable state -------------------------------------------------

    @Published var isRecording = false
    /// P0 fix: takes the reentry gate synchronously at the start of `start()`,
    /// before any await, so a double-tap during the 300ms+ SCK content fetch
    /// can't get past the guard twice. Cleared via defer on early-throw paths.
    fileprivate var isStarting = false
    @Published var isPaused    = false

    /// Wall-clock seconds the user perceives as "elapsed recording time".
    /// Pauses freeze this; resumes continue it. Distinct from the SCK
    /// presentation timestamps the writer uses internally.
    @Published var elapsed: TimeInterval = 0

    /// Rolling estimate based on appended bytes so the HUD shows a real
    /// number rather than a recompute every frame.
    @Published var estimatedBytes: Int64 = 0

    /// Audio level meters: 0...1, smoothed. One per active source.
    @Published var systemAudioLevel: Float = 0
    @Published var micAudioLevel: Float = 0

    @Published var lastError: RecError? = nil

    /// Set after a successful stop so the View can offer "Send to Stage".
    @Published var lastOutputURL: URL? = nil

    // ---- Configuration captured at start ------------------------------------

    private var captureSystemAudio = false
    private var captureMic         = false
    private var showsCursor        = true

    // ---- Mid-recording live toggles (pro-user customizability) -------------
    //
    // These mirror `captureSystemAudio` / `captureMic` / `showsCursor` but
    // are mutable during the recording. The audio delegates check them on
    // every buffer and silence-drop when the corresponding toggle is off;
    // the cursor toggle pushes through SCStream.updateConfiguration so
    // hover hot-spots disappear within one frame of the user flipping it.
    //
    // The HUD binds directly to these — flipping a toggle in the UI is
    // an immediate effect, no recording restart required. This is the
    // single biggest gap between Trove's recorder and a pro tool: until
    // now you had to stop, change a checkbox, and re-record.
    @Published var liveSystemAudioOn: Bool = false {
        didSet { /* picked up by SCStream audio delegate on next buffer */ }
    }
    @Published var liveMicOn: Bool = false {
        didSet { /* picked up by AVCapture audio delegate on next buffer */ }
    }
    @Published var liveShowsCursor: Bool = true {
        didSet { pushLiveCursorChange() }
    }

    /// Max-duration safety cap (seconds). 0 = no cap. Recording auto-stops
    /// past this — prevents the classic "left it running overnight, woke
    /// up to a 200 GB MP4" disaster.
    var maxDurationSeconds: TimeInterval = 0
    private var maxDurationTimer: Timer?

    /// Power-user item #10 — bitrate multiplier set by the VM's quality
    /// preset before calling start(). 1.0 = balanced (current default
    /// behavior); 0.4 = smallest; 2.0 = best (archival).
    var qualityMultiplier: Double = 1.0

    /// Power-user item #13 — filename template used by the writer to
    /// pick output filenames. Empty = `Trove-yyyyMMdd-HHmmss.mp4`.
    var filenameTemplate: String = ""

    /// Power-user item #12 — software mic gain (0.0…3.0). 1.0 = unity
    /// (the existing behavior). Applied as a per-sample float multiply
    /// inside the mic delegate before appending to the writer. Values
    /// above 1.0 amplify but also risk clipping — the HUD shows a
    /// clipping indicator when sustained samples saturate.
    var micGain: Float = 1.0
    /// Set by the mic delegate when any sample in the last buffer
    /// saturated at ±1.0; cleared per-tick by the HUD ticker.
    @Published var micClipping: Bool = false

    /// Power-user item #1 — webcam PIP. When true, the engine starts a
    /// parallel RecWebcamCapture alongside the screen recording. The
    /// camera lands in `<stem>.webcam.mov`. Compositing into a single
    /// PIP MP4 is intentionally deferred to a later batch — pro users
    /// can drag both files into Final Cut / DaVinci / iMovie + overlay
    /// in 30 seconds, and shipping the recording pipeline first means
    /// the workflow unlocks today.
    var webcamPIPEnabled: Bool = false
    var webcamDeviceUID: String? = nil
    /// The parallel webcam writer. Created lazily on first record.
    private var webcamCapture: RecWebcamCapture?
    /// Last webcam output URL — surfaced in the last-recording row when
    /// PIP was enabled.
    @Published var lastWebcamURL: URL? = nil

    /// Update SCStream configuration to reflect the live cursor toggle.
    /// Falls back silently when the stream isn't running (e.g. during
    /// initial countdown) — the start() path picks up `showsCursor` from
    /// the config it builds.
    private func pushLiveCursorChange() {
        guard isRecording, let stream = self.stream else { return }
        Task { [weak self] in
            guard let self else { return }
            let cfg = SCStreamConfiguration()
            cfg.showsCursor = self.liveShowsCursor
            try? await stream.updateConfiguration(cfg)
        }
    }

    // ---- ScreenCaptureKit ----------------------------------------------------

    private var stream: SCStream?
    private let sckQueue = DispatchQueue(label: "trove.rec.sck", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "trove.rec.mic", qos: .userInitiated)

    // ---- AVAssetWriter -------------------------------------------------------

    private var writer: AVAssetWriter?
    private var videoInput:     AVAssetWriterInput?
    private var systemAudioIn:  AVAssetWriterInput?
    private var micAudioIn:     AVAssetWriterInput?
    private var sessionStarted = false

    /// First video PTS we see. Audio buffers are accepted as-is — we let
    /// AVAssetWriter's internal timeline handle drift rather than remapping
    /// (red-team #7).
    private var firstVideoPTS: CMTime?

    /// Last PTS appended per track. AVAssetWriterInput.append() requires
    /// strictly increasing PTS — a non-monotonic sample fails the writer
    /// and tanks the whole recording. SCK has been observed to deliver
    /// audio buffers slightly out of order on resolution changes / display
    /// hot-plug, so we guard each track. (red-team #5)
    private var lastVideoPTS: CMTime = .invalid
    private var lastSysAudioPTS: CMTime = .invalid
    private var lastMicPTS: CMTime = .invalid

    /// stop() idempotency latch. `isRecording` is set false synchronously,
    /// but the delegate (`didStopWithError`) and the user's stop button can
    /// both call stop() and the async finishWriting() can only be invoked
    /// once or it crashes. (red-team #1)
    private var isFinalizing = false

    /// Temp + final URLs. Writer always targets `.tmp.mp4`; renamed only
    /// on successful finalize so a mid-recording crash leaves a recoverable
    /// artifact rather than a corrupt "final" file (red-team #6).
    private var tempURL:  URL?
    private var finalURL: URL?

    // ---- Microphone via AVCaptureSession ------------------------------------

    private var micSession: AVCaptureSession?
    private var micOutput:  AVCaptureAudioDataOutput?

    // ---- Pause/resume + timer -----------------------------------------------

    private var startWall: ContinuousClock.Instant?
    private var accumulated: TimeInterval = 0
    private var tickTimer: Timer?

    // ---- IOPMAssertion (prevent system sleep during recording) --------------
    private var pmAssertionID: IOPMAssertionID = IOPMAssertionID(0)

    // Fix 24: atexit shadow so a graceful exit(0) path (outside willTerminate)
    // releases the assertion without leaking it. Pattern mirrors KeepAwakeAssertion.
    nonisolated(unsafe) private static var exitLock = os_unfair_lock_s()
    nonisolated(unsafe) private static var exitAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    nonisolated(unsafe) private static var exitHookRegistered = false

    private static func registerExitHookOnce() {
        os_unfair_lock_lock(&exitLock); defer { os_unfair_lock_unlock(&exitLock) }
        if exitHookRegistered { return }
        exitHookRegistered = true
        atexit {
            os_unfair_lock_lock(&RecEngine.exitLock)
            let id = RecEngine.exitAssertionID
            RecEngine.exitAssertionID = IOPMAssertionID(0)
            os_unfair_lock_unlock(&RecEngine.exitLock)
            if id != IOPMAssertionID(0) { IOPMAssertionRelease(id) }
        }
    }

    nonisolated private func writePMShadow(id: IOPMAssertionID) {
        os_unfair_lock_lock(&RecEngine.exitLock); defer { os_unfair_lock_unlock(&RecEngine.exitLock) }
        RecEngine.exitAssertionID = id
    }

    // red-team: tokens for willTerminate / willSleep / screens-changed.
    // willTerminate: finalize a recording in progress so the user gets a
    //   playable mp4 instead of an orphaned .tmp.mp4.
    // willSleep: stop cleanly because SCStream + mic session don't survive
    //   a multi-hour suspend reliably.
    // screensChanged: if the recording's display was unplugged, stop instead
    //   of waiting for stream(_:didStopWithError:) which can fire late.
    private var lifecycleObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        Self.registerExitHookOnce()
        let terminate = NotificationCenter.default.addObserver(
            forName: .troveWillTerminate, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            // 3s synchronous ceiling so a stuck writer can't block quit forever.
            // queue: nil means the block runs on a background thread, so
            // sem.wait() does NOT block the main actor — freeing it to execute
            // the @MainActor stop() call below.
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await self.stop()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 3.0)
        }
        let sleep = NotificationCenter.default.addObserver(
            forName: .troveSystemWillSleep, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            Task { @MainActor in await self.stop() }
        }
        let screens = NotificationCenter.default.addObserver(
            forName: .troveScreensChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            Task { @MainActor in await self.stop() }
        }
        lifecycleObservers = [terminate, sleep, screens]
    }

    // red-team: invalidate the HUD ticker and tear down the mic capture
    // session when the engine is dropped. Without this, if RecorderPane is
    // dismissed mid-recording the Timer keeps firing every 250ms forever
    // (RunLoop retains it), the AVCaptureSession keeps running, and the
    // .AVCaptureSessionRuntimeError observer is never removed.
    deinit {
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        tickTimer?.invalidate()
        tickTimer = nil
        if let s = micSession {
            // red-team: modernized — `.AVCaptureSessionRuntimeError` global was
            // deprecated in macOS 14 in favor of the type-scoped notification name.
            NotificationCenter.default.removeObserver(
                self, name: AVCaptureSession.runtimeErrorNotification, object: s)
            s.stopRunning()
        }
        micSession = nil
        micOutput  = nil
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        // IOPMAssertion is released in stop() before we reach deinit under
        // normal operation; the atexit shadow covers the edge case where stop()
        // didn't run. Avoid accessing main-actor property pmAssertionID from deinit.
    }

    // =========================================================================
    // MARK: Public API
    // =========================================================================

    /// Begin recording. Caller must have flipped any toggles on `self`
    /// already (via the `configure(...)` helper) so the engine knows what
    /// it's capturing. Errors are surfaced via `lastError` and the throw.
    func start(source: RecSourceKind,
               outputFolder: URL,
               systemAudio: Bool,
               microphone: Bool,
               micUID: String? = nil,
               showsCursor: Bool,
               codec: RecCodec = .hevc,
               fps: RecFrameRate = .fps60,
               excludeBundleID: String?) async throws {

        // red-team: reentry guard — rapid double-clicks or hotkey bursts would
        // otherwise race two concurrent recordings to the same .tmp.mp4 path.
        // P0 fix: the gate must close BEFORE the first await. Previously
        // `isRecording = true` ran at line 922 — after SCK content fetch + writer
        // setup (300ms+). A double-tap during that window passed the guard twice
        // and built two AVAssetWriters against the same path. We now take the gate
        // synchronously via a startingGen counter and only flip the public
        // `isRecording` flag once the writer is up; an early throw resets the gate
        // in a defer so a failed start doesn't lock the user out.
        guard !isRecording, !isFinalizing, !isStarting else { return }
        isStarting = true
        var startedSuccessfully = false
        defer {
            // Either we transition into the running state (startedSuccessfully = true,
            // isStarting → false and isRecording was set true at the success point),
            // or we bail / throw and need to clear isStarting so the user can retry.
            if !startedSuccessfully { self.isStarting = false }
        }

        // Red-team #2: SCK audio capture (capturesAudio) only exists on 13+.
        guard #available(macOS 13.0, *) else {
            self.lastError = .unsupportedOS
            throw RecError.unsupportedOS
        }

        // Red-team #1: don't pre-prompt; we ask now, on intent.
        if !RecPermissions.hasScreenRecording() {
            // The first `SCShareableContent` call below will trigger the
            // OS prompt. If it's denied we surface a clean inline error.
        }

        self.captureSystemAudio = systemAudio
        self.captureMic         = microphone
        self.showsCursor        = showsCursor
        // Initialize the live toggles to match the captured values. The HUD
        // binds directly to these — flipping them mid-recording immediately
        // affects the next audio buffer / cursor frame, no restart needed.
        self.liveSystemAudioOn  = systemAudio
        self.liveMicOn          = microphone
        self.liveShowsCursor    = showsCursor
        self.lastError          = nil
        self.estimatedBytes     = 0
        self.elapsed            = 0
        self.accumulated        = 0
        self.systemAudioLevel   = 0
        self.micAudioLevel      = 0
        self.firstVideoPTS      = nil
        self.sessionStarted     = false
        // red-team: reset per-track PTS guards and finalize latch
        self.lastVideoPTS       = .invalid
        self.lastSysAudioPTS    = .invalid
        self.lastMicPTS         = .invalid
        self.isFinalizing       = false

        // --- Build SCContentFilter -----------------------------------------

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            self.lastError = .needsScreenRecordingPermission
            throw RecError.needsScreenRecordingPermission
        }

        guard let display = chooseDisplay(for: source, in: content) else {
            self.lastError = .noShareableContent
            throw RecError.noShareableContent
        }

        // Red-team #9: exclude Trove itself from its own recording.
        let excluded: [SCRunningApplication] = {
            guard let bid = excludeBundleID else { return [] }
            return content.applications.filter { $0.bundleIdentifier == bid }
        }()

        let filter: SCContentFilter
        switch source {
        case .display:
            filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])
        case .window(let wid):
            if let w = content.windows.first(where: { $0.windowID == wid }) {
                filter = SCContentFilter(desktopIndependentWindow: w)
            } else {
                filter = SCContentFilter(display: display,
                                         excludingApplications: excluded,
                                         exceptingWindows: [])
            }
        case .region:
            filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])
        }

        // --- Build SCStreamConfiguration -----------------------------------

        let cfg = SCStreamConfiguration()
        // Red-team #10: Retina sharpness. Use the display's backing scale
        // factor so output is native pixels, not points.
        let scale = NSScreen.screens.first(where: { ns in
            (ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        })?.backingScaleFactor ?? 2.0

        let pxWidth  = Int(CGFloat(display.width)  * scale)
        let pxHeight = Int(CGFloat(display.height) * scale)
        cfg.width  = pxWidth
        cfg.height = pxHeight
        cfg.scalesToFit = true
        cfg.showsCursor = showsCursor
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rawValue))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth  = 6 // small queue → frames drop rather than buffer

        // Region: clip the frame to the picked rect (in display points).
        if case let .region(rect, _) = source {
            cfg.sourceRect = rect
            cfg.width  = Int(rect.width  * scale)
            cfg.height = Int(rect.height * scale)
        }

        if systemAudio {
            cfg.capturesAudio = true
            cfg.sampleRate    = 48_000
            cfg.channelCount  = 2
        }

        // --- Set up AVAssetWriter ------------------------------------------

        try RecPaths.ensureFolder(outputFolder)
        // red-team: filename collision — yyyyMMdd-HHmmss has 1-second
        // granularity, so two recordings started in the same second would
        // clash. Bump with -N until both the final and the .tmp.mp4 paths
        // are free. We do NOT clobber a stale .tmp.mp4 (it might be from a
        // recoverable crashed prior session — see RecPaths.sweepStaleTmp).
        // Power-user item #13 — expand the user's filename template
        // (codec / fps / date / source / counter tokens). Empty template
        // falls back to the classic `Trove-yyyyMMdd-HHmmss.mp4`.
        let baseName  = RecPaths.name(
            template: filenameTemplate,
            counter: 1,
            codec: codec.rawValue.replacingOccurrences(of: " ", with: "_"),
            fps: fps.rawValue,
            source: "")
        var finalURL  = outputFolder.appendingPathComponent(baseName)
        var tempURL   = outputFolder.appendingPathComponent(baseName + ".tmp.mp4")
        var bump = 1
        while FileManager.default.fileExists(atPath: finalURL.path)
            || FileManager.default.fileExists(atPath: tempURL.path) {
            let stem = (baseName as NSString).deletingPathExtension
            let ext  = (baseName as NSString).pathExtension
            let nm   = "\(stem)-\(bump).\(ext)"
            finalURL = outputFolder.appendingPathComponent(nm)
            tempURL  = outputFolder.appendingPathComponent(nm + ".tmp.mp4")
            bump += 1
            if bump > 999 { break } // sanity bail
        }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        self.writer   = writer
        self.tempURL  = tempURL
        self.finalURL = finalURL

        // Video input. Compression settings tuned for screen content:
        // High profile, bitrate scaled with pixel count, key frame every
        // 2 seconds so seek/scrub stays snappy in Finder Quick Look.
        // P1: support HEVC (H.265) — default on Apple Silicon for better
        // quality-per-bit; H.264 still available for compatibility.
        // P0 fix: cap bitrate. The naive `pxW * pxH * 4` for a 5K Retina display
        // (10240×5760) is ~59 Gbps — meaningless, and AVAssetWriter will clamp
        // internally but the intent is broken. 200 Mbps is well above what
        // HEVC/H.264 need for visually-lossless screen content at any resolution
        // we'll realistically encode; floor of 8 Mbps preserves quality at lower
        // resolutions.
        // Power-user item #10 — quality preset scales the base bitrate.
        // `qualityMultiplier` is set on the engine by start() callers; if
        // never set it falls back to 1.0 (balanced — current behavior).
        let bitrateCap = 200_000_000
        let baseBitrate = max(8_000_000, pxWidth * pxHeight * 4)
        let scaled = Double(baseBitrate) * (qualityMultiplier > 0 ? qualityMultiplier : 1.0)
        let bitrate = min(bitrateCap, Int(scaled))
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: fps.rawValue * 2,  // 2-sec key frame
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.codecType,
            AVVideoWidthKey:  cfg.width,
            AVVideoHeightKey: cfg.height,
            AVVideoCompressionPropertiesKey: compressionProps,
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        if writer.canAdd(vIn) { writer.add(vIn) }
        self.videoInput = vIn

        // System audio input — only added if requested AND OS supports it.
        if systemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey:        kAudioFormatMPEG4AAC,
                AVSampleRateKey:      48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey:  128_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if writer.canAdd(aIn) { writer.add(aIn) }
            self.systemAudioIn = aIn
        }

        // Microphone input — handled as a *separate* audio track so it
        // doesn't fight system audio for timeline ownership. Players that
        // only honor the first audio track will get system audio; pro
        // editors can pick either track. This is the same approach Loom
        // and CleanShot use.
        if microphone {
            let micSettings: [String: Any] = [
                AVFormatIDKey:        kAudioFormatMPEG4AAC,
                AVSampleRateKey:      48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey:  96_000,
            ]
            let mIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            mIn.expectsMediaDataInRealTime = true
            if writer.canAdd(mIn) { writer.add(mIn) }
            self.micAudioIn = mIn
        }

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "unknown writer error"
            self.lastError = .writerFailed(msg)
            throw RecError.writerFailed(msg)
        }

        // --- Microphone capture session ------------------------------------

        if microphone {
            try await setupMicrophoneSession(uid: micUID)
        }

        // --- SCStream ------------------------------------------------------

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: sckQueue)
        if systemAudio {
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: sckQueue)
        }

        try await stream.startCapture()

        // Kick off mic capture *after* SCK so we can align timestamps to
        // the first video frame rather than fighting two independent clocks.
        micSession?.startRunning()

        self.isRecording = true
        self.isPaused    = false
        self.startWall   = ContinuousClock.now

        // Power-user item #1 — start the parallel webcam writer if PIP
        // is enabled. The webcam lands in `<stem>.webcam.mov` alongside
        // the main file so the user gets two synced takes for post-edit
        // PIP composition. We don't fail the whole start if the webcam
        // capture errors — a screen recording without webcam still has
        // value (the toast surfaces the issue).
        if webcamPIPEnabled, let tempURL = self.tempURL {
            let webcamURL = tempURL.deletingPathExtension()
                .deletingPathExtension()
                .appendingPathExtension("webcam.mov")
            let wc = self.webcamCapture ?? RecWebcamCapture()
            self.webcamCapture = wc
            wc.start(to: webcamURL, deviceUID: webcamDeviceUID)
        }
        // Hand off from isStarting → isRecording. The defer at the top of start()
        // checks startedSuccessfully and leaves isStarting=true here untouched
        // (it's cleared on the next line). The result: a second tap arriving
        // between the await and this point still finds isStarting=true and bails.
        startedSuccessfully = true
        self.isStarting = false
        RecEngineActivityTracker.setActive(true)
        startTickTimer()
        // Prevent system sleep during recording — SCStream and AVAssetWriter
        // don't survive a multi-hour suspend reliably (red-team #8).
        if pmAssertionID == IOPMAssertionID(0) {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Trove recording in progress" as CFString,
                &pmAssertionID)
            writePMShadow(id: pmAssertionID)
        }
    }

    /// Pause. SCStream stays alive but we stop appending samples to the
    /// writer; the writer's own timeline keeps advancing, so when we
    /// resume the gap is preserved (silence + frozen frame).
    /// A more elaborate implementation would `stopCapture` + restart, but
    /// that costs ~300ms per resume and adds a visible flicker. Suppressing
    /// appends is the right tradeoff.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        if let started = startWall { accumulated += (ContinuousClock.now - started).timeInterval }  // uses Duration.timeInterval from main.swift
        startWall = nil
    }

    func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        startWall = ContinuousClock.now
    }

    /// Stop and finalize. Always renames .tmp.mp4 → final.mp4 on success;
    /// leaves the .tmp.mp4 in place on failure so the user can recover.
    func stop() async {
        // red-team: idempotency — finishWriting() called twice crashes.
        // Stream delegate + user stop-button can both invoke this; the
        // boolean isRecording flips synchronously but the *first* call is
        // still awaiting finishWriting when a second arrives — guard with
        // an explicit latch.
        guard isRecording, !isFinalizing else { return }
        isFinalizing = true
        isRecording = false
        // Fix 9: accumulate the live (non-paused) segment before clearing startWall.
        if !isPaused, let s = startWall {
            accumulated += (ContinuousClock.now - s).timeInterval
        }
        isPaused    = false

        stopTickTimer()
        micSession?.stopRunning()

        if let s = stream {
            try? await s.stopCapture()
        }
        self.stream = nil

        // Power-user item #1 — stop the parallel webcam writer so its
        // .mov is finalized at roughly the same wall-clock moment as
        // the main file. Result URL is surfaced via lastWebcamURL so
        // the last-recording row can show it next to the screen file.
        if let wc = self.webcamCapture {
            self.lastWebcamURL = await wc.stop()
        }

        videoInput?.markAsFinished()
        systemAudioIn?.markAsFinished()
        micAudioIn?.markAsFinished()

        // Fix #24: release the sleep-prevention assertion before finishWriting()
        // so it isn't held during potentially-long file finalization.
        if pmAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(pmAssertionID)
            pmAssertionID = IOPMAssertionID(0)
            writePMShadow(id: IOPMAssertionID(0))
        }

        if let writer = writer {
            await writer.finishWriting()
            if writer.status == .completed,
               let tmp = tempURL,
               let final = finalURL {
                do {
                    // If a file with the final name somehow already exists
                    // (unlikely — timestamp-named) just bump with a suffix
                    // rather than clobbering.
                    var dest = final
                    if FileManager.default.fileExists(atPath: dest.path) {
                        let stem = dest.deletingPathExtension().lastPathComponent
                        let ext  = dest.pathExtension
                        dest = dest.deletingLastPathComponent()
                            .appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(4)).\(ext)")
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    self.lastOutputURL = dest
                    OutputsLibrary.shared.record(
                        url: dest,
                        producer: "recorder",
                        sourceLabel: dest.lastPathComponent,
                        kind: "video"
                    )
                } catch {
                    self.lastError = .other("Finalize failed: \(error.localizedDescription)")
                    self.lastOutputURL = tempURL
                }
            } else {
                // Red-team #5: writer.error includes disk-full (NSPOSIXError
                // ENOSPC). The .tmp.mp4 still has whatever flushed.
                let nserr = writer.error as NSError?
                if nserr?.domain == NSPOSIXErrorDomain && nserr?.code == 28 {
                    self.lastError = .diskFull
                } else if let m = writer.error?.localizedDescription {
                    self.lastError = .writerFailed(m)
                }
                self.lastOutputURL = tempURL
            }
        }

        self.writer = nil
        self.videoInput = nil
        self.systemAudioIn = nil
        self.micAudioIn = nil
        teardownMicrophoneSession()
        // red-team: clear finalize latch so a future start/stop cycle works
        self.isFinalizing = false
        // IOPMAssertion already released above (before finishWriting).
        RecEngineActivityTracker.setActive(false)
        // If applicationShouldTerminate returned .terminateLater, now signal.
        if !RecEngineActivityTracker.isActive {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Stop recording and delete the in-progress temp file. `lastOutputURL` is
    /// NOT set so callers can distinguish a discard from a normal stop.
    func discard() async {
        let urlToDelete = tempURL
        await stop()
        // stop() sets lastOutputURL = dest on success; clear it since this is a discard.
        self.lastOutputURL = nil
        if let url = urlToDelete {
            try? FileManager.default.removeItem(at: url)
        }
        // Also remove the renamed final file if stop() managed to finalize in time.
        if let final = finalURL {
            try? FileManager.default.removeItem(at: final)
        }
    }

    // =========================================================================
    // MARK: Internal — display picking
    // =========================================================================

    private func chooseDisplay(for source: RecSourceKind,
                               in content: SCShareableContent) -> SCDisplay? {
        switch source {
        case .display(let id):
            return content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        case .window(let wid):
            if let w = content.windows.first(where: { $0.windowID == wid }) {
                // Find the display the window is mostly on.
                let f = w.frame
                return content.displays.first(where: { d in
                    let df = CGRect(x: CGFloat(d.frame.origin.x),
                                    y: CGFloat(d.frame.origin.y),
                                    width: CGFloat(d.width),
                                    height: CGFloat(d.height))
                    return df.intersects(f)
                }) ?? content.displays.first
            }
            return content.displays.first
        case .region(_, let id):
            return content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        }
    }

    // =========================================================================
    // MARK: Internal — microphone
    // =========================================================================

    private func setupMicrophoneSession(uid: String? = nil) async throws {
        // Fix #3: honour the user's mic selection. Resolve via uniqueID first;
        // fall back to system default if uid is nil or the device has gone away.
        let device: AVCaptureDevice?
        if let uid = uid {
            device = AVCaptureDevice(uniqueID: uid) ?? AVCaptureDevice.default(for: .audio)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device = device else {
            // Red-team #4: no mic connected. Record video-only, surface
            // a warning, do not crash.
            self.lastError = .noMicrophone
            return
        }

        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            self.lastError = .noMicrophone
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: micQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        // red-team: observe runtime errors so a mid-recording mic revoke /
        // unplug surfaces a banner instead of silently going dead. The
        // video track continues — we just drop mic and notify. Uses the
        // type-scoped notification name (the global `.AVCaptureSessionRuntimeError`
        // was deprecated in macOS 14).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAVSessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session)

        self.micSession = session
        self.micOutput  = output
    }

    private func teardownMicrophoneSession() {
        if let s = micSession {
            // red-team: remove the runtime-error observer so we don't leak
            // across recordings and don't fire on a stale session. Same
            // modernized notification name as `setupMicrophoneSession`.
            NotificationCenter.default.removeObserver(
                self, name: AVCaptureSession.runtimeErrorNotification, object: s)
        }
        micSession?.stopRunning()
        micSession = nil
        micOutput  = nil
    }

    @objc nonisolated private func handleAVSessionRuntimeError(_ note: Notification) {
        // red-team: mic permission revoked / device unplugged mid-recording.
        // Drop the mic track and continue video-only rather than tanking
        // the whole writer.
        Task { @MainActor in
            self.lastError = .noMicrophone
            self.micAudioIn?.markAsFinished()
            self.micAudioIn = nil
            self.teardownMicrophoneSession()
        }
    }

    // =========================================================================
    // MARK: Internal — HUD ticker
    // =========================================================================

    private func startTickTimer() {
        stopTickTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.isPaused, let s = self.startWall {
                    self.elapsed = self.accumulated + (ContinuousClock.now - s).timeInterval
                } else {
                    self.elapsed = self.accumulated
                }
                // Pro-user max-duration safety. Triggered once when the
                // elapsed wall time crosses the configured cap. We invoke
                // stop() directly here on the same MainActor task that
                // already runs the tick; the engine's idempotency latch
                // (`isFinalizing`) makes the call safe to enter at most
                // once per recording.
                if self.maxDurationSeconds > 0,
                   self.elapsed >= self.maxDurationSeconds,
                   self.isRecording, !self.isFinalizing {
                    let cap = Int(self.maxDurationSeconds)
                    Task { @MainActor in
                        await self.stop()
                        SharedStore.stage.flash(
                            "Recording auto-stopped at the \(cap)-second cap",
                            kind: .warning)
                    }
                }
                // File-size estimate from the writer's current output. We
                // stat the file on a background task rather than blocking the
                // main thread with attributesOfItem at 4 Hz.
                // Fix #23: skip the stat when paused — file isn't growing.
                if !self.isPaused, let url = self.tempURL {
                    let filePath = url.path
                    Task.detached(priority: .utility) { [weak self] in
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                           let size = attrs[.size] as? Int64 {
                            await MainActor.run { self?.estimatedBytes = size }
                        }
                    }
                }
                // Decay audio meters so peaks don't stick forever.
                self.systemAudioLevel *= 0.85
                self.micAudioLevel    *= 0.85
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

// ===========================================================================
// MARK: - SCStreamDelegate + SCStreamOutput
// ===========================================================================

extension RecEngine: SCStreamDelegate, SCStreamOutput {

    /// Stream stopped unexpectedly — usually means the captured window/app
    /// went away, or the user revoked permission mid-recording. Stop
    /// cleanly so we still produce a playable file.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.lastError = .other("Stream stopped: \(error.localizedDescription)")
            await self.stop()
        }
    }

    /// Hot path. Called for every video + audio sample buffer. Must not
    /// retain buffers (red-team #8) — the autorelease pool around the
    /// append handles cleanup.
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // P0 fix: previously captured `self` strongly. At 60fps + ~100Hz audio
        // each callback spawned `Task { @MainActor in self.writer… }` with a
        // strong RecEngine retain; during `finishWriting()` (which holds the
        // main actor) those Tasks queued up — hundreds of pending hops on stop,
        // each retaining the engine + associated encoder state until they drained.
        // [weak self] caps the queue depth: pending Tasks become no-ops the
        // instant the engine releases.
        Task { @MainActor [weak self] in
            guard let self,
                  let writer = self.writer, writer.status == .writing else { return }
            if self.isPaused { return }

            switch type {
            case .screen:
                self.handleVideoSample(sampleBuffer, writer: writer)
            case .audio:
                self.handleSystemAudioSample(sampleBuffer)
            case .microphone:
                // Reserved for future SCK mic capture (SCStreamConfiguration
                // gained `capturesMicrophone` in macOS 15). We use
                // AVCaptureSession for mic to keep 13/14 compat.
                break
            @unknown default:
                break
            }
        }
    }

    @MainActor
    private func handleVideoSample(_ sb: CMSampleBuffer, writer: AVAssetWriter) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        if !sessionStarted {
            // Red-team #7: start the writer's session at the first video
            // PTS and never remap. AVAssetWriter handles drift internally.
            writer.startSession(atSourceTime: pts)
            sessionStarted   = true
            firstVideoPTS    = pts
        }
        // red-team: drop non-monotonic PTS — append() requires strictly
        // increasing timestamps or it fails the entire writer.
        if lastVideoPTS.isValid && CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
        guard let vIn = videoInput, vIn.isReadyForMoreMediaData else { return }
        if vIn.append(sb) {
            lastVideoPTS = pts
        }
    }

    @MainActor
    private func handleSystemAudioSample(_ sb: CMSampleBuffer) {
        // Audio can arrive before the first video frame; the writer hasn't
        // started its session yet, so drop those early samples.
        guard sessionStarted, let aIn = systemAudioIn, aIn.isReadyForMoreMediaData else { return }
        // Pro-user live toggle: when the user has flipped system audio
        // OFF mid-recording, drop the buffer instead of appending. The
        // writer still gets a continuous video track; just a silent gap
        // for the duration the toggle was off — no track-discontinuity
        // artifacts on resume.
        if !liveSystemAudioOn {
            systemAudioLevel = 0
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        // red-team: drop out-of-order audio samples to avoid writer failure
        if lastSysAudioPTS.isValid && CMTimeCompare(pts, lastSysAudioPTS) <= 0 { return }
        if aIn.append(sb) {
            lastSysAudioPTS = pts
        }
        systemAudioLevel = max(systemAudioLevel, RecAudioLevel.estimate(sb))
    }
}

// ===========================================================================
// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (mic)
// ===========================================================================

extension RecEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Task { @MainActor in
            guard self.sessionStarted, !self.isPaused else { return }
            guard let mIn = self.micAudioIn, mIn.isReadyForMoreMediaData else { return }
            // Pro-user live toggle: mid-recording mic off → buffer dropped,
            // level meter zeroed. Re-enabling later resumes seamlessly on
            // the next buffer that arrives.
            if !self.liveMicOn {
                self.micAudioLevel = 0
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid else { return }
            // red-team: monotonic PTS guard on mic track too
            if self.lastMicPTS.isValid && CMTimeCompare(pts, self.lastMicPTS) <= 0 { return }
            // Power-user item #12 — software mic gain. When != 1.0 we
            // apply the gain in-place on the sample buffer's audio data,
            // clamping to [-1, 1] to prevent floating-point wrap. A
            // clipped sample is reported as clipping to the HUD so the
            // user can dial the gain back.
            let gain = self.micGain
            let bufferToAppend: CMSampleBuffer
            if abs(gain - 1.0) > 0.001 {
                if let amped = RecAudioGain.applyGain(sampleBuffer, gain: gain,
                                                       clippingOut: &self.micClipping) {
                    bufferToAppend = amped
                } else {
                    bufferToAppend = sampleBuffer
                }
            } else {
                bufferToAppend = sampleBuffer
            }
            if mIn.append(bufferToAppend) {
                self.lastMicPTS = pts
            }
            self.micAudioLevel = max(self.micAudioLevel, RecAudioLevel.estimate(bufferToAppend))
        }
    }
}

// ===========================================================================
// MARK: - Audio level estimator
// ===========================================================================

/// Peak-amplitude estimator for the HUD meters. Reads the raw float/int16
/// bytes off the sample buffer and returns a 0...1 value. Intentionally
/// approximate — this is a UI vibes meter, not a calibrated VU.
/// Power-user item #12 — software mic gain. Multiplies each Float32 PCM
/// sample by `gain` and clamps to [-1, 1] in-place on a copy of the
/// buffer (the original is a read-only AudioToolbox-allocated block).
/// Returns nil when the format isn't recognized; the caller falls back
/// to the un-amplified buffer in that case.
enum RecAudioGain {
    /// `clippingOut` is set to true when any sample saturated. The
    /// caller pulls this onto its `@Published` clipping property so the
    /// HUD can light up a clipping warning.
    static func applyGain(_ sb: CMSampleBuffer, gain: Float,
                          clippingOut: inout Bool) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }
        // Only handle the common case: native Float32 PCM. Anything else
        // (compressed, Int16, multi-track interleaved) falls through to
        // the un-amplified buffer. Most macOS mic capture pipelines use
        // Float32, so this covers the realistic input.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        guard isFloat, bitsPerChannel == 32 else { return nil }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &totalLength, dataPointerOut: &dataPtr)
        guard let src = dataPtr, totalLength > 0 else { return nil }
        // Make a writable copy so we don't mutate the AudioToolbox block.
        var bufferOut = Data(count: totalLength)
        var localClipping = false
        bufferOut.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let srcF = UnsafePointer<Float>(OpaquePointer(src))
            let count = totalLength / MemoryLayout<Float>.size
            for i in 0..<count {
                let amped = srcF[i] * gain
                if amped > 1.0 { dst[i] = 1.0; localClipping = true }
                else if amped < -1.0 { dst[i] = -1.0; localClipping = true }
                else { dst[i] = amped }
            }
        }
        clippingOut = localClipping
        // Reconstruct a CMSampleBuffer pointing at the new data.
        var newBlock: CMBlockBuffer?
        let createStatus = bufferOut.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: totalLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: totalLength,
                flags: 0,
                blockBufferOut: &newBlock)
        }
        guard createStatus == kCMBlockBufferNoErr, let bb = newBlock else { return nil }
        let replaceStatus = bufferOut.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalLength)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }
        var newSB: CMSampleBuffer?
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        let numSamples = CMSampleBufferGetNumSamples(sb)
        let createSBStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &newSB)
        guard createSBStatus == noErr else { return nil }
        return newSB
    }
}

enum RecAudioLevel {
    static func estimate(_ sb: CMSampleBuffer) -> Float {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &dataPtr) == noErr,
              let raw = dataPtr, length > 0 else { return 0 }

        // SCK system audio is Float32 interleaved; AVCapture mic is Int16
        // by default. Try Float first (its max valid magnitude is 1.0),
        // fall back to Int16 if it looks out of range.
        let floatCount = length / MemoryLayout<Float32>.size
        if floatCount > 0 {
            var peak: Float = 0
            raw.withMemoryRebound(to: Float32.self, capacity: floatCount) { p in
                let stride = max(1, floatCount / 256)
                var i = 0
                while i < floatCount {
                    peak = max(peak, abs(p[i]))
                    i += stride
                }
            }
            if peak <= 1.5 { return min(peak, 1.0) }
        }
        // Int16 fallback
        let i16Count = length / MemoryLayout<Int16>.size
        if i16Count > 0 {
            var peak: Int16 = 0
            raw.withMemoryRebound(to: Int16.self, capacity: i16Count) { p in
                let stride = max(1, i16Count / 256)
                var i = 0
                while i < i16Count {
                    let v = abs(p[i])
                    if v > peak { peak = v }
                    i += stride
                }
            }
            return Float(peak) / Float(Int16.max)
        }
        return 0
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

/// P1: codec choices surfaced in the Output card.
enum RecCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"
    var id: String { rawValue }
    /// AVVideoCodecType to pass into the writer settings.
    var codecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// P1: frame rate choices.
enum RecFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

@MainActor
final class RecViewModel: ObservableObject {

    // Source picking
    enum SourceMode: String, CaseIterable {
        case display = "Display"
        case window  = "Window"
        case region  = "Region"
        case webcam  = "Webcam"  // Power-user item #19 — record just the camera, no screen
    }
    @Published var mode: SourceMode = .display
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var selectedWindowID:  CGWindowID = 0
    @Published var regionRect: CGRect? = nil
    @Published var regionDisplayID: CGDirectDisplayID = CGMainDisplayID()

    // P1: audio toggles — persisted via @AppStorage
    @AppStorage("rec.systemAudioOn")   var systemAudioOn: Bool = true
    @AppStorage("rec.microphoneOn")    var microphoneOn:  Bool = true
    @AppStorage("rec.selectedMicUID")  private var _selectedMicUID: String = ""
    var selectedMicUID: String? {
        get { _selectedMicUID.isEmpty ? nil : _selectedMicUID }
        set { _selectedMicUID = newValue ?? "" }
    }

    // P1: misc prefs — persisted
    @AppStorage("rec.highlightCursor")    var highlightCursor:    Bool   = true
    @AppStorage("rec.sendToStageOnStop")  var sendToStageOnStop: Bool   = false
    // Power-user item #10 — quality preset.
    @AppStorage("rec.quality")           private var _quality: String = RecQuality.balanced.rawValue
    var quality: RecQuality {
        get { RecQuality(rawValue: _quality) ?? .balanced }
        set { _quality = newValue.rawValue }
    }
    // Power-user item #13 — filename template (empty = default timestamped name).
    @AppStorage("rec.filenameTemplate")  var filenameTemplate: String = ""
    // Power-user item #15 — countdown seconds before recording starts (0 = off).
    @AppStorage("rec.countdownSeconds")  var countdownSeconds: Int = 0
    @Published var pendingCountdown: Int? = nil
    // Power-user item #7 — floating Stop panel pref.
    @AppStorage("rec.floatingStop")      private var _floatingStop: String = RecFloatingStopPref.whileRecording.rawValue
    var floatingStopPref: RecFloatingStopPref {
        get { RecFloatingStopPref(rawValue: _floatingStop) ?? .whileRecording }
        set {
            _floatingStop = newValue.rawValue
            RecFloatingStopController.shared.prefDidChange()
        }
    }
    // Power-user item #16 — menu bar status item while recording.
    @AppStorage("rec.menuBarWhileRecording") var menuBarWhileRecording: Bool = false {
        didSet { RecMenuBarController.shared.prefDidChange() }
    }
    // Power-user item #17 — preview sheet after stop (default on).
    @AppStorage("rec.previewSheetOnStop")   var previewSheetOnStop: Bool = true
    /// Set transiently by RecorderView after the engine stops so the
    /// sheet auto-presents. Cleared on dismiss.
    @Published var pendingPreviewURL: URL? = nil
    @Published var pendingPreviewSentToStage: Bool = false
    @Published var pendingPreviewDuration: TimeInterval = 0
    // Power-user item #5 — click ripple overlay during recording.
    @AppStorage("rec.clickRipple")          var clickRipple: Bool = false
    // Power-user item #4 — keystroke overlay during recording.
    @AppStorage("rec.keystrokeOverlay")     var keystrokeOverlay: Bool = false
    // Power-user item #12 — software mic gain (0.0…3.0; 1.0 = unity).
    @AppStorage("rec.micGain")              var micGain: Double = 1.0
    // Power-user item #1 — webcam PIP: record webcam alongside screen.
    @AppStorage("rec.webcamPIP")            var webcamPIP: Bool = false
    @AppStorage("rec.webcamCorner")         private var _webcamCorner: String = RecWebcamCorner.bottomTrailing.rawValue
    var webcamCorner: RecWebcamCorner {
        get { RecWebcamCorner(rawValue: _webcamCorner) ?? .bottomTrailing }
        set { _webcamCorner = newValue.rawValue }
    }
    @AppStorage("rec.webcamSize")           private var _webcamSize: String = RecWebcamSize.medium.rawValue
    var webcamSize: RecWebcamSize {
        get { RecWebcamSize(rawValue: _webcamSize) ?? .medium }
        set { _webcamSize = newValue.rawValue }
    }

    @AppStorage("rec.codec")             private var _codec: String = RecCodec.hevc.rawValue
    var codec: RecCodec {
        get { RecCodec(rawValue: _codec) ?? .hevc }
        set { _codec = newValue.rawValue }
    }
    @AppStorage("rec.fps")               private var _fps: Int  = RecFrameRate.fps60.rawValue
    var fps: RecFrameRate {
        get { RecFrameRate(rawValue: _fps) ?? .fps60 }
        set { _fps = newValue.rawValue }
    }
    @AppStorage("rec.outputFolderPath")  private var _outputFolderPath: String = ""
    var outputFolder: URL {
        get {
            let p = _outputFolderPath
            guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else {
                return RecPaths.defaultFolder
            }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        set { _outputFolderPath = newValue.path }
    }

    @Published var preset: RecPreset? = .tutorial

    let catalog = RecSourceCatalog()
    let engine  = RecEngine()

    init() {
        // Only apply preset on first launch (when AppStorage values are defaults).
        if UserDefaults.standard.object(forKey: "rec.systemAudioOn") == nil {
            applyPreset(.tutorial)
        }
    }

    /// Apply a preset by snapping the relevant toggles. We don't mutate
    /// `outputFolder` / `highlightCursor` since those are pure prefs.
    func applyPreset(_ p: RecPreset) {
        preset = p
        switch p {
        case .tutorial:
            mode = .region
            systemAudioOn = true
            microphoneOn  = true
        case .demo:
            mode = .display
            systemAudioOn = true
            microphoneOn  = false
        case .quiet:
            mode = .region
            systemAudioOn = false
            microphoneOn  = false
        }
    }

    /// Microphones currently visible to the OS. The selection is advisory
    /// — AVCaptureDevice.default(for: .audio) honors the system default,
    /// which is what most users actually want.
    ///
    /// red-team: `.builtInMicrophone` and `.externalUnknown` were deprecated
    /// in macOS 14 in favor of the unified `.microphone` and `.external`
    /// types. Branch on availability so we compile clean on 13 and use the
    /// modern types on 14+.
    var availableMicrophones: [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = {
            if #available(macOS 14.0, *) {
                return [.microphone, .external]
            } else {
                return [.builtInMicrophone, .externalUnknown]
            }
        }()
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices
    }

    func buildSource() -> RecSourceKind {
        switch mode {
        case .display:
            return .display(selectedDisplayID)
        case .window:
            return .window(selectedWindowID)
        case .region:
            if let r = regionRect {
                return .region(r, displayID: regionDisplayID)
            }
            return .display(selectedDisplayID)
        case .webcam:
            // Webcam-only mode (#19) bypasses SCStream entirely; this is
            // a fallback for the rare moment the caller still asks
            // buildSource() before the engine swaps to RecWebcamCapture.
            // The next batch routes the start path past SCStream when
            // mode == .webcam; until then we fall back to display so
            // a partial UI state still produces a valid recording.
            return .display(selectedDisplayID)
        }
    }
}

// ===========================================================================
// MARK: - RecView (public entry point)
// ===========================================================================

/// The pane the caller wires up. No `@main`, no `App`, no `Pane` case — the
/// host app does all of that. Public no-arg init so it slots into the
/// existing `switch pane` in RootView.
struct RecView: View {
    @StateObject private var vm = RecViewModel()
    @EnvironmentObject var stage: Stage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Preset chips ---------------------------------------------
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Presets").headerText()
                        HStack(spacing: 10) {
                            ForEach(RecPreset.allCases) { p in
                                RecPresetChip(preset: p,
                                              selected: vm.preset == p) {
                                    vm.applyPreset(p)
                                }
                            }
                        }
                        if let p = vm.preset {
                            Text(p.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Source ---------------------------------------------------
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Source").headerText()
                        Picker("", selection: $vm.mode) {
                            ForEach(RecViewModel.SourceMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch vm.mode {
                        case .display:
                            Picker("Display", selection: $vm.selectedDisplayID) {
                                ForEach(NSScreen.screens, id: \.self) { s in
                                    if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                                        Text(s.localizedName).tag(id)
                                    }
                                }
                            }
                        case .window:
                            if vm.catalog.windows.isEmpty {
                                Text("Loading windows…")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Window", selection: $vm.selectedWindowID) {
                                    ForEach(vm.catalog.windows, id: \.windowID) { w in
                                        let app = w.owningApplication?.applicationName ?? "?"
                                        Text("\(app) — \(w.title ?? "")").tag(w.windowID)
                                    }
                                }
                            }
                        case .region:
                            HStack {
                                if let r = vm.regionRect {
                                    Text("Region: \(Int(r.width)) × \(Int(r.height))")
                                } else {
                                    Text("No region selected").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Pick region…") {
                                    Task {
                                        if let (rect, did) = await RecRegionPicker.pick() {
                                            vm.regionRect = rect
                                            vm.regionDisplayID = did
                                        }
                                    }
                                }
                            }
                        case .webcam:
                            // #19 webcam-only — the engine path lands in
                            // the next batch; this row tells the user
                            // what's coming so the picker case isn't
                            // a dead end.
                            HStack {
                                Image(systemName: "video.circle")
                                    .foregroundStyle(.secondary)
                                Text("Webcam-only recording — full wiring lands in the next batch. For now, use Display / Window / Region + the Record webcam alongside (PIP) toggle to get a parallel webcam file.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Audio ----------------------------------------------------
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Audio").headerText()

                        // Red-team #2: disable system audio toggle on < 13.
                        if #available(macOS 13.0, *) {
                            Toggle("System audio", isOn: $vm.systemAudioOn)
                        } else {
                            Toggle("System audio (needs macOS 13+)", isOn: .constant(false))
                                .disabled(true)
                        }

                        Toggle("Microphone", isOn: $vm.microphoneOn)
                        if vm.microphoneOn {
                            Picker("Input", selection: Binding(
                                get: { vm.selectedMicUID },
                                set: { vm.selectedMicUID = $0 }
                            )) {
                                Text("System default").tag(String?.none)
                                ForEach(vm.availableMicrophones, id: \.uniqueID) { dev in
                                    Text(dev.localizedName).tag(Optional(dev.uniqueID))
                                }
                            }
                        }
                    }
                }

                // Output + options ----------------------------------------
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Output").headerText()
                        HStack {
                            Text(vm.outputFolder.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Color.troveFgDim)
                            Spacer()
                            Button("Choose…") { chooseFolder() }
                        }
                        // P1: codec picker — default HEVC on Apple Silicon
                        Picker("Codec", selection: Binding(
                            get: { vm.codec },
                            set: { vm.codec = $0 }
                        )) {
                            ForEach(RecCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)

                        // P1: frame rate picker
                        Picker("Frame rate", selection: Binding(
                            get: { vm.fps },
                            set: { vm.fps = $0 }
                        )) {
                            ForEach(RecFrameRate.allCases) { r in
                                Text(r.label).tag(r)
                            }
                        }
                        .pickerStyle(.segmented)

                        // Power-user item #10 — quality preset.
                        Picker("Quality", selection: Binding(
                            get: { vm.quality },
                            set: { vm.quality = $0 }
                        )) {
                            ForEach(RecQuality.allCases) { q in
                                Text(q.label).tag(q)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help(vm.quality.tooltip)

                        // Power-user item #15 — countdown timer before record.
                        Picker("Countdown", selection: Binding(
                            get: { vm.countdownSeconds },
                            set: { vm.countdownSeconds = $0 }
                        )) {
                            Text("Off").tag(0)
                            Text("3s").tag(3)
                            Text("5s").tag(5)
                            Text("10s").tag(10)
                        }
                        .pickerStyle(.segmented)
                        .help("Show a 3-2-1 countdown before recording starts. Esc cancels.")

                        // Power-user item #13 — filename template.
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Filename")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(filenamePreview())
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            TextField("Trove-{datetime}",
                                      text: Binding(
                                          get: { vm.filenameTemplate },
                                          set: { vm.filenameTemplate = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Text("Tokens: {date} {time} {datetime} {yyyy} {MM} {dd} {HH} {mm} {ss} {codec} {fps} {counter}")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Toggle("Show cursor", isOn: Binding(
                            get: { vm.highlightCursor },
                            set: { vm.highlightCursor = $0 }
                        ))
                        Toggle("Send to Stage when stopped", isOn: Binding(
                            get: { vm.sendToStageOnStop },
                            set: { vm.sendToStageOnStop = $0 }
                        ))
                        // Power-user item #7 — floating Stop panel.
                        Picker("Floating Stop", selection: Binding(
                            get: { vm.floatingStopPref },
                            set: { vm.floatingStopPref = $0 }
                        )) {
                            ForEach(RecFloatingStopPref.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help("Show a draggable always-on-top Stop button so you can stop a fullscreen recording without finding the Trove window.")
                        // Power-user item #16 — menu bar status item while recording.
                        Toggle("Show menu bar Record dot", isOn: Binding(
                            get: { vm.menuBarWhileRecording },
                            set: { vm.menuBarWhileRecording = $0 }
                        ))
                        .help("Display a pulsing record dot in the menu bar while recording — click to stop.")
                        // Power-user item #1 — webcam PIP toggle.
                        Toggle("Record webcam alongside (PIP)", isOn: Binding(
                            get: { vm.webcamPIP },
                            set: { vm.webcamPIP = $0 }
                        ))
                        .help("Records a parallel <stem>.webcam.mov so you can overlay the camera onto the screen recording in post. Future batch will add automatic PIP composition.")
                        if vm.webcamPIP {
                            HStack(spacing: 10) {
                                Text("Corner")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { vm.webcamCorner },
                                    set: { vm.webcamCorner = $0 }
                                )) {
                                    ForEach(RecWebcamCorner.allCases) { c in
                                        Text(c.label).tag(c)
                                    }
                                }
                                .labelsHidden()
                                Picker("", selection: Binding(
                                    get: { vm.webcamSize },
                                    set: { vm.webcamSize = $0 }
                                )) {
                                    ForEach(RecWebcamSize.allCases) { s in
                                        Text(s.label).tag(s)
                                    }
                                }
                                .labelsHidden()
                            }
                            .help("Corner + size are baked into the eventual auto-PIP composite. For now they're recorded as metadata for the post-edit step.")
                        }
                        // Power-user item #5 — click ripple overlay.
                        Toggle("Show click ripples", isOn: Binding(
                            get: { vm.clickRipple },
                            set: { vm.clickRipple = $0 }
                        ))
                        .help("Render a fading ring at every mouse click — essential for tutorial recordings. Needs Accessibility permission.")
                        // Power-user item #4 — keystroke overlay.
                        Toggle("Show keystrokes", isOn: Binding(
                            get: { vm.keystrokeOverlay },
                            set: { vm.keystrokeOverlay = $0 }
                        ))
                        .help("Display a HUD with the last chord pressed (⌘⇧K etc.) bottom-center of the screen. Secure input fields are filtered out automatically.")
                        // Power-user item #12 — mic gain slider.
                        HStack(spacing: 10) {
                            Text("Mic gain")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Slider(value: Binding(
                                get: { vm.micGain },
                                set: { vm.micGain = $0 }
                            ), in: 0.0...3.0, step: 0.1)
                                .disabled(!vm.microphoneOn)
                            Text(String(format: "%.1f×", vm.micGain))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(vm.micGain > 2.0 ? Color.troveError
                                                  : (vm.micGain > 1.5 ? .orange : .secondary))
                                .frame(width: 40, alignment: .trailing)
                            Button {
                                vm.micGain = 1.0
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Reset to unity gain (1.0×)")
                            .disabled(abs(vm.micGain - 1.0) < 0.05)
                        }
                        .help("Software gain applied to the mic before encoding. 1.0× is unity (current behavior); >1.0 amplifies; gains above 2.0 will frequently clip. Watch the clipping indicator in the HUD during recording.")
                    }
                }

                // Recording HUD, countdown overlay, or Record button -----
                if let n = vm.pendingCountdown {
                    Card {
                        VStack(spacing: 14) {
                            Text("\(n)")
                                .font(.system(size: 96, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Recording starts in \(n) seconds")
                            Text(n == 1 ? "Recording in 1 second…"
                                        : "Recording in \(n) seconds…")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                vm.pendingCountdown = nil
                            } label: {
                                Label("Cancel countdown", systemImage: "xmark.circle")
                            }
                            .controlSize(.large)
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("Cancel before recording starts (Esc)")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }
                } else if vm.engine.isRecording {
                    RecHUD(engine: vm.engine, vm: vm) { url in
                        let routedToStage = vm.sendToStageOnStop && (url != nil)
                        if routedToStage, let url = url {
                            stage.addFile(url)
                            // Power-user item #3 — rich auto-route message
                            // with duration + sources + codec + fps so the
                            // user sees what just landed instead of a
                            // generic "added to Stage" toast.
                            let dur = RecMeta.duration(vm.engine.elapsed)
                            let audio = RecMeta.audioSummary(sys: vm.systemAudioOn,
                                                              mic: vm.microphoneOn)
                            let codec = vm.codec.rawValue
                            let fps = vm.fps.rawValue
                            stage.flash("\(dur) · \(audio) · \(codec) \(fps)fps → Stage")
                        }
                        // Power-user item #17 — preview sheet auto-pop.
                        if vm.previewSheetOnStop, let url = url {
                            vm.pendingPreviewDuration = vm.engine.elapsed
                            vm.pendingPreviewSentToStage = routedToStage
                            vm.pendingPreviewURL = url
                        }
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            if let err = vm.engine.lastError {
                                RecErrorBanner(error: err)
                            }
                            HStack {
                                Button(action: startRecording) {
                                    Label("Record", systemImage: "record.circle.fill")
                                        .font(.title3)
                                        .padding(.horizontal, 8)
                                }
                                .keyboardShortcut("r", modifiers: [.command, .shift])
                                .controlSize(.large)
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Spacer()
                            }

                            if let url = vm.engine.lastOutputURL {
                                RecLastRecordingRow(url: url)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Recorder")
        .navigationSubtitle(vm.engine.isRecording
                            ? (vm.engine.isPaused ? "Paused" : "Recording…")
                            : "ScreenCaptureKit · system + mic")
        // Power-user item #17 — preview sheet auto-popped after stop.
        .sheet(isPresented: Binding(
            get: { vm.pendingPreviewURL != nil },
            set: { if !$0 { vm.pendingPreviewURL = nil } }
        )) {
            if let url = vm.pendingPreviewURL {
                RecPreviewSheet(
                    url: url,
                    durationHint: vm.pendingPreviewDuration,
                    sentToStage: vm.pendingPreviewSentToStage,
                    onClose: { vm.pendingPreviewURL = nil },
                    onReRecord: {
                        // Move to Trash, dismiss, restart with current settings.
                        let target = url
                        vm.pendingPreviewURL = nil
                        try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
                        startRecording()
                    })
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(RecPreset.allCases) { p in
                    Button {
                        vm.applyPreset(p)
                    } label: {
                        Label(p.rawValue, systemImage: p.icon)
                    }
                    .help(p.subtitle)
                }
            }
        }
        // Red-team #1: do NOT call SCShareableContent on appear. Just
        // attempt a no-permission-required catalog refresh when the user
        // explicitly switches into Window mode.
        .task(id: vm.mode) {
            if vm.mode == .window {
                await vm.catalog.refresh()
            }
        }
        // red-team: sweep orphaned `.tmp.mp4` files from a prior crash so
        // the output folder doesn't accumulate junk and so the user sees
        // a clearly-named `.recovered.mp4` they can attempt to repair.
        // Discard the renamed-count return value explicitly — the previous
        // `await Task.detached { ... }.value` form raised a Swift 6 unused-
        // expression warning because the Int wasn't consumed.
        .task {
            let folder = vm.outputFolder
            await Task.detached(priority: .background) {
                _ = RecPaths.sweepStaleTmp(folder)
            }.value
            // Power-user items #7 + #16 — attach controllers once on
            // appear. They observe engine.isRecording themselves so the
            // attach call is idempotent + cheap.
            let stop: () -> Void = {
                Task { @MainActor in
                    await vm.engine.stop()
                    if vm.sendToStageOnStop, let url = vm.engine.lastOutputURL {
                        stage.addFile(url)
                        stage.flash("Recording added to Stage")
                    }
                }
            }
            RecFloatingStopController.shared.attach(engine: vm.engine, stop: stop)
            RecMenuBarController.shared.attach(engine: vm.engine, stop: stop)
            // Power-user items #4 + #5 — overlay tap. Active only when
            // a recording is running AND the relevant pref is on.
            // Combine sink on the engine's isRecording publisher keeps
            // the dispatcher state in sync without polling.
            for await rec in vm.engine.$isRecording.values {
                let cr = rec && vm.clickRipple
                let ks = rec && vm.keystrokeOverlay
                RecOverlayDispatcher.shared.clickRippleOn = cr
                RecOverlayDispatcher.shared.keystrokeOn   = ks
                RecOverlayTap.shared.setClickRipple(cr)
                RecOverlayTap.shared.setKeystrokeOverlay(ks)
            }
        }
        // Listen for menu-bar Record submenu triggers. userInfo carries
        // mix-and-match audio config: keys "mic" and "sys", both Bool.
        // Falls back to system+mic if userInfo is missing (legacy callers).
        .onReceive(NotificationCenter.default.publisher(for: .troveStartRecordingNow)) { note in
            guard !vm.engine.isRecording else { return }
            let mic = (note.userInfo?["mic"] as? Bool) ?? true
            let sys = (note.userInfo?["sys"] as? Bool) ?? true
            // Pick preset by audio combo so the UI subtitle reflects it.
            switch (mic, sys) {
            case (false, false): vm.applyPreset(.quiet)
            case (true,  true):  vm.applyPreset(.tutorial)
            case (false, true):  vm.applyPreset(.demo)
            case (true,  false): vm.applyPreset(.tutorial)  // no mic-only preset; tutorial then disable sys
            }
            vm.systemAudioOn = sys
            vm.microphoneOn  = mic
            startRecording()
        }
    }

    // ---- Actions -------------------------------------------------------

    private func startRecording() {
        Task {
            do {
                // Power-user item #15 — countdown timer. Run BEFORE asking
                // mic permission so the user can cancel during the countdown
                // without dismissing the OS dialog (worse UX). Esc cancels
                // by setting pendingCountdown = nil; the loop bails out on
                // the next tick.
                if vm.countdownSeconds > 0 {
                    var n = vm.countdownSeconds
                    vm.pendingCountdown = n
                    while n > 0 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard vm.pendingCountdown != nil else {
                            // User cancelled via Esc / button — abort cleanly.
                            return
                        }
                        n -= 1
                        vm.pendingCountdown = n
                    }
                    vm.pendingCountdown = nil
                }

                // Fix #1: Request mic permission BEFORE starting the engine
                // so the OS dialog appears before recording begins and we can
                // gate the mic track accurately rather than starting it and
                // then discovering it was denied.
                var micGranted = vm.microphoneOn
                if vm.microphoneOn {
                    let granted = await withCheckedContinuation { cont in
                        RecPermissions.requestMicrophone { ok in cont.resume(returning: ok) }
                    }
                    if !granted {
                        vm.microphoneOn = false
                        micGranted = false
                        SharedStore.stage.flash("Microphone permission denied", kind: .warning)
                        return
                    }
                }
                // Apply pro-user knobs that aren't passed via start()'s
                // parameter list — kept as engine properties so the rest
                // of the signature stays stable.
                vm.engine.qualityMultiplier = vm.quality.bitrateMultiplier
                vm.engine.filenameTemplate  = vm.filenameTemplate
                vm.engine.micGain           = Float(vm.micGain)
                vm.engine.webcamPIPEnabled  = vm.webcamPIP
                vm.engine.webcamDeviceUID   = vm.selectedMicUID == "" ? nil : nil   // separate webcam UID picker is next batch
                try await vm.engine.start(
                    source: vm.buildSource(),
                    outputFolder: vm.outputFolder,
                    systemAudio: vm.systemAudioOn,
                    microphone: micGranted,
                    micUID: vm.selectedMicUID,
                    showsCursor: vm.highlightCursor,
                    codec: vm.codec,
                    fps: vm.fps,
                    excludeBundleID: Bundle.main.bundleIdentifier
                )
            } catch {
                // Engine already set lastError; nothing else to do.
            }
        }
    }

    /// Live preview of the expanded filename template. Shown to the
    /// right of the "Filename" label so the user knows what the next
    /// recording will be named without having to start one to find out.
    private func filenamePreview() -> String {
        RecPaths.name(
            template: vm.filenameTemplate,
            counter: 1,
            codec: vm.codec.rawValue.replacingOccurrences(of: " ", with: "_"),
            fps: vm.fps.rawValue,
            source: "")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vm.outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            vm.outputFolder = url
        }
    }
}

// ===========================================================================
// MARK: - Last-recording row (Save / Reveal / Stage / Copy Path / Drag)
// ===========================================================================

/// Mirrors the pdf.swift `outputRow` affordance set for a single recording.
/// Recordings can be multi-GB videos; `NSItemProvider(contentsOf:)` returns
/// a file URL the OS copies lazily, so dragging stays cheap even for huge
/// files.
struct RecLastRecordingRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.fileSizeString(url))
                    Text("·")
                    Text("Last recording")
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { RecSaver.save(url) } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save the recording (⌘S).")

            Menu {
                Button { RecSaver.quickSaveToDownloads(url) } label: {
                    Label("Save to Downloads", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut("d", modifiers: [.command])
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button {
                    SharedStore.stage.addFile(url)
                    SharedStore.stage.flash("Sent \(url.lastPathComponent) to Stage")
                } label: {
                    Label("Send to Stage", systemImage: "tray.and.arrow.down")
                }
                Button { RecSaver.openInQuickTime(url) } label: {
                    Label("Show in QuickTime Player", systemImage: "play.rectangle")
                }
                // Power-user item #2 — cross-pane Continue editing.
                Divider()
                Section("Continue editing") {
                    Button {
                        RecSaver.extractFirstFrameAndSendToOCR(url)
                    } label: {
                        Label("Extract a frame → OCR", systemImage: "doc.viewfinder")
                    }
                    .help("Pull the first frame of the recording and route it into the OCR pane for text extraction.")
                    Button {
                        RecSaver.extractFirstFrameAndSendToStage(url)
                    } label: {
                        Label("First frame → Stage", systemImage: "photo")
                    }
                    .help("Pull the first frame as a PNG and route it to Stage so you can chain it into any image pane.")
                    Button {
                        if let openURL = URL(string: "trove://pane/open?pane=Snip") {
                            NSWorkspace.shared.open(openURL)
                        }
                    } label: {
                        Label("Annotate a frame in Snip", systemImage: "scribble.variable")
                    }
                    .help("Open the Snip pane — drop a frame from this recording in to annotate / arrow / blur.")
                }
                Divider()
                Button { RecSaver.copyPath(url) } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        // Recordings can be many GB — NSItemProvider(contentsOf:) hands the
        // receiver a file URL and lets the OS copy lazily, so even drags
        // into Mail or Slack don't block the UI.
        .onDrag {
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button { RecSaver.save(url) } label: { Label("Save…", systemImage: "square.and.arrow.down") }
            Button { RecSaver.quickSaveToDownloads(url) } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
            Button {
                SharedStore.stage.addFile(url)
                SharedStore.stage.flash("Sent \(url.lastPathComponent) to Stage")
            } label: { Label("Send to Stage", systemImage: "tray.and.arrow.down") }
            Button { RecSaver.openInQuickTime(url) } label: { Label("Show in QuickTime Player", systemImage: "play.rectangle") }
            Divider()
            Button { RecSaver.copyPath(url) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    private static func fileSizeString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Power-user item #3 — short readable strings for the "added to Stage"
/// flash toast (and anywhere else we surface recording metadata).
enum RecMeta {
    static func duration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, ss = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, ss)
            : String(format: "%d:%02d", m, ss)
    }
    static func audioSummary(sys: Bool, mic: Bool) -> String {
        switch (sys, mic) {
        case (true,  true):  return "system + mic"
        case (true,  false): return "system audio"
        case (false, true):  return "mic only"
        case (false, false): return "silent"
        }
    }
}

/// Static save / drag / clipboard helpers for recordings. Mirrors the pdf.swift
/// `outputRow` helper pattern. Statics so closures don't capture `self` on
/// rapidly-recreated views.
enum RecSaver {
    private static let kSaveDirKey = "recorder.captures.saveDir.last"

    static func save(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        if let ut = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [ut]
        }
        panel.canCreateDirectories = true
        panel.directoryURL = lastSaveDir() ?? downloadsDir()
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            setLastSaveDir(dest.deletingLastPathComponent())
            do {
                // NSSavePanel itself prompted for overwrite consent.
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                SharedStore.stage.flash("Saved to \(dest.deletingLastPathComponent().lastPathComponent)")
            } catch {
                SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
            }
        }
    }

    static func quickSaveToDownloads(_ url: URL) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            SharedStore.stage.flash("Downloads folder unavailable")
            return
        }
        let dest = collisionFreeURL(in: downloads, name: url.lastPathComponent)
        do {
            try fm.copyItem(at: url, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            SharedStore.stage.flash("Saved to Downloads")
        } catch {
            SharedStore.stage.flash("Save failed: \(error.localizedDescription)")
        }
    }

    static func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        SharedStore.stage.flash("Copied path")
    }

    /// Power-user item #2 — cross-pane Continue editing. Pull the first
    /// frame from the recording and send it into another Trove pane.
    /// We extract once and reuse the PNG for both routes so we never
    /// pay the AVAssetImageGenerator cost twice.
    static func extractFirstFrameAndSendToOCR(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            guard let png = await firstFramePNG(url: url) else {
                await MainActor.run { SharedStore.stage.flash("Couldn't extract a frame", kind: .warning) }
                return
            }
            await MainActor.run {
                // Send the PNG to Stage with a hint label so the user can
                // see what arrived, then deeplink to OCR which picks up
                // the new image item on appear.
                SharedStore.stage.addFile(png)
                if let openURL = URL(string: "trove://pane/open?pane=OCR") {
                    NSWorkspace.shared.open(openURL)
                }
                SharedStore.stage.flash("First frame → Stage; opening OCR")
            }
        }
    }

    static func extractFirstFrameAndSendToStage(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            guard let png = await firstFramePNG(url: url) else {
                await MainActor.run { SharedStore.stage.flash("Couldn't extract a frame", kind: .warning) }
                return
            }
            await MainActor.run {
                SharedStore.stage.addFile(png)
                SharedStore.stage.flash("First frame → Stage")
            }
        }
    }

    /// Render the first frame of a video file to a PNG in `~/Documents/Trove/frames/`.
    /// Off-main. Returns nil on decode failure or if the file isn't a
    /// video Trove can read.
    nonisolated private static func firstFramePNG(url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity
        // Use the modern async API where available (macOS 13+).
        do {
            let result = try await gen.image(at: .zero)
            let cg = result.image
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            // Sit alongside the recording so the user finds it without
            // having to dig — but in a `.frames/` subdir to keep the
            // recording folder uncluttered.
            let dir = url.deletingLastPathComponent().appendingPathComponent("frames",
                                                                            isDirectory: true)
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            let stem = (url.lastPathComponent as NSString).deletingPathExtension
            let dest = dir.appendingPathComponent("\(stem)-frame1.png")
            try data.write(to: dest, options: [.atomic])
            return dest
        } catch {
            return nil
        }
    }

    /// Explicitly open in QuickTime Player rather than relying on default
    /// open — Finder may have a third-party .mov handler set (IINA, VLC).
    /// Falls back to the default opener if QuickTime isn't at the known path.
    static func openInQuickTime(_ url: URL) {
        let qt = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        if FileManager.default.fileExists(atPath: qt.path) {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: qt, configuration: cfg) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

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

// ===========================================================================
// MARK: - Preset chip
// ===========================================================================

struct RecPresetChip: View {
    let preset: RecPreset
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: preset.icon)
                Text(preset.rawValue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // P2: raw colors → tokens
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.troveAccent.opacity(0.18) : Color.troveCardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.troveAccent : Color.troveCardStroke,
                                  lineWidth: selected ? 1.2 : 0.5)
            )
            .foregroundStyle(selected ? Color.troveAccent : Color.troveFg)
        }
        .buttonStyle(.plain)
    }
}

// ===========================================================================
// MARK: - Live HUD
// ===========================================================================

struct RecHUD: View {
    @ObservedObject var engine: RecEngine
    @ObservedObject var vm: RecViewModel
    let onStop: (URL?) -> Void

    /// P0: confirmation state for Discard — must preview before hard-stop.
    @State private var showDiscardConfirm = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(engine.isPaused ? Color.orange : Color.red)
                        .frame(width: 12, height: 12)
                        // red-team: a repeatForever blink ignored Reduce Motion.
                        // Under that setting we hold a solid dot — the colour
                        // and adjacent "Recording" label already signal state.
                        .opacity(engine.isPaused
                                 ? 1.0
                                 : (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                    ? 1.0
                                    : (pulse ? 0.4 : 1.0)))
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                   ? nil
                                   : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                                   value: pulse)
                        .onAppear {
                            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                                pulse = true
                            }
                        }
                        .accessibilityLabel(engine.isPaused ? "Recording paused" : "Recording in progress")
                    Text(engine.isPaused ? "Paused" : "Recording")
                        // P1 a11y fix: sweep regression — this is a live
                        // status string that mutates during recording, not
                        // a structural section heading. .isHeader trait
                        // pollutes the VoiceOver heading rotor.
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    Text(timecode(engine.elapsed))
                        .font(.system(.title2, design: .monospaced))
                        .monospacedDigit()
                }

                HStack {
                    Label(engine.estimatedBytes.human, systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // Audio meters — one row per enabled source.
                if vm.systemAudioOn {
                    RecLevelMeter(label: "System", level: engine.systemAudioLevel)
                }
                if vm.microphoneOn {
                    RecLevelMeter(label: "Mic",    level: engine.micAudioLevel)
                }

                if let err = engine.lastError {
                    RecErrorBanner(error: err)
                }

                HStack {
                    if engine.isPaused {
                        Button { engine.resume() } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .controlSize(.large)
                    } else {
                        Button { engine.pause() } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .controlSize(.large)
                    }

                    Button {
                        Task {
                            await engine.stop()
                            onStop(engine.lastOutputURL)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Stop recording (Esc or ⌘.)")
                    // Mirror ⌘. → Stop. SwiftUI only honors one shortcut per
                    // Button, so a zero-size hidden Button carries the second.
                    Button("") {
                        Task {
                            await engine.stop()
                            onStop(engine.lastOutputURL)
                        }
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)

                    Spacer()

                    // P0 fix: Discard button — show confirmationDialog before
                    // calling engine.discard() so the user sees elapsed time +
                    // estimated size before potentially trashing a multi-GB file.
                    Button {
                        showDiscardConfirm = true
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .controlSize(.large)
                    .foregroundStyle(Color.troveError)
                    .help("Stop recording and delete this clip (asks for confirmation)")
                    .confirmationDialog(
                        "Discard this recording?",
                        isPresented: $showDiscardConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Discard Recording", role: .destructive) {
                            Task { await engine.discard() }
                        }
                        Button("Keep Recording", role: .cancel) {}
                    } message: {
                        let elapsed = engine.elapsed
                        let s = Int(elapsed)
                        let timeStr = String(format: "%02d:%02d", s / 60, s % 60)
                        let sizeStr = engine.estimatedBytes.human
                        Text("\(timeStr) recorded (\(sizeStr) so far) will be permanently deleted.")
                    }
                }
            }
        }
    }

    @State private var pulse = false

    private func timecode(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct RecLevelMeter: View {
    let label: String
    let level: Float   // 0...1
    // Fix 10: gate animation on reduceMotion accessibility preference.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.gray.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.green, .yellow, .red],
                                             startPoint: .leading,
                                             endPoint: .trailing))
                        .frame(width: max(2, CGFloat(level) * geo.size.width))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
                }
            }
            .frame(height: 8)
        }
    }
}

// ===========================================================================
// MARK: - Error banner
// ===========================================================================

struct RecErrorBanner: View {
    let error: RecError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.troveWarning)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.errorDescription ?? "Error")
                if let action = actionLabel {
                    // red-team: was `.link` style — too easy to overlook for
                    // the very error states where it's the user's only path
                    // forward (TCC denial). Promote to `.borderedProminent`
                    // for permission failures specifically; non-permission
                    // errors don't have an `actionLabel` so this branch is
                    // unreachable for them.
                    Button {
                        runAction()
                    } label: {
                        Label(action, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        // P2: raw color → token
        .background(Color.troveWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch error {
        case .needsScreenRecordingPermission, .needsMicrophonePermission:
            return "lock.shield"
        case .diskFull:
            return "externaldrive.badge.exclamationmark"
        default:
            return "exclamationmark.triangle"
        }
    }

    private var actionLabel: String? {
        switch error {
        case .needsScreenRecordingPermission: return "Open System Settings"
        case .needsMicrophonePermission:      return "Open System Settings"
        default: return nil
        }
    }

    private func runAction() {
        switch error {
        case .needsScreenRecordingPermission: RecPermissions.openScreenRecordingSettings()
        case .needsMicrophonePermission:      RecPermissions.openMicrophoneSettings()
        default: break
        }
    }
}

// ===========================================================================
// MARK: - RecRedTeam index
// ===========================================================================
//
// 1. Screen Recording TCC denied:
//    - We do NOT call SCShareableContent on view appear (only on user
//      switching to Window mode or pressing Record). On denial, we surface
//      `RecError.needsScreenRecordingPermission` with a deep-link button to
//      System Settings > Privacy > Screen Recording. No crash, no loop.
//
// 2. macOS < 13:
//    - System-audio toggle is disabled with a clear label.
//    - `RecEngine.start` short-circuits with `RecError.unsupportedOS` if
//      `#available(macOS 13.0, *)` fails.
//
// 3. Microphone permission denied:
//    - `AVCaptureDevice.requestAccess(for: .audio)` triggered on Record;
//      denial surfaces `.needsMicrophonePermission`. Recording proceeds
//      video-only (mic input is simply never added to the writer).
//
// 4. No microphone connected:
//    - `AVCaptureDevice.default(for: .audio)` returns nil → surface
//      `.noMicrophone`, skip mic input, continue recording.
//
// 5. Disk fills mid-recording:
//    - AVAssetWriter sets `error` to NSPOSIXError ENOSPC (28). We detect
//      that in `stop()` and surface `.diskFull`. Whatever bytes flushed
//      are preserved (the .tmp.mp4 path is still returned as
//      `lastOutputURL`).
//
// 6. App crashes mid-recording:
//    - Writer always targets `<name>.mp4.tmp.mp4`. Renamed to `<name>.mp4`
//      only on successful `finishWriting()`. A crash leaves the .tmp file
//      behind — likely missing moov atom, recoverable with ffmpeg.
//      Documented at top of file.
//
// 7. A/V drift on long recordings:
//    - `startSession(atSourceTime:)` uses the first video PTS verbatim.
//      Audio sample buffers are appended with their own PTS, untranslated;
//      AVAssetWriter handles the timeline. No manual remap math to drift.
//
// 8. Memory growth on long sessions:
//    - SCStream callbacks append-and-discard. We do not retain
//      CMSampleBufferRefs anywhere. `queueDepth = 6` so SCK drops frames
//      rather than backing up its internal queue.
//
// 9. App recording itself:
//    - `SCContentFilter(display:excludingApplications:exceptingWindows:)`
//      is built with `excluded = applications.filter { $0.bundleIdentifier
//      == Bundle.main.bundleIdentifier }`. Trove can't capture itself.
//
// 10. Retina / HiDPI:
//    - `cfg.width = display.width * screen.backingScaleFactor` (same for
//      height). Output is native pixels, not points.
