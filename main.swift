// Trove — local-only macOS productivity app.
//   • Stage:    CommandX-style multi-clipboard / screenshot staging
//   • Storage:  disk inspector + dev-cache cleaner + Downloads/Desktop sweeper
//
// No network. No third-party deps. Single Swift file.

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - App entry + menu bar
// ===========================================================================

#if !TROVE_TESTING
@main
struct TroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Trove") {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
                .background(WindowChrome(stage: SharedStore.stage))
                .environmentObject(SharedStore.stage)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))

        // Proper macOS Settings scene — hosts under Trove → Settings… (⌘,).
        // CustomizeView used to be a sidebar route; that was the wrong shape.
        // Settings windows live in the menu bar and persist their own state.
        Settings {
            TroveSettingsScene()
        }

        .commands {
            // ─── Trove (app menu) ──────────────────────────────────────────
            // SwiftUI auto-provides About / Settings… / Services / Hide /
            // Quit. We add a manual "Check for Updates…" right under About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await UpdateChecker.shared.check(quiet: false) }
                }
            }

            // ─── File ──────────────────────────────────────────────────────
            // We deliberately don't expose "New Window" (single-window app).
            // The native File menu collapses to just Close (⌘W), which is
            // what we want.
            CommandGroup(replacing: .newItem) {}

            // ─── Edit ──────────────────────────────────────────────────────
            // Stage actions live after the standard Cut/Copy/Paste cluster.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Paste into Stage")    { SharedStore.stage.pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Copy All as Files")   { SharedStore.stage.copyAllAsFiles() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Capture Screenshot")  { SharedStore.stage.captureScreenshot() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Clear Stage")         { SharedStore.stage.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            // ─── View ──────────────────────────────────────────────────────
            // SwiftUI auto-adds "Show/Hide Sidebar" for NavigationSplitView.
            // We append quick-jump shortcuts for the canonical clipboard
            // panes (⌘1-⌘4) so power users never have to mouse to the
            // sidebar. Order matches the Clipboard section in the sidebar.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Stage")    { switchToPane(.stage) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("History")  { switchToPane(.history) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Snippets") { switchToPane(.snippets) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Notes")    { switchToPane(.notes) }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button(SharedStore.stage.floating ? "Unpin Window" : "Pin Window on Top") {
                    SharedStore.stage.floating.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Quick Switcher…") {
                    // Posts a notification; RootView listens and shows the sheet.
                    NotificationCenter.default.post(name: .troveOpenQuickSwitcher, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Customize Sidebar…") { openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }

            // ─── Help ──────────────────────────────────────────────────────
            // Replace the default search-only Help menu with branded links.
            CommandGroup(replacing: .help) {
                Button("Trove Website") {
                    if let url = URL(string: "https://gettrove.vercel.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Send Feedback") {
                    if let url = URL(string: "mailto:arnavgoel0303@gmail.com?subject=Trove%20feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Privacy Policy") {
                    if let url = URL(string: "https://gettrove.vercel.app/privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
#endif

enum SharedStore {
    static let stage = Stage()
}

// red-team: three call sites shell out to `/usr/sbin/screencapture -i` — Stage's
// `captureScreenshot`, OCR's `OCRCapture.captureRegion`, and Recorder's
// `RecRegionPicker.pick`. macOS happily lets two run concurrently, which
// produces two competing crosshair overlays, two dimmed-screen layers, and
// keyboard/Esc routing that disagrees about which session is being cancelled.
// Gate all three through a single tryAcquire latch so the second invocation
// fails fast instead of corrupting both sessions. Acquire/release is main-only,
// so no lock is needed — both reads and writes hop to MainActor.
/// Single-acquirer latch for `screencapture -i` invocations across Stage,
/// OCR, and Recorder. Without it, two concurrent invocations produce two
/// competing crosshair overlays.
/// nonisolated + os_unfair_lock so any thread can ask for the gate without
/// hopping to MainActor first.
enum InteractiveCaptureGate {
    nonisolated(unsafe) private static var inFlight = false
    nonisolated(unsafe) private static var lock = os_unfair_lock_s()

    static func tryAcquire() -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if inFlight { return false }
        inFlight = true
        return true
    }

    static func release() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        inFlight = false
    }
}

/// One-click deep links to System Settings privacy panes. URL schemes are
/// documented-stable across macOS 13/14/15. Every TCC-blocked failure path
/// in Trove surfaces one of these via either an "Open Settings" toast
/// action button or a `.borderedProminent` empty-state button, so the user
/// can fix permissions without leaving the app.
enum TCCDeepLink: String {
    case accessibility    = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case screenRecording  = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    case fullDiskAccess   = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    case microphone       = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case camera           = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    case automation       = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    case filesAndFolders  = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    case inputMonitoring  = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    @discardableResult
    func open() -> Bool {
        // Fix 6: mirror the multi-URL fallback pattern from PermsCategoryCard.openDeepLink().
        let primary = rawValue
        if let url = URL(string: primary), NSWorkspace.shared.open(url) { return true }
        // Try the Ventura+ bundle-id translation.
        let translated = primary.replacingOccurrences(
            of: "com.apple.preference.security",
            with: "com.apple.settings.PrivacySecurity.extension")
        if translated != primary,
           let url = URL(string: translated),
           NSWorkspace.shared.open(url) { return true }
        // Fall back to Privacy root pane.
        if let root = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"),
           NSWorkspace.shared.open(root) { return true }
        // Absolute last resort — open System Settings.
        if let app = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(app)
            return true
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        #if !TROVE_TESTING
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.button?.image = NSImage(systemSymbolName: "tray.full.fill",
                                  accessibilityDescription: "Trove")
        let m = NSMenu()
        m.addItem(make("Show Trove",      #selector(showWin), "0"))
        m.addItem(.separator())
        m.addItem(make("Capture Screenshot", #selector(cap)))
        m.addItem(make("Paste Clipboard",    #selector(pst)))
        m.addItem(make("Copy All",           #selector(cpy)))
        m.addItem(make("Clear",              #selector(clr)))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Trove",
                             action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q"))
        s.menu = m
        statusItem = s

        // red-team: install the configurable global hotkey (⌘⇧2 → full-screen
        // screenshot to Stage by default). Settings UI lives in Customize.
        TroveGlobalHotkeys.shared.install()

        // Auto-check for updates if enabled (default ON). Throttled — checks
        // at most once every 6h. Silent on failure during launch.
        UpdateChecker.shared.checkOnLaunchIfEligible()

        // red-team: system-state lifecycle hooks.
        //   • didWakeNotification         → re-fetch stale ECB rates, rebuild locale formatter caches.
        //   • screensDidChangeNotification → snap AltTab overlay off if its host display vanished.
        //   • NSLocale.currentLocaleDidChangeNotification → bust cached formatters.
        //   • willTerminateNotification   → cutpaste already self-subscribes; notes/recorder finalize here.
        let ws  = NSWorkspace.shared.notificationCenter
        let nc  = NotificationCenter.default
        ws.addObserver(self, selector: #selector(systemDidWake(_:)),
                       name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWillSleep(_:)),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged(_:)),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(localeChanged(_:)),
                       name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willTerminateHook(_:)),
                       name: NSApplication.willTerminateNotification, object: nil)
        #endif
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // Fix 4: CalcRateStore.shared.refreshIfStale() moved into
        // CalcRateStore.init() so the store self-manages its lifecycle.
    }

    @objc func systemDidWake(_ note: Notification) {
        // Fix 4: ECB refresh on wake is now handled inside CalcRateStore.init()
        // via an NSWorkspace.didWakeNotification subscription. No delegate call needed.
        Formatters.bumpEpoch()   // already nonisolated, safe to call directly.
    }

    @objc func systemWillSleep(_ note: Notification) {
        // red-team: long-running BigScan + Recorder are best stopped before
        // sleep so we don't carry a half-finished writer / scan across an
        // 8-hour suspend. We post a notification; owners listen.
        NotificationCenter.default.post(name: .troveSystemWillSleep, object: nil)
    }

    @objc func screensChanged(_ note: Notification) {
        // red-team: if the AltTab overlay was on a now-disconnected display,
        // hide it so a panel doesn't sit at off-screen coords forever.
        NotificationCenter.default.post(name: .troveScreensChanged, object: nil)
    }

    @objc func localeChanged(_ note: Notification) {
        // red-team: cached NumberFormatter / RelativeDateTimeFormatter
        // statics don't re-read Locale.current. Bump an epoch so views that
        // care can rebuild via a computed accessor.
        Formatters.bumpEpoch()
    }

    @objc func willTerminateHook(_ note: Notification) {
        // red-team: force-flush notes within the 200ms debounce window so a
        // quit-immediately-after-keystroke doesn't lose the last edit.
        NotificationCenter.default.post(name: .troveWillTerminate, object: nil)
    }

    private func make(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc func showWin() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first { w.makeKeyAndOrderFront(nil) }
    }
    @objc func cap() { SharedStore.stage.captureScreenshot() }
    @objc func pst() { SharedStore.stage.pasteFromClipboard() }
    @objc func cpy() { SharedStore.stage.copyAllAsFiles() }
    @objc func clr() { SharedStore.stage.clear() }

    // red-team: re-open from Dock / Finder while running activates the existing
    // window instead of spawning a second instance. macOS already does the
    // single-instance enforcement for .app bundles, but `open Trove.app`
    // can race with a dying main process; we re-show our window here too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWin() }
        return true
    }
}

// red-team: notifications used across files for centralized lifecycle hooks.
extension Notification.Name {
    static let troveSystemWillSleep = Notification.Name("TroveSystemWillSleep")
    static let troveScreensChanged  = Notification.Name("TroveScreensChanged")
    static let troveWillTerminate   = Notification.Name("TroveWillTerminate")
    // Stage / History post this when they write to NSPasteboard.general; the
    // *other* store listens and bumps its `lastChangeCount` so the next
    // watcher tick doesn't echo-ingest our own write.
    static let troveDidWritePasteboard = Notification.Name("TroveDidWritePasteboard")
    /// Posted when the View → Quick Switcher menu item (⌘K) fires. RootView
    /// listens and presents the QuickSwitcherView sheet.
    static let troveOpenQuickSwitcher = Notification.Name("TroveOpenQuickSwitcher")
}

// Fix 11: shared pasteboard poller that replaces the twin 0.5s timers that
// Stage and ClipHistory each ran independently (2 main-thread wakes/sec → 1).
// Subscribers register a handler; the singleton fires once per 0.5s tick when
// at least one subscriber is registered.  A `troveDidWritePasteboard` post from
// either store advances the shared watermark so the very next tick is a no-op.
// NOTE: all methods MUST be called from the main thread (timer/handlers run on main).
final class PasteboardWatcher {
    // nonisolated(unsafe) so both @MainActor and non-@MainActor callers can
    // access the singleton without an actor hop at the call site.
    nonisolated(unsafe) static let shared = PasteboardWatcher()

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var handlers: [ObjectIdentifier: () -> Void] = [:]
    private var writeObserver: NSObjectProtocol?

    private init() {
        writeObserver = NotificationCenter.default.addObserver(
            forName: .troveDidWritePasteboard, object: nil, queue: .main
        ) { [weak self] _ in
            // Advance watermark so the next tick sees no delta.
            self?.lastChangeCount = NSPasteboard.general.changeCount
        }
    }

    deinit {
        if let obs = writeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        stopTimer()
    }

    /// Register a handler.  The `key` is any object (use `self`).
    /// While at least one handler is registered the 0.5s timer runs.
    /// Must be called on the main thread.
    func subscribe(key: AnyObject, handler: @escaping () -> Void) {
        handlers[ObjectIdentifier(key)] = handler
        startIfNeeded()
    }

    /// Must be called on the main thread.
    func unsubscribe(key: AnyObject) {
        handlers.removeValue(forKey: ObjectIdentifier(key))
        if handlers.isEmpty { stopTimer() }
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cc = NSPasteboard.general.changeCount
            guard cc != self.lastChangeCount else { return }
            self.lastChangeCount = cc
            self.handlers.values.forEach { $0() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// red-team: epoch-bumped formatter source so locale/dark-mode-related caches
// rebuild lazily on next read instead of being frozen at app launch.
// nonisolated so @objc notification handlers (which aren't on a specific actor)
// can call bumpEpoch() from any thread. Access is via os_unfair_lock for safety.
enum Formatters {
    nonisolated(unsafe) private static var _epoch: Int = 0
    nonisolated(unsafe) private static var lock = os_unfair_lock_s()

    static var epoch: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _epoch
    }
    static func bumpEpoch() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        _epoch &+= 1
    }
}

/// Window-level adjuster that doesn't participate in the SwiftUI attribute
/// graph (which crashes on macOS 26 when wrapped in `.background()` with
/// `@ObservedObject`). Instead we observe via Combine in a coordinator.
struct WindowChrome: NSViewRepresentable {
    let stage: Stage

    func makeCoordinator() -> Coord { Coord(stage: stage) }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        // Apply once after the view is in the window
        DispatchQueue.main.async {
            if let w = v.window {
                w.isMovableByWindowBackground = true
                // red-team: dotted, reverse-DNS-style autosave key. AppKit
                // namespaces window frame defaults under
                // `NSWindow Frame <name>`; a generic key like "main" risks
                // colliding with other apps that share the prefs domain
                // (cmdline tools relinked under our bundle ID during dev).
                // Setting this here — after the NSView is parented — is
                // the canonical SwiftUI escape hatch; WindowGroup doesn't
                // expose a frame-autosave API until macOS 14.
                if w.frameAutosaveName.isEmpty {
                    w.setFrameAutosaveName("trove.mainWindow")
                }
            }
            context.coordinator.applyFloating(stage.floating)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { /* coordinator handles it */ }

    final class Coord {
        let stage: Stage
        weak var view: NSView?
        private var token: AnyCancellable?

        init(stage: Stage) {
            self.stage = stage
            self.token = stage.$floating.sink { [weak self] f in
                DispatchQueue.main.async { self?.applyFloating(f) }
            }
        }

        func applyFloating(_ floating: Bool) {
            guard let w = view?.window else { return }
            w.level = floating ? .floating : .normal
        }
    }
}

// ===========================================================================
// MARK: - Toast stack (Sonner-style)
// ===========================================================================

/// Bottom-trailing stack of transient toasts. Subscribes to `Stage.toasts`
/// and renders newest at the bottom. Each capsule has a leading kind-tint
/// stripe and an optional trailing action button.
struct ToastStackView: View {
    @EnvironmentObject var stage: Stage
    @State private var hoveredID: UUID? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(stage.toasts) { toast in
                ToastCapsule(
                    toast: toast,
                    isHovered: hoveredID == toast.id,
                    onHover: { hovering in
                        hoveredID = hovering ? toast.id : (hoveredID == toast.id ? nil : hoveredID)
                    },
                    onAction: {
                        toast.action?()
                        stage.dismiss(toast.id)
                    },
                    onClose: { stage.dismiss(toast.id) }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .frame(maxWidth: 380, alignment: .trailing)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                   ? nil : .spring(response: 0.32, dampingFraction: 0.82),
                   value: stage.toasts.map(\.id))
    }
}

private struct ToastCapsule: View {
    let toast: TroveToast
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onAction: () -> Void
    let onClose: () -> Void
    // Fix 23: solid fill fallback when Reduce Transparency is enabled.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tint: Color {
        switch toast.kind {
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        case .info:    return .secondary
        }
    }

    private var iconName: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Leading kind-tint stripe.
            Rectangle()
                .fill(tint)
                .frame(width: 3)
                .clipShape(Capsule())

            Image(systemName: iconName)
                .foregroundStyle(tint)
                .imageScale(.medium)

            Text(toast.message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let label = toast.actionLabel {
                Button(action: onAction) {
                    Text(label)
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tint)
                .accessibilityLabel("\(label) — \(toast.message)")
            }

            // Hover-revealed close affordance.
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(minWidth: 220, maxWidth: 380, alignment: .leading)
        .background(
            Group {
                if reduceTransparency {
                    // Fix 23: solid fill when Reduce Transparency is set.
                    Capsule(style: .continuous).fill(Color.troveBgElev)
                } else {
                    Capsule(style: .continuous).fill(.thinMaterial)
                }
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
    }
}

// ===========================================================================
// MARK: - Root navigation
// ===========================================================================

enum Pane: String, Hashable, CaseIterable {
    case stage      = "Stage"
    case history    = "History"
    case snippets   = "Snippets"
    case notes      = "Notes"
    case calc       = "Calculator"
    case xform      = "Text Tools"
    case color      = "Color"
    case qr         = "QR"
    case ocr        = "OCR"
    case imageTools = "Image Tools"
    case pdfTools   = "PDF"
    case fileHash   = "Hash"
    case recorder   = "Record"
    case winsnap    = "Snap"
    case alttab     = "Switcher"
    case cutpaste   = "Move Files"
    case finder     = "Finder"
    case procs      = "Processes"
    case overview   = "Overview"
    case scan       = "Scan"
    case clean      = "Clean"
    case sweep      = "Sweep"
    case library    = "Library"
    case rename     = "Rename"
    case snip       = "Snip"
    case keepAwake  = "Awake"
    case perms      = "Permissions"
    case log        = "Log"
    case gpu        = "GPU"
    case diskSpeed  = "Disk Speed"
    case network    = "Network"
    case account    = "Account"
    var icon: String {
        switch self {
        case .stage:      return "tray.full.fill"
        case .history:    return "clock.arrow.circlepath"
        case .snippets:   return "text.append"
        case .notes:      return "note.text"
        case .calc:       return "function"
        case .xform:      return "wand.and.stars"
        case .color:      return "eyedropper.halffull"
        case .qr:         return "qrcode"
        case .ocr:        return "doc.viewfinder"
        case .imageTools: return "photo.on.rectangle.angled"
        case .pdfTools:   return "doc.richtext"
        case .fileHash:   return "number"
        case .recorder:   return "record.circle"
        case .winsnap:    return "rectangle.split.2x1"
        case .alttab:     return "rectangle.stack"
        case .cutpaste:   return "scissors"
        case .finder:     return "macwindow.and.cursorarrow"
        case .procs:      return "cpu"
        case .overview:   return "internaldrive"
        case .scan:       return "magnifyingglass.circle"
        case .clean:      return "sparkles"
        case .sweep:      return "tray.and.arrow.down"
        case .library:    return "books.vertical"
        case .rename:     return "textformat.alt"
        case .snip:       return "scissors"
        case .keepAwake:  return "powerplug"
        case .perms:      return "lock.shield"
        case .log:        return "doc.text.magnifyingglass"
        case .gpu:        return "memorychip"
        case .diskSpeed:  return "speedometer"
        case .network:    return "network"
        case .account:    return "person.crop.circle"
        }
    }

    /// Group the pane lives under in the sidebar.
    var section: String {
        switch self {
        case .stage, .history, .snippets, .notes:                 return "Clipboard"
        case .calc, .xform:                                        return "Compute"
        case .recorder, .ocr, .color, .qr:                         return "Capture"
        case .imageTools, .pdfTools, .fileHash:                    return "Files"
        case .winsnap, .alttab, .cutpaste, .finder, .procs:        return "System"
        case .overview, .scan, .clean, .sweep:                     return "Storage"
        case .rename:                                               return "Files"
        case .snip:                                                 return "Capture"
        case .keepAwake, .perms, .log, .gpu, .network:              return "System"
        case .diskSpeed:                                            return "Storage"
        case .library:                                              return "App"
        case .account:                                              return "Profile"
        }
    }

    /// Whether the user can hide this pane from the sidebar. Stage is the
    /// core differentiator (don't bury it); everything else is toggleable.
    /// Re-showing hidden tools lives in Trove → Settings… (⌘,).
    var userHideable: Bool {
        switch self {
        case .stage: return false
        default:     return true
        }
    }

    /// One-line value-prop shown in the Customize panel.
    var blurb: String {
        switch self {
        case .stage:      return "Multi-clipboard staging — drop, paste, screenshot, copy all at once."
        case .history:    return "Persistent clipboard history with search, pin, and recovery."
        case .snippets:   return "Reusable text templates, copy with one click."
        case .notes:      return "Five colored tabs of always-on markdown scratchpad."
        case .calc:       return "Soulver-style tape: variables, units, live currency, smart percent."
        case .xform:      return "Chainable text transforms — Base64, JSON, JWT, regex, 40+ ops."
        case .color:      return "Pick from screen, palette from image, WCAG contrast checker."
        case .qr:         return "Generate QR codes from any text. Live preview."
        case .ocr:        return "Capture region → recognize text → optional translate, all local."
        case .imageTools: return "Convert / resize / compress images. HEIC, PNG, JPEG, WebP."
        case .pdfTools:   return "Merge, split, compress, rotate, OCR, watermark — iLovePDF-class, all local."
        case .fileHash:   return "Drag any file, get MD5/SHA1/SHA256 hashes simultaneously."
        case .recorder:   return "Screen recording with system audio + mic. ScreenCaptureKit."
        case .winsnap:    return "Aero-Snap-style window tiling with smart per-app presets."
        case .alttab:     return "AltTab-style window switcher with type-to-filter."
        case .cutpaste:   return "⌘X / ⌘V in Finder actually moves files (Windows behavior)."
        case .finder:     return "Show extensions, path bar, hidden files — Finder tweaks bundled."
        case .procs:      return "Live process list, kill, group by parent app."
        case .overview:   return "Disk usage at a glance with top-folders breakdown."
        case .scan:       return "Drill down into any folder's biggest sub-items."
        case .clean:      return "One-click cleanup of dev caches: npm/pnpm/brew/Xcode/etc."
        case .sweep:      return "Auto-organize ~/Downloads by age + type."
        case .library:    return "Recoverable cache of everything Trove has produced — re-open, re-edit, send to Stage."
        case .rename:     return "Mass file rename — find/replace, regex, sequence, date prefix, EXIF date."
        case .snip:       return "Screenshot with delay timer + multi-destination (Stage / Clipboard / file)."
        case .keepAwake:  return "Prevent display + system sleep with conditional rules (app, time, power)."
        case .perms:      return "Audit macOS privacy permissions, deep-link to System Settings."
        case .log:        return "Searchable view of macOS unified log with color-coded levels."
        case .gpu:        return "GPU utilization, thermal pressure, VRAM, fan RPM (where readable)."
        case .diskSpeed:  return "Sequential + random read/write benchmark per volume."
        case .network:    return "Per-process network throughput (Little Snitch read-only)."
        case .account:    return "Sign in with Apple, system identity, preferences."
        }
    }
}

// ===========================================================================
// MARK: - Sidebar visibility / customization
// ===========================================================================

/// Persists which panes the user has hidden from the sidebar. The default
/// state shows everything; hidden entries are stored as raw values in JSON.
@MainActor
final class PaneVisibilityStore: ObservableObject {
    static let shared = PaneVisibilityStore()

    @Published private(set) var hidden: Set<String> = []

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Trove", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sidebar.json")
    }

    private init() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard let data = boundedRead(url) else { return }
            let arr = try JSONDecoder().decode([String].self, from: data)
            // Fix 1: filter stale rawValues so removed panes don't persist.
            let valid = Set(Pane.allCases.map(\.rawValue))
            self.hidden = Set(arr).intersection(valid)
        } catch {
            // Quarantine corrupt file so next save doesn't clobber it.
            let ts = Int(Date().timeIntervalSince1970)
            let corrupt = url.deletingLastPathComponent()
                .appendingPathComponent("sidebar-corrupt-\(ts).json")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            let msg = "Sidebar layout file unreadable — backed up to \(corrupt.lastPathComponent)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SharedStore.stage.flash(msg, kind: .warning)
            }
        }
    }

    private func save() {
        let arr = Array(hidden).sorted()
        guard let data = try? JSONEncoder().encode(arr) else {
            SharedStore.stage.flash("Couldn't save sidebar visibility — encode failed", kind: .warning)
            return
        }
        let target = Self.fileURL
        let tmp = target.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            // Fix 2: surface write failures instead of silently discarding them.
            SharedStore.stage.flash("Couldn't save sidebar visibility — \(error.localizedDescription)", kind: .warning)
        }
    }

    func isVisible(_ pane: Pane) -> Bool {
        if !pane.userHideable { return true }
        return !hidden.contains(pane.rawValue)
    }

    func setVisible(_ pane: Pane, _ value: Bool) {
        guard pane.userHideable else { return }
        if value { hidden.remove(pane.rawValue) }
        else     { hidden.insert(pane.rawValue) }
        save()
    }

    func toggle(_ pane: Pane) { setVisible(pane, !isVisible(pane)) }

    func showAll() {
        hidden.removeAll()
        save()
    }

    func hideAllOptional() {
        hidden = Set(Pane.allCases.filter { $0.userHideable }.map { $0.rawValue })
        save()
    }
}

// ===========================================================================
// MARK: - Profile sync (iCloud Drive + manual export/import)
// ===========================================================================

/// Bundles the user's customizable settings (sidebar layout, snippets, notes,
/// prefs) into a single JSON blob the user can back up to iCloud Drive or a
/// file. Deliberately excludes the clipboard history (privacy), the storage
/// scan cache (machine-specific), and the SIA identity token (Keychain only).
@MainActor
final class ProfileSync: ObservableObject {
    static let shared = ProfileSync()

    @Published var lastBackup: Date?
    @Published var lastError: String?

    /// Files in Application Support that count as part of the user's profile.
    /// Anything not listed here is left alone on import.
    private static let bundledFiles = [
        "sidebar.json", "snippets.json", "notes.json", "account.json"
    ]

    private var appSupportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Trove", isDirectory: true)
    }

    private var iCloudDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Trove",
                                           isDirectory: true)
    }

    var iCloudAvailable: Bool {
        let parent = iCloudDir.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: parent.path)
    }

    private init() {
        // iCloud Drive paths route through the `bird` daemon — an
        // attributesOfItem call on a CloudDocs mount can block until the
        // daemon responds (200ms–∞ during a sync). Defer the probe off
        // main; `lastBackup` starts nil and patches in when ready.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let path = await MainActor.run { self.iCloudDir.appendingPathComponent("profile.json").path }
            let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            await MainActor.run { self.lastBackup = mod }
        }
    }

    /// Build a single JSON blob from the profile files.
    func snapshot() -> Data? {
        var bundle: [String: String] = [:]
        for name in Self.bundledFiles {
            let url = appSupportDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                bundle[name] = data.base64EncodedString()
            }
        }
        var wrapped: [String: Any] = [
            "schema": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "files": bundle
        ]
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            wrapped["appVersion"] = appVersion
        }
        return try? JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys])
    }

    /// Apply a profile blob — atomically replaces each known file. Caller
    /// should ask the user to relaunch Trove to pick up the new state.
    @discardableResult
    func apply(_ blob: Data) -> Bool {
        // red-team-sec: bound profile blob — a hostile iCloud-Drive plant or a
        // user-picked file could be gigabytes. JSONSerialization will OOM.
        let maxBlobBytes = 10 * 1024 * 1024
        if blob.count > maxBlobBytes {
            lastError = "Profile too large (\(blob.count / 1024) KB > \(maxBlobBytes / 1024) KB)"
            return false
        }
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let files = obj["files"] as? [String: String] else {
            lastError = "File is not a valid Trove profile"
            return false
        }
        // red-team-sec: per-entry cap so one malicious key can't blow memory.
        let maxFileBytes = 2 * 1024 * 1024
        // red-team: accumulate skip messages so the final `lastError = nil` at
        // the bottom of the do-block doesn't silently swallow per-entry caps.
        var skipMessages: [String] = []
        do {
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            for (name, b64) in files {
                guard Self.bundledFiles.contains(name),
                      let payload = Data(base64Encoded: b64) else { continue }
                if payload.count > maxFileBytes {
                    skipMessages.append("Entry '\(name)' exceeded \(maxFileBytes / 1024) KB — skipped")
                    continue
                }
                if payload.isEmpty { continue }
                let target = appSupportDir.appendingPathComponent(name)
                // red-team-sec: unpredictable tmp filename. The previous
                // deterministic `.import-tmp` could be pre-planted as a
                // symlink by a co-resident process — `payload.write(... .atomic)`
                // would resolve the symlink and write outside our dir.
                let tmp = appSupportDir.appendingPathComponent(
                    ".\(name).import-\(UUID().uuidString).tmp"
                )
                try payload.write(to: tmp, options: .atomic)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: target)
                }
            }
            lastError = skipMessages.isEmpty ? nil : skipMessages.joined(separator: "; ")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func backupToICloud() async -> Bool {
        guard let data = snapshot() else {
            lastError = "Couldn't snapshot profile"; return false
        }
        let dir = iCloudDir
        // Fix 3: move iCloud I/O off the main actor to avoid blocking when
        // the bird daemon is stalled.
        let result = await Task.detached(priority: .utility) { () -> Result<Date, Error> in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent("profile.json")
                let tmp = target.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: target)
                }
                return .success(Date())
            } catch {
                return .failure(error)
            }
        }.value
        // Hop back to main actor for @Published updates.
        await MainActor.run {
            switch result {
            case .success(let date):
                lastBackup = date
                lastError = nil
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
        if case .success = result { return true }
        return false
    }

    @discardableResult
    func restoreFromICloud() -> Bool {
        let url = iCloudDir.appendingPathComponent("profile.json")
        guard let data = try? Data(contentsOf: url) else {
            lastError = "No iCloud profile found yet — back up from another Mac first."
            return false
        }
        return apply(data)
    }

    func exportToFile(_ url: URL) -> Bool {
        guard let data = snapshot() else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func importFromFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Couldn't read \(url.lastPathComponent)"; return false
        }
        return apply(data)
    }
}

struct ProfileSyncCard: View {
    @ObservedObject private var sync = ProfileSync.shared
    @State private var showRestoreConfirm = false
    @State private var showRelaunchAlert = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.fill").foregroundStyle(.tint)
                    Text("Backup & sync").headerText()
                    Spacer()
                    if let last = sync.lastBackup {
                        Text("Last: \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Your sidebar layout, snippets, notes, and preferences travel between Macs via iCloud Drive. Clipboard history and your Apple ID token are intentionally excluded.")
                    .font(.callout).foregroundStyle(.secondary)

                if !sync.iCloudAvailable {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("iCloud Drive isn't enabled on this Mac. Turn it on in System Settings → Apple ID → iCloud → iCloud Drive.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            if await sync.backupToICloud() {
                                SharedStore.stage.flash("Backed up to iCloud Drive")
                            } else if let e = sync.lastError {
                                SharedStore.stage.flash("Backup failed: \(e)")
                            }
                        }
                    } label: {
                        Label("Backup now", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!sync.iCloudAvailable)

                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Label("Restore", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(!sync.iCloudAvailable)

                    Spacer()

                    Menu {
                        Button("Export to file…") { exportFile() }
                        Button("Import from file…") { importFile() }
                    } label: {
                        Label("File", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                }

                if let err = sync.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog("Restore from iCloud Drive?",
                            isPresented: $showRestoreConfirm,
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if sync.restoreFromICloud() {
                    SharedStore.stage.flash("Profile restored — relaunch to apply")
                    showRelaunchAlert = true
                } else if let e = sync.lastError {
                    SharedStore.stage.flash(e)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Overwrites your current sidebar, snippets, notes, and preferences with the iCloud backup. Trove will need to relaunch.")
        }
        .alert("Restart Trove", isPresented: $showRelaunchAlert) {
            Button("Relaunch now") { relaunchApp() }
            Button("Later") {}
        } message: {
            Text("Your settings are imported but the running app is using the old ones. Relaunch picks up the new state.")
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "trove-profile.json"
        if panel.runModal() == .OK, let url = panel.url {
            if sync.exportToFile(url) {
                SharedStore.stage.flash("Profile exported")
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            if sync.importFromFile(url) {
                SharedStore.stage.flash("Profile imported — relaunch to apply")
                showRelaunchAlert = true
            } else if let e = sync.lastError {
                SharedStore.stage.flash(e)
            }
        }
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        do { try task.run() } catch { /* fall through */ }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

struct CustomizeView: View {
    @ObservedObject private var store = PaneVisibilityStore.shared

    private static let sectionOrder = ["Clipboard", "Compute", "Capture", "Files", "System", "Storage", "Profile"]

    private var grouped: [(String, [Pane])] {
        let toggleable = Pane.allCases.filter { $0.userHideable }
        var byKey: [String: [Pane]] = [:]
        for p in toggleable { byKey[p.section, default: []].append(p) }
        return Self.sectionOrder.compactMap { key in
            byKey[key].map { (key, $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VersionBannerCard()
                LaunchAtLoginCard()
                AccentPickerCard()

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Make Trove yours")
                            // red-team: fixed 22pt point size ignored Dynamic
                            // Type. Use .title2 text style so users with
                            // larger system font sizes see a proportionally
                            // larger heading.
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                        Text("Hide tools you don't use. Stage and this panel can't be hidden. Settings persist across launches.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(grouped, id: \.0) { (section, panes) in
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(section).headerText()
                                Spacer()
                                Text("\(panes.filter { store.isVisible($0) }.count) / \(panes.count) shown")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 6)
                            ForEach(panes, id: \.rawValue) { p in
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: p.icon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.rawValue).font(.body.weight(.medium))
                                        Text(p.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { store.isVisible(p) },
                                        set: { store.setVisible(p, $0) }
                                    ))
                                    .labelsHidden()
                                }
                                .padding(.vertical, 8)
                                if p != panes.last { Divider() }
                            }
                        }
                    }
                }

                HStack {
                    Button("Show every tool") { store.showAll() }
                    Button("Hide everything optional") { store.hideAllOptional() }
                    Spacer()
                }
                .padding(.top, 4)

                // Global hotkey configuration (⌘⇧2 → Stage screenshot by default,
                // rebindable, persists across launches).
                HotkeySettingsCard()

                // Auto-update checker (default ON, throttled to 6h).
                UpdateCheckerCard()

                // Backup & sync (iCloud Drive + file export/import).
                ProfileSyncCard()

                DiagnosticsCard()
            }
            .padding(24)
        }
        .navigationTitle("Customize")
        .navigationSubtitle("\(Pane.allCases.filter { $0.userHideable }.count - store.hidden.count) of \(Pane.allCases.filter { $0.userHideable }.count) optional tools visible")
    }
}

// ===========================================================================
// MARK: - Launch at Login
// ===========================================================================

/// Wraps `SMAppService.mainApp` so the rest of the app can drive a SwiftUI
/// toggle without touching ServiceManagement directly. Every public method
/// degrades silently (NSLog + no-op) on macOS 12 (where `SMAppService` is
/// unavailable) — we don't want a missing API to crash a release build.
///
/// `status` is `@Published` so the toggle in Settings reflects external
/// changes (user disabled the login item via System Settings → General →
/// Login Items, etc.) the next time the Settings window opens.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()
    @Published var enabled: Bool = false

    private init() {
        refresh()
    }

    func refresh() {
        if #available(macOS 13, *) {
            enabled = SMAppService.mainApp.status == .enabled
        } else {
            enabled = false
        }
    }

    func set(_ on: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            enabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            NSLog("LaunchAtLogin: %@", "\(error)")
            // Re-read whatever the system thinks the state actually is so
            // the toggle doesn't lie to the user about the success/failure.
            refresh()
        }
    }
}

/// Bounded local file read. Returns nil if:
///   • the file doesn't exist,
///   • the file is larger than `maxBytes` (defaults to 16 MB — generous
///     for any prefs JSON Trove writes; refuses to load anything bigger
///     so a corrupt or hostile blob can't OOM the app),
///   • the read or stat throws for any reason.
/// Pair with the existing per-store "quarantine corrupt JSON" pattern —
/// callers should still try-decode and quarantine on decode failure;
/// this just adds an upstream memory safety net.
func boundedRead(_ url: URL, maxBytes: Int = 16 * 1024 * 1024) -> Data? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return nil }
    if let attrs = try? fm.attributesOfItem(atPath: url.path),
       let size = (attrs[.size] as? NSNumber)?.intValue,
       size > maxBytes {
        NSLog("boundedRead: refusing %@ — %d bytes > %d cap", url.lastPathComponent, size, maxBytes)
        return nil
    }
    return try? Data(contentsOf: url)
}

/// Hosts the Settings window content. Reads the accent choice from
/// `@AppStorage` so flipping the swatch picker re-tints both the Settings
/// window *and* (via the same key) the main window — a single source of truth.
struct TroveSettingsScene: View {
    @AppStorage("trove.accent") private var accentRaw: String = TroveAccentChoice.white.rawValue
    var body: some View {
        CustomizeView()
            .frame(minWidth: 640, minHeight: 520)
            .tint(TroveAccentChoice(rawValue: accentRaw)?.color ?? .troveAccentAlt)
            .background(TroveAppBackground())
    }
}

/// Big, hard-to-miss version banner at the top of Settings. Shows the
/// installed version, bundle id, and a direct link to the GitHub release
/// page so the user can always confirm which build they're running and
/// where to grab the next one. Also: tappable to copy the version string
/// (handy when the user is filing an issue).
struct VersionBannerCard: View {
    @State private var copied = false
    var version: String { UpdateChecker.currentVersion() ?? "dev" }
    var bundleID: String { Bundle.main.bundleIdentifier ?? "com.arnavgoel.trove" }
    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Trove")
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                        Text("v\(version)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.troveCardFill, in: Capsule())
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("Trove \(version)", forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            .help("Click to copy")
                        if copied {
                            Text("Copied").font(.caption).foregroundStyle(.secondary).transition(.opacity)
                        }
                    }
                    Text(bundleID).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if let url = URL(string: "https://github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName)/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Releases", systemImage: "arrow.up.right.square")
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Quick Switcher (⌘K palette)
// ===========================================================================

/// One row in the switcher's result list. Either jumps to a pane or runs a
/// closure (for command-style actions like "Open Settings"). Closures are
/// captured by the items array, which lives only while the sheet is open
/// — no retain cycle.
struct QuickSwitcherItem: Identifiable {
    let id = UUID()
    let label: String
    let detail: String?
    let icon: String
    let action: Action
    enum Action {
        case openPane(Pane)
        case run(() -> Void)
    }
    /// Score a query against this item. Lower is better; nil = no match.
    /// Substring match wins over acronym match wins over fuzzy.
    func score(_ q: String) -> Int? {
        let needle = q.lowercased()
        let hay = label.lowercased()
        if needle.isEmpty { return 100 }
        if hay == needle { return 0 }
        if hay.hasPrefix(needle) { return 5 }
        if hay.contains(needle) { return 10 }
        // Acronym match: "ph" matches "Permissions Help" via initials.
        let initials = hay.split(separator: " ").compactMap { $0.first }
        let initialStr = String(initials)
        if initialStr.hasPrefix(needle) { return 15 }
        // Fuzzy: every needle char appears in order in hay.
        var hi = hay.startIndex
        for c in needle {
            guard let next = hay[hi...].firstIndex(of: c) else { return nil }
            hi = hay.index(after: next)
        }
        return 25
    }
}

struct QuickSwitcherView: View {
    @Binding var isOpen: Bool
    @State private var query: String = ""
    @State private var selected: Int = 0
    // Fix 22: cache allItems and results so they're not recomputed on every body invocation.
    @State private var allItems: [QuickSwitcherItem] = []
    @State private var results: [QuickSwitcherItem] = []
    @State private var debounceTask: Task<Void, Never>? = nil

    private func buildAllItems() -> [QuickSwitcherItem] {
        var items: [QuickSwitcherItem] = []
        let visibility = PaneVisibilityStore.shared
        for p in Pane.allCases where visibility.isVisible(p) {
            items.append(QuickSwitcherItem(
                label: p.rawValue,
                detail: p.section,
                icon: p.icon,
                action: .openPane(p)
            ))
        }
        items.append(QuickSwitcherItem(
            label: "Open Settings",
            detail: "Customize • ⌘,",
            icon: "gearshape",
            action: .run { openSettingsWindow() }
        ))
        items.append(QuickSwitcherItem(
            label: "Check for Updates",
            detail: "GitHub Releases",
            icon: "arrow.triangle.2.circlepath",
            action: .run { Task { await UpdateChecker.shared.check(quiet: false) } }
        ))
        items.append(QuickSwitcherItem(
            label: "Clear Stage",
            detail: "Remove all staged items",
            icon: "tray",
            action: .run { SharedStore.stage.clear() }
        ))
        items.append(QuickSwitcherItem(
            label: "Paste into Stage",
            detail: "From clipboard",
            icon: "doc.on.clipboard",
            action: .run { SharedStore.stage.pasteFromClipboard() }
        ))
        items.append(QuickSwitcherItem(
            label: "Capture Screenshot",
            detail: "Selection to Stage",
            icon: "camera.viewfinder",
            action: .run { SharedStore.stage.captureScreenshot() }
        ))
        return items
    }

    private func updateResults(for q: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            // No debounce needed for a synchronous in-memory score (tiny set),
            // but wrapping in Task lets us cancel on rapid keystrokes.
            guard !Task.isCancelled else { return }
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let items = allItems
            let scored = items.compactMap { item -> (QuickSwitcherItem, Int)? in
                guard let s = item.score(trimmed) else { return nil }
                return (item, s)
            }
            let r = scored.sorted { $0.1 < $1.1 }.map { $0.0 }
            await MainActor.run { results = r }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                TextField("Jump to a pane or run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onSubmit { execute(at: selected) }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let res = results
                        if res.isEmpty {
                            HStack {
                                Spacer()
                                Text("No matches")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.vertical, 24)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(res.enumerated()), id: \.element.id) { idx, item in
                                row(item: item, isSelected: idx == selected)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture { execute(at: idx) }
                                    .onHover { hovering in
                                        if hovering { selected = idx }
                                    }
                            }
                        }
                    }
                }
                .onChange(of: selected) { _, new in
                    proxy.scrollTo(new, anchor: .center)
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack(spacing: 14) {
                tip("↑↓", "Navigate")
                tip("⏎", "Open")
                tip("Esc", "Dismiss")
                Spacer()
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(TroveAppBackground())
        .onAppear {
            selected = 0
            // Fix 22: populate allItems once on appear; update results for empty query.
            allItems = buildAllItems()
            updateResults(for: query)
        }
        .onChange(of: query) { _, newValue in
            selected = 0
            updateResults(for: newValue)
        }
        .background {
            // Hidden key handlers via Button + keyboardShortcut.
            Group {
                Button("") { moveSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { moveSelection(+1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { isOpen = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .hidden()
        }
    }

    @ViewBuilder
    private func row(item: QuickSwitcherItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .frame(width: 22).foregroundStyle(isSelected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(isSelected ? Color.white.opacity(0.7) : .secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "return")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.troveAccentSky.opacity(0.85) : Color.clear)
    }

    @ViewBuilder
    private func tip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.troveCardFill, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func execute(at idx: Int) {
        let res = results
        guard idx >= 0, idx < res.count else { return }
        let item = res[idx]
        isOpen = false
        // Defer the action one runloop turn so the sheet dismissal animation
        // doesn't race against the pane switch / window opening.
        DispatchQueue.main.async {
            switch item.action {
            case .openPane(let p): switchToPane(p)
            case .run(let f):      f()
            }
        }
    }
}

/// Launch-at-login toggle for Settings.
struct LaunchAtLoginCard: View {
    @ObservedObject private var lal = LaunchAtLogin.shared
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "power.circle")
                    .font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login").headerText()
                    Text("Start Trove automatically when you log in. Toggle off any time; you can also manage this from System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { lal.enabled }, set: { lal.set($0) }))
                    .labelsHidden()
            }
        }
        .onAppear { lal.refresh() }
    }
}

/// Diagnostics: surface recent crash reports so the user doesn't have to
/// dig through Console.app, plus a hard-reset action (clears UserDefaults
/// for the bundle so a corrupt pref state can't keep crash-looping) and a
/// "Report Issue" link that opens a pre-filled GitHub issue with the
/// installed version + macOS info.
struct DiagnosticsCard: View {
    @State private var recent: [RecentCrash] = []
    @State private var resetConfirm = false

    struct RecentCrash: Identifiable {
        let id = UUID()
        let path: URL
        let date: Date
        let symbol: String
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "stethoscope").foregroundStyle(.tint)
                    Text("Diagnostics").headerText()
                    Spacer()
                    if recent.isEmpty {
                        Text("No recent crashes").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(recent.count) recent").font(.caption).foregroundStyle(.orange)
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recent.prefix(5)) { c in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.caption)
                                Text(c.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption.monospaced())
                                Text(c.symbol)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([c.path])
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Button {
                        loadRecent()
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button {
                        let url = URL(string: "https://github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName)/issues/new?title=\(reportTitle)&body=\(reportBody)")
                        if let url { NSWorkspace.shared.open(url) }
                    } label: { Label("Report Issue", systemImage: "ladybug") }
                    Spacer()
                    Button(role: .destructive) {
                        resetConfirm = true
                    } label: { Label("Reset Trove…", systemImage: "trash") }
                        .help("Clear all Trove preferences. Notes, snippets, and outputs library are preserved.")
                }
            }
        }
        .onAppear { loadRecent() }
        .confirmationDialog("Reset Trove?",
                             isPresented: $resetConfirm,
                             titleVisibility: .visible) {
            Button("Reset preferences", role: .destructive) { performReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears Trove's UserDefaults — selected pane, accent, sidebar visibility, hotkey bindings, and the auto-update cache. Notes, snippets, and outputs library on disk are not touched.")
        }
    }

    private var reportTitle: String {
        let v = UpdateChecker.currentVersion() ?? "dev"
        return "Issue%20in%20Trove%20v\(v)".replacingOccurrences(of: " ", with: "%20")
    }

    private var reportBody: String {
        let v = UpdateChecker.currentVersion() ?? "dev"
        // Fix 5: strip macOS and Machine from the pre-filled body — privacy
        // policy states no usage data leaves the device on launch/idle; even
        // though this is user-initiated the auto-fill is undisclosed.
        let body = """
        **Version**: Trove \(v)

        **What happened**:


        **What I expected**:


        **Steps to reproduce**:

        """
        return body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    private func loadRecent() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400) // last 7 days
        let crashes: [RecentCrash] = entries
            .filter { $0.lastPathComponent.hasPrefix("Trove-") && $0.lastPathComponent.hasSuffix(".ips") }
            .compactMap { url -> RecentCrash? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard date >= cutoff else { return nil }
                let symbol = Self.extractTopSymbol(from: url) ?? "unknown"
                return RecentCrash(path: url, date: date, symbol: symbol)
            }
            .sorted { $0.date > $1.date }
        recent = Array(crashes.prefix(10))
    }

    /// Parse just the first symbol of the triggered thread out of an .ips
    /// file. Defensive — any parse failure returns nil; we never crash
    /// trying to render a crash log.
    private static func extractTopSymbol(from url: URL) -> String? {
        guard let data = boundedRead(url, maxBytes: 2 * 1024 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // .ips files: first line is a header JSON, rest is the body JSON.
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        // The triggered thread's top frame's symbol — find the first
        // `"symbol" : "X"` after `"triggered": true`. Cheap string search.
        let body = String(parts[1])
        guard let triggerRange = body.range(of: "\"triggered\":true") ??
              body.range(of: "\"triggered\" : true") else { return nil }
        let after = body[triggerRange.upperBound...]
        guard let symRange = after.range(of: "\"symbol\"") else { return nil }
        let sym = after[symRange.upperBound...]
        guard let openQuote = sym.range(of: "\"") else { return nil }
        let symStart = sym[openQuote.upperBound...]
        guard let closeQuote = symStart.range(of: "\"") else { return nil }
        return String(symStart[..<closeQuote.lowerBound])
    }

    private func performReset() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.arnavgoel.trove"
        // Persist files (Notes, Snippets, Outputs Library) are in
        // Application Support; we intentionally do NOT touch those.
        // Reset just the UserDefaults domain.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        // Reload to defaults: write a sane selected pane so next launch
        // doesn't pick a stale one that crashes.
        UserDefaults.standard.set(Pane.stage.rawValue, forKey: "trove.selectedPane")
        NSLog("Trove: preferences reset by user")
    }
}

/// Swatch picker for `TroveAccentChoice`. Lives at the top of `CustomizeView`
/// so the user finds it on first run; writes through `@AppStorage` so both
/// windows re-tint live.
struct AccentPickerCard: View {
    @AppStorage("trove.accent") private var accentRaw: String = TroveAccentChoice.white.rawValue
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Accent").headerText()
                    Spacer()
                    Text(TroveAccentChoice(rawValue: accentRaw)?.label ?? "Magenta")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    ForEach(TroveAccentChoice.allCases) { choice in
                        Button {
                            accentRaw = choice.rawValue
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 30, height: 30)
                                if accentRaw == choice.rawValue {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .frame(width: 40, height: 40)
                            .help(choice.label)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                Text("Tints sidebar selection, buttons, toggles, and accent icons. Picks live across both windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Opens the standard macOS Settings window. The selector renamed in macOS
/// 14 (`showSettingsWindow:` vs the older `showPreferencesWindow:`), so dispatch
/// on availability — sending the wrong one is a silent no-op.
@MainActor private func openSettingsWindow() {
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

/// Switch the active sidebar pane from a menu command. Writes through to
/// the same `UserDefaults` key that `@AppStorage("trove.selectedPane")` reads
/// in `RootView`, so the binding picks up the change automatically.
@MainActor private func switchToPane(_ pane: Pane) {
    UserDefaults.standard.set(pane.rawValue, forKey: "trove.selectedPane")
}

struct RootView: View {
    // Persist the active pane across launches. red-team: store the rawValue
    // (a String) not the enum directly — @AppStorage can't bridge a custom
    // enum without bespoke RawRepresentable plumbing, and any future Pane
    // rename would silently mis-decode an old value. Keeping it as a string
    // means an obsolete rawValue cleanly degrades to .stage via the resolver.
    @AppStorage("trove.selectedPane") private var paneRaw: String = Pane.stage.rawValue
    @State private var quickSwitcherOpen = false
    // App-wide tint choice (Settings → Accent). Default to magenta after the
    // warm-orange phase was retired for being too loud across 30+ panes.
    @AppStorage("trove.accent") private var accentRaw: String = TroveAccentChoice.white.rawValue
    // Persist sidebar visibility as a raw int (0 = all, 1 = doubleColumn,
    // 2 = detailOnly). NavigationSplitViewVisibility isn't @AppStorage-bridgable
    // directly, so we shadow it through this int and resolve in a binding.
    @AppStorage("trove.sidebar.visibility") private var sidebarVisibilityRaw: Int = 0
    @EnvironmentObject var stage: Stage
    @ObservedObject private var visibility = PaneVisibilityStore.shared

    /// Sidebar section order. Sections with zero visible panes are hidden.
    private static let sectionOrder = [
        "Clipboard", "Compute", "Capture", "Files",
        "System", "Storage", "Profile", "App"
    ]

    private var paneBinding: Binding<Pane?> {
        Binding(
            get: { Pane(rawValue: paneRaw) ?? .stage },
            set: { paneRaw = ($0 ?? .stage).rawValue }
        )
    }

    private var sidebarVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch sidebarVisibilityRaw {
                case 1:  return .doubleColumn
                case 2:  return .detailOnly
                default: return .all
                }
            },
            set: { v in
                switch v {
                case .doubleColumn: sidebarVisibilityRaw = 1
                case .detailOnly:   sidebarVisibilityRaw = 2
                default:            sidebarVisibilityRaw = 0
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
          VStack(spacing: 0) {
            List(selection: paneBinding) {
                ForEach(Self.sectionOrder, id: \.self) { section in
                    let panesInSection = Pane.allCases.filter {
                        $0.section == section && visibility.isVisible($0)
                    }
                    if !panesInSection.isEmpty {
                        Section(section) {
                            ForEach(panesInSection, id: \.self) { p in
                                Label(p.rawValue, systemImage: p.icon)
                                    .tag(p)
                                    .contextMenu {
                                        if p.userHideable {
                                            Button {
                                                visibility.setVisible(p, false)
                                                if paneRaw == p.rawValue { paneRaw = Pane.stage.rawValue }
                                            } label: {
                                                Label("Hide from sidebar", systemImage: "eye.slash")
                                            }
                                        }
                                        Button {
                                            openSettingsWindow()
                                        } label: {
                                            Label("Customize sidebar…", systemImage: "slider.horizontal.3")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // Sidebar footer — always-visible version + quick Settings.
            // Pinned to the bottom of the sidebar column so the user can
            // see at a glance which build they're on, without having to
            // open the About dialog or Settings.
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 11))
                Text("Trove")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(UpdateChecker.currentVersion().map { "v\($0)" } ?? "dev")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          }
          .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                switch Pane(rawValue: paneRaw) ?? .stage {
                case .stage:      StageView()
                case .history:    HistoryView()
                case .snippets:   SnippetsView()
                case .notes:      NotesView()
                case .calc:       CalcView()
                case .xform:      XformView()
                case .color:      ColorToolView()
                case .qr:         QRView()
                case .ocr:        OCRView()
                case .imageTools: ImageToolsView()
                case .pdfTools:   PDFToolsView()
                case .fileHash:   FileHashView()
                case .recorder:   RecView()
                case .winsnap:    WinSnapView()
                case .alttab:     AltTabView()
                case .cutpaste:   CutPasteView()
                case .finder:     FinderTweaksView()
                case .procs:      ProcView()
                case .overview:   OverviewView()
                case .scan:       BigScanView()
                case .clean:      CleanView()
                case .sweep:      SweepView()
                case .library:    OutputsLibraryView()
                case .rename:     RenameView()
                case .snip:       SnipView()
                case .keepAwake:  KeepAwakeView()
                case .perms:      PermissionsView()
                case .log:        LogViewerView()
                case .gpu:        GPUMonitorView()
                case .diskSpeed:  DiskSpeedView()
                case .network:    NetworkMonitorView()
                case .account:    AccountView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Detail surface stays transparent so `TroveAppBackground` shows
            // through. See the doc comment on `TroveAppBackground` — do NOT
            // re-introduce a per-detail background here.
            .background(.clear)
        }
        .background(TroveAppBackground())
        // App-wide accent. Reads the user's choice from `@AppStorage` so
        // flipping the swatch in Settings re-tints every control live. Do
        // NOT re-tint per-pane; see the coherence rules above.
        .tint(TroveAccentChoice(rawValue: accentRaw)?.color ?? .troveAccentAlt)
        // ⌘K — quick switcher. The keyboard shortcut is bound on the View
        // menu's "Quick Switcher…" command, which posts a notification we
        // listen to here. This keeps the binding in exactly one place (the
        // menu) — no duplicate hidden Button + Command Group entry.
        .onReceive(NotificationCenter.default.publisher(for: .troveOpenQuickSwitcher)) { _ in
            quickSwitcherOpen = true
        }
        .sheet(isPresented: $quickSwitcherOpen) {
            QuickSwitcherView(isOpen: $quickSwitcherOpen)
        }
        .overlay(alignment: .bottomTrailing) {
            ToastStackView()
                .environmentObject(stage)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
                .allowsHitTesting(true)
        }
        .onOpenURL { url in handleURL(url) }
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "trove" else { return }
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var q: [String: String] = [:]
        for it in comps?.queryItems ?? [] { if let v = it.value { q[it.name] = v } }

        switch action {
        case "show":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        case "capture":
            // red-team-sec: gate state-changing actions on Trove being
            // frontmost so a drive-by URL from a website can't pop the
            // screenshot crosshair unannounced.
            guard Self.isTroveFrontmost() else {
                stage.flash("Capture refused — Trove must be frontmost")
                return
            }
            paneRaw = Pane.stage.rawValue
            stage.captureScreenshot()
        case "paste":
            paneRaw = Pane.stage.rawValue
            stage.pasteFromClipboard()
            stage.flash("Pasted from clipboard via CLI")
        case "copy", "copy-text":
            // red-team-sec: clipboard-hijack mitigation. Website firing
            // `trove://add?type=text&value=rm -rf` then `trove://copy-text`
            // would silently take over the pasteboard. Require frontmost.
            guard Self.isTroveFrontmost() else {
                stage.flash("Copy refused — Trove must be frontmost")
                return
            }
            if action == "copy-text" { stage.copyAllAsText() } else { stage.copyAllAsFiles() }
        case "clear":
            stage.clear()
            stage.flash("Stage cleared")
        case "add":
            paneRaw = Pane.stage.rawValue
            let type = q["type"] ?? "file"
            if type == "text", let v = q["value"] {
                // red-team-sec: bound text size — website firing 10 MB of
                // text would balloon the in-memory Stage.
                if v.utf8.count > 1_000_000 {
                    stage.flash("CLI text refused: too large (>1 MB)")
                    return
                }
                stage.addText(v)
                stage.flash("Added text from CLI")
            } else if type == "file", let p = q["path"] {
                Self.stageFileSafely(path: p)
            }
        default:
            break
        }
    }

    /// True iff Trove is the frontmost app — gate state-changing URL actions.
    static func isTroveFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Bundle.main.bundleIdentifier
    }

    /// Pure validation half of `stageFileSafely`. Returns nil if the path is
    /// safe to stage, otherwise a human-readable rejection reason. Split out
    /// so tests can exercise the policy without poking SharedStore.stage.
    static func stageFileValidation(path p: String) -> String? {
        let blockedPrefixes = ["/dev/", "/proc/", "/sys/", "/private/var/run/"]
        for pfx in blockedPrefixes where p.hasPrefix(pfx) {
            return "CLI path refused: \(pfx) blocked"
        }
        let fileURL = URL(fileURLWithPath: p)
        guard let vals = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey
        ]), vals.isRegularFile == true else {
            return "CLI path refused: not a regular file"
        }
        let size = Int64(vals.fileSize ?? 0)
        if size > 200 * 1024 * 1024 {
            return "CLI path refused: file >200 MB"
        }
        return nil
    }

    /// Validate + stage a file referenced via `trove://add?type=file&path=…`.
    /// Without these guards a drive-by URL could feed paths like `/dev/zero`,
    /// a hung SMB mount, or a 50 GB sparse file into `NSImage(contentsOf:)`
    /// — which reads to EOF on the main actor → app freeze / OOM.
    static func stageFileSafely(path p: String) {
        if let reason = stageFileValidation(path: p) {
            SharedStore.stage.flash(reason)
            return
        }
        let fileURL = URL(fileURLWithPath: p)
        // Read off the main actor so slow disks / hung mounts don't freeze UI.
        Task.detached(priority: .userInitiated) {
            let img: NSImage? = NSImage(contentsOf: fileURL)
            await MainActor.run {
                if let img = img {
                    SharedStore.stage.addImage(img)
                    SharedStore.stage.flash("Added image from CLI")
                } else if FileManager.default.fileExists(atPath: p) {
                    SharedStore.stage.addFile(fileURL)
                    SharedStore.stage.flash("Added file from CLI")
                } else {
                    SharedStore.stage.flash("CLI file no longer exists")
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Shared UI helpers
// ===========================================================================

extension Int64 {
    var human: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: self)
    }
}

// ===========================================================================
// MARK: - Design tokens (extracted from the trove-site renders)
// ---------------------------------------------------------------------------
// Backgrounds are near-black with subtle gradient. Cards use 1px translucent
// strokes, near-black panel fills, generous radii, and warm shadows.
// Accent dots / glows use the site's warm-orange (#FF7A45) and magenta
// (#B27CFF) — pulled verbatim from `app/globals.css`.
//
// COHERENCE RULES (read before adding a new pane):
//   1. NEVER set a page-level background. `TroveAppBackground` is mounted
//      once in `RootView` and spans the whole window. Pane content sits on
//      top of it transparently. A pane with `.background(Color.troveBg)` is
//      a regression.
//   2. ACCENT IS WARM-ORANGE, not system blue. The app-wide `.tint(
//      Color.troveAccent)` is set in `RootView` — do not pass an explicit
//      `.tint(.blue)` to a child view.
//   3. ELEVATED SURFACES (cards, panels, popovers) use the palette tokens
//      below (`troveCardFill` / `troveCardStroke` / `troveCardSolid` for the
//      Reduce-Transparency fallback), never raw `Color.white.opacity(...)`
//      or `Color.gray`. If you need a new surface fill, add a token here.
//   4. CORNER RADII are generous (12-18pt for cards, full capsule for pills,
//      8-10pt for inline chips). Match the site, not native Mac controls.
//   5. SUB-PANELS within a pane (e.g. Notes preview, Calc results column)
//      stay transparent so the global gradient reads through. If you need a
//      visual seam, use a hairline `troveLine` divider, not a contrasting
//      fill.
// ===========================================================================

extension Color {
    /// Page background — `--color-bg` (#08080B) in globals.css.
    static let troveBg          = Color(red: 0.031, green: 0.031, blue: 0.043)
    /// Elevated surface — `--color-bg-elev` (#0E0E12).
    static let troveBgElev      = Color(red: 0.055, green: 0.055, blue: 0.071)
    /// Card stroke — `rgba(255,255,255,0.08)` matches every visual's
    /// `border-white/[0.06]` / `border-white/[0.08]` band.
    static let troveCardStroke  = Color.white.opacity(0.08)
    /// Card fill — translucent overlay (`rgba(255,255,255,0.035)`); pairs with
    /// `.thinMaterial` for the Linear-style glass look.
    static let troveCardFill    = Color.white.opacity(0.035)
    /// Solid fallback when Reduce Transparency is on. ~`#0E0F14`.
    static let troveCardSolid   = Color(red: 0.055, green: 0.060, blue: 0.082)
    /// `--color-fg-dim` (#A1A1AA) for body copy.
    static let troveFgDim       = Color(red: 0.631, green: 0.631, blue: 0.667)
    /// `--color-fg-mute` (#71717A) for captions / hotkey labels.
    static let troveFgMute      = Color(red: 0.443, green: 0.443, blue: 0.478)
    /// Hairline divider — `--color-line` (#1F1F24).
    static let troveLine        = Color(red: 0.122, green: 0.122, blue: 0.141)
    /// Warm orange accent — `--color-accent` (#FF7A45).
    static let troveAccent      = Color(red: 1.0,   green: 0.478, blue: 0.271)
    /// Magenta accent — `--color-accent-2` (#B27CFF).
    static let troveAccentAlt   = Color(red: 0.698, green: 0.486, blue: 1.0)
    /// Sky accent — `--color-accent-3` (#4CB8FF).
    static let troveAccentSky   = Color(red: 0.298, green: 0.722, blue: 1.0)
}

// MARK: - Accessibility header trait helper
// ---------------------------------------------------------------------------
// Fix 26: single modifier that combines .font(.headline) + .accessibilityAddTraits(.isHeader)
// so VoiceOver rotor "Headings" navigation works. Use `.headerText()` in place of
// `.font(.headline)` at all pane / section / card title sites.

extension View {
    /// Apply headline font and expose this text as an accessibility heading
    /// so VoiceOver's "Headings" rotor can navigate to it.
    func headerText() -> some View {
        self
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Accent choice (user-selectable in Settings)
// ---------------------------------------------------------------------------
// The system tint cascades to sidebar selection rings, button capsules,
// toggles, progress views, and most SF-typed icons via `.foregroundStyle(.tint)`.
// We let the user pick among the three palette accents + a "white" mode that
// renders everything in the foreground color (Linear / Things-style flat UI).
// Persisted via `@AppStorage("trove.accent")`; the canonical default is
// `.magenta` — warm-orange was overtuned and felt loud across 30+ panes.
enum TroveAccentChoice: String, CaseIterable, Identifiable {
    case magenta = "magenta"
    case sky     = "sky"
    case warm    = "warm"
    case white   = "white"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .magenta: return "Magenta"
        case .sky:     return "Sky"
        case .warm:    return "Warm"
        case .white:   return "Neutral"
        }
    }

    var color: Color {
        switch self {
        case .magenta: return .troveAccentAlt
        case .sky:     return .troveAccentSky
        case .warm:    return .troveAccent
        case .white:   return .white
        }
    }

    /// Reads the current choice from `UserDefaults`, falling back to `.white`
    /// if no value is stored or the stored value no longer maps to a case.
    /// `.white` is the canonical default — monochrome reads as designed-by-a-
    /// person; chromatic accents in dark mode kept tripping the "AI startup"
    /// pattern recognizer.
    static var current: TroveAccentChoice {
        let raw = UserDefaults.standard.string(forKey: "trove.accent") ?? Self.white.rawValue
        return TroveAccentChoice(rawValue: raw) ?? .white
    }
}

// MARK: App background — single source of truth
// ---------------------------------------------------------------------------
// `TroveAppBackground` is the ONLY place the app paints its page chrome.
// It is mounted ONCE behind the NavigationSplitView in `RootView` (so it spans
// sidebar + detail uniformly) and every individual pane is required to render
// transparently on top of it (sidebar: `.scrollContentBackground(.hidden)`;
// detail: `.background(.clear)`). Do NOT add per-pane backgrounds — if a pane
// needs a tint, layer it semi-transparently so this gradient still reads. The
// goal is that switching panes never visually swaps the canvas underneath.
//
// On Reduce Transparency we collapse to flat `Color.troveBg` so the gradient
// never reads as visual noise for vestibular-sensitive users.
struct TroveAppBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            Color.troveBg.ignoresSafeArea()
        } else {
            ZStack {
                Color.troveBg
                // Mirrors the trove-site hero gradient
                // (`radial-gradient(120% 80% at 50% 0%, rgba(255,122,69,0.10),
                // transparent 60%)`). LinearGradient top→center reads close
                // enough at NavigationSplitView aspect ratios.
                LinearGradient(
                    colors: [Color.troveAccent.opacity(0.08), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension Font {
    /// Small-caps section eyebrow — matches the `text-[11px] uppercase
    /// tracking-[0.18em]` label used on every visual. SwiftUI doesn't expose
    /// letter-spacing on `Font`; pair with `.tracking(1.6)` at the call site.
    static let trovePaneLabel   = Font.system(size: 11, weight: .medium, design: .default)
    /// Headline number (Sweep "15.9 GB", Thermals "62"). `tracking(-0.5)`
    /// at the call site approximates `-tracking-tight`.
    static let troveHeadline    = Font.system(size: 28, weight: .semibold, design: .default)
    /// Standard row title — 13 px matches the renders' `text-[13px]`.
    static let troveRowTitle    = Font.system(size: 13, weight: .medium, design: .default)
    /// Row body / preview — `text-[11.5px]` in renders.
    static let troveRowBody     = Font.system(size: 11.5, weight: .regular, design: .default)
    /// Caption / footer paragraph (`text-[11.5px]`).
    static let troveCaption     = Font.system(size: 11.5, weight: .regular, design: .default)
    /// Mono kbd / filename — `SF Mono`, 10 px.
    static let troveMono        = Font.system(size: 10, weight: .regular, design: .monospaced)
}

/// Card — the visual contract every pane inherits.
///
/// Before this revision the Card was a 10-pt rounded rectangle with
/// `.background.secondary` fill and a half-pt separator stroke — pleasant but
/// indistinguishable from a stock AppKit list row. The site renders use a
/// 14-pt radius, a translucent black panel with a 1-pt `rgba(255,255,255,0.08)`
/// stroke, generous internal padding, and a soft warm-tinted shadow.
///
/// Reduce Transparency: blur is swapped for a solid `Color.troveCardSolid`
/// fill, since `.thinMaterial` becomes opaque/grey and looks broken under that
/// accessibility setting. WCAG AA: 13 px white-on-`#0E0F14` body copy clears
/// the 4.5:1 ratio comfortably.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.troveCardStroke, lineWidth: 1)
            )
            // Warm-tinted ambient shadow — matches the `shadow-[0_20px_50px_-20px_rgba(0,0,0,0.8)]`
            // halo on PdfVisual's stacked pages. Tint = trace of the orange accent so
            // it blends with the hero gradient bleed.
            .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
            .shadow(color: Color.troveAccent.opacity(0.05), radius: 30, x: 0, y: 12)
    }

    @ViewBuilder private var cardBackground: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.troveCardSolid)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.troveCardFill)
            }
        }
    }
}

/// Pill-style hotkey indicator (`⌥1`, `⌘V`). Mirrors the `.text-[10px]
/// font-mono` capsules in every visual. Outlined, not filled, so it reads as
/// a chrome element rather than competing with content.
struct TroveKbd: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.troveMono)
            .foregroundStyle(Color.troveFgMute)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.troveCardStroke, lineWidth: 0.75)
            )
            .accessibilityHidden(true)
    }
}

/// Eyebrow label — `text-[11px] uppercase tracking-[0.18em] text-[var(--color-fg-mute)]`.
struct TroveEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.trovePaneLabel)
            .tracking(1.6)
            .foregroundStyle(Color.troveFgMute)
            .accessibilityLabel(text)
    }
}

// ===========================================================================
// MARK: - Clipboard reader (hardened, shared by Stage + History)
// ===========================================================================

/// One-shot snapshot of the pasteboard with privacy + size guards applied.
/// Both Stage's auto-grab and Clipboard History use this so the rules can't drift.
enum ClipboardReader {
    /// Pasteboard types that mark an item as ephemeral / sensitive. Password managers
    /// (1Password, Bitwarden) and screen-recording tools mark items so they're not
    /// vacuumed up. See http://nspasteboard.org for the convention.
    // red-team: full list per nspasteboard.org spec — missing any of these means
    // a copied password from 1Password / Bitwarden / Keychain / AltTab gets logged
    // to clipboard history. Includes the bare `Generic` marker some clients use
    // and the AltTab-macos concealed type. Strings are matched against the raw
    // value of `NSPasteboard.PasteboardType` since these are not standard typed
    // constants in AppKit.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword.ConcealedType",
        "com.agilebits.onepassword",
        "com.lwouis.alttab-macos.concealed",
        "Pasteboard generator type",
        "Generic",
    ]

    /// Skip clipboard items bigger than this on background ingestion to avoid
    /// runaway memory/disk when the user copies a huge screenshot.
    static let maxAutoBytes: Int64 = 100 * 1024 * 1024  // 100 MB

    enum Payload {
        case text(String)
        case image(NSImage)
        case files([URL])
    }

    /// `strict=true` → honor privacy markers + size cap (use for background watch).
    /// `strict=false` → only block on the size cap (use for explicit user-paste).
    static func snapshot(strict: Bool) -> Payload? {
        let pb = NSPasteboard.general

        if strict {
            for t in pb.types ?? [] {
                if concealedTypes.contains(t.rawValue) { return nil }
            }
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        // Pre-decode size guard: probe raw bytes before allocating NSImage (defense-in-depth below).
        if strict {
            let rawBytes = Int64(pb.data(forType: .tiff)?.count ?? pb.data(forType: .png)?.count ?? 0)
            if rawBytes > maxAutoBytes { return nil }
        }
        if let img = NSImage(pasteboard: pb) {
            let bytes = Int64(img.tiffRepresentation?.count ?? 0)
            if strict && bytes > maxAutoBytes { return nil }
            return .image(img)
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            if strict && Int64(s.utf8.count) > maxAutoBytes { return nil }
            return .text(s)
        }
        return nil
    }
}

// ===========================================================================
// MARK: - Stage (CommandX-style multi-clipboard)
// ===========================================================================

enum ItemKind: Hashable {
    case image(URL)
    case text(String)
    case file(URL)
}

struct StagedItem: Identifiable, Hashable {
    let id = UUID()
    let kind: ItemKind
    let createdAt = Date()
    var summary: String {
        switch kind {
        case .image:        return "Image"
        case .text(let s):
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return String(one.prefix(60))
        case .file(let u):  return u.lastPathComponent
        }
    }
}

/// Sonner-style toast model. Each toast is identity-stable so per-toast
/// dismiss timers don't cancel siblings. `action`/`actionLabel` are paired —
/// presence of `actionLabel` means a button is rendered.
struct TroveToast: Identifiable {
    enum Kind { case info, success, warning, error }
    let id: UUID
    let message: String
    let kind: Kind
    let actionLabel: String?
    let action: (() -> Void)?
    let createdAt: Date

    init(message: String,
         kind: Kind = .info,
         actionLabel: String? = nil,
         action: (() -> Void)? = nil) {
        self.id = UUID()
        self.message = message
        self.kind = kind
        self.actionLabel = actionLabel
        self.action = action
        self.createdAt = Date()
    }
}

final class Stage: ObservableObject {
    @Published var items: [StagedItem] = []
    @Published var floating: Bool = false
    @Published var autoGrab: Bool = false
    @Published var toasts: [TroveToast] = []

    /// Back-compat shim for legacy readers (cutpaste / finder_tweaks / qr) that
    /// peek at the current toast as a plain `String?`. Reflects the newest
    /// toast's message so existing `navigationSubtitle` bindings keep working.
    var transientStatus: String? { toasts.last?.message }

    let tempDir: URL
    // red-team: one DispatchWorkItem per toast id so dismissing/extending one
    // toast doesn't affect siblings. The previous single-shot timer cancelled
    // the prior toast's clear work when a new flash arrived — fine for replace
    // semantics, broken for stacking.
    private var dismissWork: [UUID: DispatchWorkItem] = [:]
    // Fix 11: private timer and lastChangeCount removed — PasteboardWatcher
    // owns the shared 0.5s poller and watermark now.

    /// Cap on simultaneously-visible toasts. red-team: chose 4 because Stage's
    /// own stage-grid uses bottom-trailing real estate at ~280pt wide; more
    /// than 4 stacked capsules clips the lowest one behind the window edge
    /// on a 640pt-tall minimum window. FIFO eviction (oldest first) so the
    /// freshest toast — the one the user just triggered — is never the one
    /// that vanishes.
    private static let maxVisibleToasts = 4

    /// Primary flash entry. Kept as the existing 1-arg form for compatibility
    /// with every `SharedStore.stage.flash("…")` call site across the codebase.
    func flash(_ msg: String, kind: TroveToast.Kind = .info) {
        enqueue(TroveToast(message: msg, kind: kind))
    }

    /// Flash with a trailing action button (Undo / Retry / Open…). Auto-dismiss
    /// is extended to 6.0s because reaching for an Undo button is time-sensitive
    /// and 4s is below the published Fitts-time threshold for confident recovery.
    func flash(_ msg: String,
               kind: TroveToast.Kind = .info,
               actionLabel: String,
               action: @escaping () -> Void) {
        enqueue(TroveToast(message: msg, kind: kind,
                             actionLabel: actionLabel, action: action))
    }

    func dismiss(_ id: UUID) {
        dismissWork[id]?.cancel()
        dismissWork.removeValue(forKey: id)
        toasts.removeAll { $0.id == id }
    }

    private func enqueue(_ toast: TroveToast) {
        toasts.append(toast)
        // red-team: evict oldest first when over cap. Drop work items for the
        // evicted ids so a stale fire-after doesn't try to remove a UUID that
        // no longer exists (no crash, but wastes a main-queue hop).
        while toasts.count > Self.maxVisibleToasts {
            let evicted = toasts.removeFirst()
            dismissWork[evicted.id]?.cancel()
            dismissWork.removeValue(forKey: evicted.id)
        }
        let lifetime: TimeInterval = (toast.actionLabel == nil) ? 4.0 : 6.0
        let id = toast.id
        let w = DispatchWorkItem { [weak self] in self?.dismiss(id) }
        dismissWork[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: w)
    }

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        // Fix 11: pasteboard write suppression is now handled inside
        // PasteboardWatcher.shared which listens for .troveDidWritePasteboard
        // and advances the shared watermark. Stage no longer needs its own observer.
    }

    func pasteFromClipboard() {
        // Explicit user action — accept everything but oversized binary blobs.
        guard let payload = ClipboardReader.snapshot(strict: false) else { return }
        ingest(payload)
    }

    /// Called by the auto-grab timer. Honors privacy markers + dedup vs last item.
    fileprivate func autoGrabFromClipboard() {
        guard let payload = ClipboardReader.snapshot(strict: true) else { return }
        if isDuplicateOfLast(payload) { return }
        ingest(payload)
    }

    private func ingest(_ payload: ClipboardReader.Payload) {
        switch payload {
        case .text(let s):  addText(s)
        case .image(let i): addImage(i)
        case .files(let us): for u in us { addFile(u) }
        }
    }

    private func isDuplicateOfLast(_ payload: ClipboardReader.Payload) -> Bool {
        guard let last = items.last else { return false }
        switch (last.kind, payload) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.file(let a), .files(let bs)):
            return bs.count == 1 && a.path == bs[0].path
        default:
            return false
        }
    }

    func addImage(_ img: NSImage) {
        let url = tempDir.appendingPathComponent("img-\(UUID().uuidString.prefix(8)).png")
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            items.append(StagedItem(kind: .image(url)))
        } catch { /* ignore */ }
    }

    func addText(_ s: String) { items.append(StagedItem(kind: .text(s))) }
    func addFile(_ url: URL)  { items.append(StagedItem(kind: .file(url))) }
    func remove(_ id: UUID)   { items.removeAll { $0.id == id } }
    func clear()              { items.removeAll() }

    func captureScreenshot() {
        // red-team: Esc-cancel produces no file → guarded by fileExists check below.
        // red-team: tempDir path is %-quoted as a Process argument array element,
        // so unicode/spaces in the user's tmp dir cannot break the invocation.
        // red-team: serialize with OCR + Recorder region picker — two `screencapture -i`
        // in flight produces overlapping crosshairs and ambiguous Esc routing.
        guard InteractiveCaptureGate.tryAcquire() else {
            flash("Another capture is already in progress")
            return
        }
        let url = tempDir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        NSApp.hide(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { InteractiveCaptureGate.release() }
                return
            }
            let p = Process()
            p.launchPath = "/usr/sbin/screencapture"
            p.arguments = ["-i", url.path]
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                    InteractiveCaptureGate.release()
                }
                return
            }
            p.waitUntilExitOffMain()
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    self.items.append(StagedItem(kind: .image(url)))
                }
                InteractiveCaptureGate.release()
            }
        }
    }

    func copyAllAsFiles() {
        // red-team: filter dead URLs before pasteboard write. A staged file can
        // disappear out from under us via (a) the user hand-deleting in Finder,
        // (b) Sweep moving it into ~/Downloads/_archive/, or (c) /tmp/ being
        // pruned for an old image we wrote. Writing a phantom NSURL onto the
        // pasteboard means Finder's paste errors out, and worse, partially-dead
        // multi-file pastes silently drop the missing ones. Drop them with a
        // visible status instead of poisoning the pasteboard.
        let allURLs = exportAllToURLs()
        let fm = FileManager.default
        let urls = allURLs.filter { fm.fileExists(atPath: $0.path) }
        let dropped = allURLs.count - urls.count
        guard !urls.isEmpty else {
            flash(dropped > 0
                  ? "All staged files have moved or been deleted — nothing to copy"
                  : "Nothing to copy")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        // Fix 11: troveDidWritePasteboard bumps PasteboardWatcher's shared watermark.
        // Stage no longer tracks lastChangeCount itself.
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
        let base = "Copied \(urls.count) item\(urls.count == 1 ? "" : "s") · ⌘V to paste them anywhere"
        flash(dropped > 0 ? "\(base) (\(dropped) missing skipped)" : base)
    }

    func copyAllAsText() {
        let parts: [String] = items.compactMap {
            if case .text(let s) = $0.kind { return s }
            return nil
        }
        guard !parts.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: "\n\n"), forType: .string)
        // Fix 11: see copyAllAsFiles — PasteboardWatcher suppresses History re-ingestion.
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)
        flash("Copied text from \(parts.count) item\(parts.count == 1 ? "" : "s")")
    }

    private func exportAllToURLs() -> [URL] {
        items.compactMap { item -> URL? in
            switch item.kind {
            case .image(let u), .file(let u): return u
            case .text(let s):
                let u = tempDir.appendingPathComponent("text-\(UUID().uuidString.prefix(6)).txt")
                try? s.write(to: u, atomically: true, encoding: .utf8)
                return u
            }
        }
    }

    func setAutoGrab(_ on: Bool) {
        autoGrab = on
        // Fix 11: use shared PasteboardWatcher instead of a private 0.5s Timer.
        if on {
            PasteboardWatcher.shared.subscribe(key: self) { [weak self] in
                guard let self, self.autoGrab else { return }
                self.autoGrabFromClipboard()
            }
        } else {
            PasteboardWatcher.shared.unsubscribe(key: self)
        }
    }
}

struct StageView: View {
    @EnvironmentObject var stage: Stage
    @State private var dropTargeted = false
    var body: some View {
        ZStack {
            // Background is owned globally by `TroveAppBackground` (mounted
            // once in `RootView`). Stage no longer paints its own canvas — see
            // the doc comment on `TroveAppBackground`.

            VStack(spacing: 0) {
                // Contextual workflow actions based on what's staged.
                if !stage.items.isEmpty {
                    StageSmartActionsBar(items: stage.items)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
                Group {
                    if stage.items.isEmpty { StageEmpty() } else { StageGrid() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Always-present drop overlay, opacity-modulated. macOS 26's SwiftUI
            // graph is unstable if we structurally add/remove this with an `if`,
            // so we keep it in the tree and fade it.
            DropTargetOverlay()
                .opacity(dropTargeted ? 1 : 0)
                // red-team: previous animation ignored Reduce Motion. Honor the
                // OS-level accessibility setting (folks with vestibular
                // sensitivities and VoiceOver users expect zero-duration
                // transitions).
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                           ? nil : .easeOut(duration: 0.12),
                           value: dropTargeted)
                .allowsHitTesting(false)
                // red-team: VoiceOver had no signal that the drop overlay
                // appeared. Expose it as an accessibility element with a
                // label so VO announces it when it becomes visible.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Drop to stage")
                .accessibilityHint("Release the dragged item to add it to the Stage.")
                .accessibilityHidden(!dropTargeted)
        }
        .onDrop(of: [UTType.image, UTType.fileURL, UTType.text, UTType.plainText],
                isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .navigationTitle("Stage")
        .navigationSubtitle(stage.transientStatus
                            ?? (stage.items.isEmpty
                                ? "Drop, paste, or capture to begin"
                                : "\(stage.items.count) item\(stage.items.count == 1 ? "" : "s") staged"))
        .toolbar { stageToolbar() }
    }

    @ToolbarContentBuilder
    func stageToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                stage.captureScreenshot()
            } label: {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .help("Capture a region screenshot (⌘⇧N)")

            Button {
                stage.pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Add clipboard contents (⌘⇧V)")

            Toggle(isOn: Binding(get: { stage.autoGrab },
                                 set: { stage.setAutoGrab($0) })) {
                Label("Auto-grab", systemImage: "scope")
            }
            .help("Watch clipboard and auto-add anything you copy")

            Toggle(isOn: $stage.floating) {
                Label("Pin", systemImage: stage.floating ? "pin.fill" : "pin")
            }
            .help("Keep window above other apps")

            Button(role: .destructive) {
                stage.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(stage.items.isEmpty)
            .help("Remove all staged items (⌘⇧⌫)")

            Menu {
                Button("As files (all types)") { stage.copyAllAsFiles() }
                Button("Text items joined")    { stage.copyAllAsText() }
            } label: {
                Label("Copy all (\(stage.items.count))", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .disabled(stage.items.isEmpty)
            .help("Put everything on the clipboard (⌘⇧C)")
        }
    }
    func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { obj, _ in
                    if let u = obj { DispatchQueue.main.async { stage.addFile(u) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    let maxBytes = 100 * 1024 * 1024
                    if let bytes = img.tiffRepresentation?.count, bytes > maxBytes {
                        NSLog("Trove: dropped dropped image (%.1f MB) — exceeds 100 MB limit", Double(bytes) / 1_048_576)
                        return
                    }
                    DispatchQueue.main.async { stage.addImage(img) }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? String { DispatchQueue.main.async { stage.addText(s) } }
                }
            }
        }
    }

}

struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.troveAccent.opacity(0.05))
                .padding(8)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.troveAccent.opacity(0.85),
                              style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .padding(8)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.troveAccent)
                Text("Drop to stage")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
            }
        }
    }
}

struct StageEmpty: View {
    @EnvironmentObject var stage: Stage
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.03))
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(Color.troveCardStroke, lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "tray")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.troveFgDim)
            }
            VStack(spacing: 6) {
                Text("Drop anything here")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                Text("Drag in files, hit ⌘⇧V to paste, or capture a screenshot. Stage holds it all until you’re ready to drop it elsewhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.troveFgDim)
                    .frame(maxWidth: 440)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            HStack(spacing: 8) {
                Button { stage.pasteFromClipboard() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste clipboard")
                        TroveKbd(label: "⌘⇧V")
                    }
                }
                Button { stage.captureScreenshot() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder")
                        Text("Capture screenshot")
                        TroveKbd(label: "⌘⇧N")
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Row-style Stage list — matches the trove-site `StageVisual` render
/// row-for-row: 36×36 icon tile, title + preview stack, `⌥N` kbd capsule on
/// the right, 1-pt translucent border, item-typed accent tint bleeding from
/// the leading edge. Each row carries a faint `from-tint/15 to-transparent`
/// gradient so images / text / files are differentiable at a glance, same as
/// the marketing render.
///
/// The first 9 items get a numbered hotkey capsule (`⌥1`…`⌥9`); after that
/// the capsule is hidden — the hotkeys are vended by the global hotkey
/// system already, so we don't promise something we can't deliver.
struct StageGrid: View {
    @EnvironmentObject var stage: Stage
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(stage.items.enumerated()), id: \.element.id) { idx, item in
                    StageCard(item: item, index: idx)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

struct StageCard: View {
    @EnvironmentObject var stage: Stage
    let item: StagedItem
    /// Position in the staged list — drives the `⌥N` indicator.
    let index: Int
    @State private var hover = false

    /// Red-team: a staged file URL can be moved/deleted out from under us between
    /// being added and being copied. Detect at render time so the user sees a
    /// warning and can remove the dead entry before "Copy all" produces broken refs.
    private var fileMissing: Bool {
        switch item.kind {
        case .image(let u), .file(let u):
            return !FileManager.default.fileExists(atPath: u.path)
        case .text:
            return false
        }
    }

    /// Per-kind tint used for the leading-edge gradient bleed. Mirrors the
    /// `tint` palette in `StageVisual.tsx` (orange = text, magenta = image,
    /// sky = file/link).
    private var tint: Color {
        switch item.kind {
        case .text:  return .troveAccent      // #FF7A45
        case .image: return .troveAccentAlt   // #B27CFF
        case .file:  return .troveAccentSky   // #4CB8FF
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.troveRowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(previewText)
                    .font(.troveRowBody)
                    .foregroundStyle(Color.troveFgDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if fileMissing {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Missing").font(.troveMono)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                .accessibilityLabel("File missing on disk")
            } else if hover {
                Button { stage.remove(item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.troveFgDim)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle().fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            Circle().strokeBorder(Color.troveCardStroke, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .help("Remove from Stage")
                .accessibilityLabel("Remove \(titleText)")
            }
            if index < 9 {
                TroveKbd(label: "⌥\(index + 1)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    fileMissing ? Color.red.opacity(0.55) :
                    (hover ? Color.white.opacity(0.14) : Color.troveCardStroke),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(fileMissing ? 0.7 : 1)
        .onHover { hover = $0 }
        .onDrag { dragProvider() }
        .contextMenu {
            switch item.kind {
            case .image(let u), .file(let u):
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            case .text(let s):
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
            }
            Button("Remove") { stage.remove(item.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel): \(titleText)")
        .accessibilityHint(previewText)
    }

    /// Row background — black wash + leading tint gradient bleed.
    /// Matches `bg-gradient-to-r ${tint} bg-black/30` in the render.
    @ViewBuilder private var rowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
            LinearGradient(
                colors: [tint.opacity(0.14), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 36×36 icon plaque on the left of every row — `w-9 h-9 rounded-lg
    /// bg-white/[0.04] border-white/[0.06]` in the render.
    @ViewBuilder private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.troveCardStroke, lineWidth: 0.75)
            iconContent
        }
        .frame(width: 36, height: 36)
    }

    /// Icon glyph — for `.image` items we render a tiny thumbnail crop, so the
    /// row carries genuine visual info (preserving the old grid's "I can see
    /// what I copied" affordance in a row-shape).
    @ViewBuilder private var iconContent: some View {
        switch item.kind {
        case .image(let u):
            if let img = NSImage(contentsOf: u) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
        case .file(let u):
            Image(systemName: u.hasDirectoryPath ? "folder.fill" : "doc.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var titleText: String {
        switch item.kind {
        case .image(let u): return u.lastPathComponent
        case .file(let u):  return u.lastPathComponent
        case .text(let s):
            let one = s.replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespaces)
            return String(one.prefix(80))
        }
    }

    private var previewText: String {
        switch item.kind {
        case .image(let u):
            if let img = NSImage(contentsOf: u) {
                let sz = img.size
                return "\(Int(sz.width)) × \(Int(sz.height)) · \(u.pathExtension.uppercased())"
            }
            return u.pathExtension.uppercased()
        case .file(let u):
            return u.deletingLastPathComponent().path
        case .text(let s):
            let n = s.count
            return "\(n) char\(n == 1 ? "" : "s")"
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .image: return "Image"
        case .text:  return "Text"
        case .file:  return "File"
        }
    }

    func dragProvider() -> NSItemProvider {
        switch item.kind {
        case .image(let u), .file(let u):
            return NSItemProvider(contentsOf: u) ?? NSItemProvider()
        case .text(let s):
            return NSItemProvider(object: s as NSString)
        }
    }
}

// ===========================================================================
// MARK: - Storage helpers
// ===========================================================================

extension Process {
    /// Wait for the process to exit, with a hard main-thread guard. Use this
    /// instead of `waitUntilExit()` at every call site. The one place where
    /// `waitUntilExit()` is allowed bare is inside `runShell` itself (which
    /// is already guarded at function entry); the extension is idempotent so
    /// that call is fine either way. Lint enforces this — see `lint-trove`.
    func waitUntilExitOffMain() {
        preconditionNotMainThread("Process.waitUntilExit(\(launchPath ?? executableURL?.path ?? "?"))")
        waitUntilExit()
    }
}

/// Hard guard: aborts with a clear message if the caller is on the main thread.
/// Used at the entry of every blocking helper (currently `runShell`). Uses
/// `preconditionFailure` rather than `assertionFailure` so it fires under
/// `-O` too — both `test-trove` and `build-macapp` ship optimized binaries
/// that would strip an assertion-only guard. The pre-existing failure mode
/// when this contract was violated was a cryptic AttributeGraph SIGABRT
/// during view-graph updates; replacing that with a labelled crash means the
/// regression is *immediately legible* in the crash log instead of buried in
/// SwiftUI internals.
@inline(__always) func preconditionNotMainThread(_ label: @autoclosure () -> String,
                                                 file: StaticString = #file,
                                                 line: UInt = #line) {
    if Thread.isMainThread {
        let msg = "MAIN-THREAD VIOLATION: \(label()) called on the main thread — must be off main"
        NSLog("%@", msg)
        preconditionFailure(msg, file: file, line: line)
    }
}

// red-team: drain stdout AND stderr concurrently *before* waitUntilExit, otherwise
// any child that writes >64KB to either pipe blocks forever (kernel pipe-buffer cap)
// and the app deadlocks (e.g. `du -sk ~`, `find / -size +10M`, verbose `brew cleanup`).
// red-team: wallclock timeout — `npm cache clean`, `pip cache purge`, `pnpm store prune`
// can hang on network mirrors / locked state. Kill the child after `timeout` seconds
// so the Clean view never freezes the app.
func runShell(_ launch: String, _ args: [String], timeout: TimeInterval = 60) -> (out: String, code: Int32) {
    // INVARIANT: never call this on the main thread. The function blocks on
    // `waitUntilExit` for up to `timeout` seconds — doing that on main pegs
    // the run loop and, if we're inside a SwiftUI view-graph update, trips
    // AttributeGraph's main-thread invariant and aborts with EXC_CRASH/SIGABRT
    // (this is exactly how Trove crashed on 2026-05-16 when the restored
    // selected pane happened to be `Clean` and `@StateObject CleanModel.init()`
    // chained into `whichExists` → `runShell` synchronously).
    //
    // `assertionFailure` is fatal in debug builds (so any new regression is
    // caught the first time a dev runs the app) and a no-op in release (so
    // even a missed audit can't cost a user a crash on launch). Pair with
    // `whichExists` below — it inherits this guard.
    preconditionNotMainThread("runShell(\(launch))")
    let p = Process()
    p.launchPath = launch
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return ("", -1) }

    // Concurrent drain so neither pipe can fill its 64KB buffer.
    let outBox = DrainBox()
    let outQ = DispatchQueue(label: "trove.runshell.out")
    let errQ = DispatchQueue(label: "trove.runshell.err")
    let group = DispatchGroup()
    group.enter()
    outQ.async {
        outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    errQ.async {
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()  // drain & discard
        group.leave()
    }

    // Bounded wait for process exit.
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    var didTimeout = false
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
        if p.isRunning {
            didTimeout = true
            p.terminate()
            // Give it 1s to die gracefully, then SIGKILL.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
    timer.resume()
    p.waitUntilExitOffMain()
    timer.cancel()
    group.wait()

    let s = String(data: outBox.data, encoding: .utf8) ?? ""
    let code = didTimeout ? Int32(-2) : p.terminationStatus
    return (s, code)
}

// red-team: box wrapper so the drain queue mutates a heap slot, not a captured local.
private final class DrainBox { var data = Data() }

func dirSize(_ path: String) -> Int64 {
    // BSD du supports -I to skip patterns. Used to avoid descending into Photos /
    // TV / Music libraries (TCC walls) — those trigger a permission prompt the
    // user shouldn't see for a casual size scan.
    var args = ["-sk"]
    for s in tccProtectedSuffixes {
        args.append("-I"); args.append("*\(s)")
    }
    args.append(path)
    // red-team: home-dir `du -sk` can legitimately take minutes; give it room.
    let (s, _) = runShell("/usr/bin/du", args, timeout: 300)
    let kb = Int64(s.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
    return kb * 1024
}

/// Paths that would trigger a macOS TCC permission popup if we tried to walk them.
/// Skip these unless the user explicitly opts in. Anti-spam guardrail.
private let tccProtectedPathPrefixes: [String] = {
    let h = NSHomeDirectory()
    return [
        "\(h)/Library/Mobile Documents",
        "\(h)/Library/Calendars",
        "\(h)/Library/Contacts",
        "\(h)/Library/Reminders",
        "\(h)/Library/Messages",
        "\(h)/Library/Safari",
        "\(h)/Library/Application Support/AddressBook",
        "\(h)/Library/Application Support/CallHistoryDB",
    ]
}()
private let tccProtectedSuffixes: [String] = [
    ".photoslibrary", ".tvlibrary", ".musiclibrary", ".photosbook",
]

func pathIsTCCWalled(_ path: String) -> Bool {
    for s in tccProtectedSuffixes where path.hasSuffix(s) { return true }
    for p in tccProtectedPathPrefixes where path == p || path.hasPrefix(p + "/") { return true }
    return false
}

struct DiskInfo {
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var pct: Double { total > 0 ? Double(used)/Double(total) : 0 }
    static func fetch() -> DiskInfo {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            let total = Int64(v.volumeTotalCapacity ?? 0)
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return DiskInfo(total: total, free: free)
        }
        return DiskInfo(total: 0, free: 0)
    }
}

struct SizedItem: Identifiable, Hashable {
    let path: String
    let size: Int64
    let isDirectory: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Expand any folder URLs to their regular-file children, filtered by
/// extension. Caps the result so a drop of `~/` doesn't enumerate a
/// million files. Non-directory URLs pass through unchanged.
func troveExpandFolders(_ urls: [URL],
                          allowedExtensions: Set<String>? = nil,
                          cap: Int = 1000) -> [URL] {
    let fm = FileManager.default
    var out: [URL] = []
    for u in urls {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            guard let it = fm.enumerator(at: u,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let child = it.nextObject() as? URL {
                if out.count >= cap { return out }
                let ext = child.pathExtension.lowercased()
                if let allowed = allowedExtensions, !allowed.contains(ext) { continue }
                if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    out.append(child)
                }
            }
        } else {
            out.append(u)
        }
    }
    return out
}

func topChildren(of path: String, limit: Int = 30, filesOnly: Bool = false) -> [SizedItem] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
    var out: [SizedItem] = []
    for n in names {
        if n == ".DS_Store" || n == ".localized" { continue }
        let full = (path as NSString).appendingPathComponent(n)
        // Avoid triggering TCC dialogs by walking Photos / iCloud / Calendars / etc.
        if pathIsTCCWalled(full) { continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
        if filesOnly && isDir.boolValue { continue }
        let size: Int64
        if isDir.boolValue {
            size = dirSize(full)
        } else {
            let attrs = try? fm.attributesOfItem(atPath: full)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        out.append(SizedItem(path: full, size: size, isDirectory: isDir.boolValue))
    }
    out.sort { $0.size > $1.size }
    return Array(out.prefix(limit))
}

func topFilesRecursive(under path: String, limit: Int = 30) -> [SizedItem] {
    // -prune the TCC-walled paths so `find` doesn't descend and trip a permission prompt.
    var args = [path]
    for prune in tccProtectedPathPrefixes {
        args.append(contentsOf: ["-path", prune, "-prune", "-o"])
    }
    for suffix in tccProtectedSuffixes {
        args.append(contentsOf: ["-name", "*\(suffix)", "-prune", "-o"])
    }
    args.append(contentsOf: ["-type", "f", "-size", "+10M", "-print"])
    // red-team: `find` on a deep tree can run for minutes; raise the timeout.
    let (out, _) = runShell("/usr/bin/find", args, timeout: 300)
    let paths = out.split(separator: "\n").map(String.init)
    let fm = FileManager.default
    var rows: [SizedItem] = []
    for p in paths {
        if pathIsTCCWalled(p) { continue }
        let attrs = try? fm.attributesOfItem(atPath: p)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        rows.append(SizedItem(path: p, size: size, isDirectory: false))
    }
    rows.sort { $0.size > $1.size }
    return Array(rows.prefix(limit))
}

struct UsageBar: View {
    let pct: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(
                        colors: pct > 0.85 ? [.red, .pink]
                              : pct > 0.7  ? [.orange, .yellow]
                                           : [.blue, .cyan],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * pct)
                    .animation(.easeOut(duration: 0.4), value: pct)
            }
        }
        .frame(height: 14)
    }
}

struct SizedRow: View {
    let item: SizedItem
    let maxSize: Int64
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body).lineLimit(1)
                Text(item.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint.opacity(0.85))
                        .frame(width: g.size.width * (maxSize > 0 ? CGFloat(Double(item.size)/Double(maxSize)) : 0))
                }
            }
            .frame(width: 140, height: 6)
            Text(item.size.human)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: { Image(systemName: "arrow.up.right.square") }
            .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.vertical, 5)
    }
}

// ===========================================================================
// MARK: - Storage: Overview
// ===========================================================================

struct OverviewView: View {
    @State private var disk: DiskInfo = StorageCache.shared.loadedOverview()?.0 ?? DiskInfo.fetch()
    @State private var topHome: [SizedItem] = StorageCache.shared.loadedOverview()?.1 ?? []
    @State private var cachedAt: Date? = StorageCache.shared.loadedOverview()?.2
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Stop the permission popups").headerText()
                            Text("macOS asks for Downloads, Desktop, Documents access every time you click Refresh because Trove is locally-built (no Developer ID). Grant Full Disk Access once and the prompts stop forever.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button {
                                TCCDeepLink.fullDiskAccess.open()
                            } label: {
                                Label("Open Full Disk Access settings", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                        }
                        Spacer()
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(disk.used.human)
                                // red-team: hard-coded point size ignored
                                // Dynamic Type. Scale a rounded-design system
                                // font tied to .largeTitle so it grows with
                                // user font-size settings.
                                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                .monospacedDigit()
                            Text("of \(disk.total.human) used")
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            Spacer()
                            Text("\(Int((disk.pct*100).rounded()))%")
                                // red-team: was a fixed 34pt — now scales with
                                // Dynamic Type via .title text style.
                                .font(.system(.title, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        UsageBar(pct: disk.pct)
                        HStack(spacing: 12) {
                            stat("Free", disk.free.human, .green)
                            stat("Used", disk.used.human, .blue)
                            stat("Total", disk.total.human, .gray)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Top folders in Home").headerText()
                            Spacer()
                            if loading && topHome.isEmpty { ProgressView().controlSize(.small) }
                        }
                        if topHome.isEmpty && !loading {
                            Text("No data yet — hit Refresh.").foregroundStyle(.secondary)
                        } else {
                            ForEach(topHome) { SizedRow(item: $0, maxSize: topHome.first?.size ?? 1) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(
            cachedAt.map { "\(Int((disk.pct*100).rounded()))% used · \(disk.free.human) free · cached \(StorageCacheAge.describe($0))" }
            ?? "\(Int((disk.pct*100).rounded()))% used · \(disk.free.human) free"
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        // No auto-scan. Walking ~/* trips macOS TCC for Downloads / Documents /
        // Desktop on every fresh app signature. The user clicks Refresh when
        // they want fresh data; we paint from cache on launch.
    }

    func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium))
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    @MainActor
    func refresh() async {
        // red-team: rapid double-clicks of Refresh could spawn two `du -sk` walks
        // because SwiftUI's `.disabled(loading)` doesn't take effect until the next
        // render tick. Guard explicitly so we never double-execute.
        if loading { return }
        loading = true; defer { loading = false }
        disk = DiskInfo.fetch()
        topHome = await Task.detached { topChildren(of: NSHomeDirectory(), limit: 10) }.value
        StorageCache.shared.saveOverview(disk: disk, topHome: topHome)
        cachedAt = Date()
    }
}

// ===========================================================================
// MARK: - Storage: Scan
// ===========================================================================

struct ScanView: View {
    @State private var path: String = NSHomeDirectory()
    @State private var mode: ScanMode = .dirs
    @State private var results: [SizedItem] = StorageCache.shared.loadedScan(path: NSHomeDirectory(), mode: "dirs")?.0 ?? []
    @State private var cachedAt: Date? = StorageCache.shared.loadedScan(path: NSHomeDirectory(), mode: "dirs")?.1
    @State private var loading = false

    enum ScanMode: String, CaseIterable { case dirs = "Folders", files = "Big files (≥10 MB)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                            Text(path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { pick() }
                            Menu("Quick") {
                                Button("Home")      { path = NSHomeDirectory() }
                                Button("Downloads") { path = "\(NSHomeDirectory())/Downloads" }
                                Button("Desktop")   { path = "\(NSHomeDirectory())/Desktop" }
                                Button("Documents") { path = "\(NSHomeDirectory())/Documents" }
                                Button("Library")   { path = "\(NSHomeDirectory())/Library" }
                                Button("Movies")    { path = "\(NSHomeDirectory())/Movies" }
                            }
                        }
                        Picker("", selection: $mode) {
                            ForEach(ScanMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Results").headerText()
                            Spacer()
                            if !results.isEmpty {
                                Text("Total: \(results.reduce(Int64(0)) { $0 + $1.size }.human)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if results.isEmpty && !loading {
                            Text("Pick a folder and hit Scan.").foregroundStyle(.secondary).padding(.vertical, 6)
                        } else {
                            ForEach(results) { SizedRow(item: $0, maxSize: results.first?.size ?? 1) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Scan")
        .navigationSubtitle(
            cachedAt.map { "\((path as NSString).lastPathComponent) · cached \(StorageCacheAge.describe($0))" }
            ?? (path as NSString).lastPathComponent
        )
        .onChange(of: path) { _ in reseedFromCache() }
        .onChange(of: mode) { _ in reseedFromCache() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await scan() } } label: {
                    Label(loading ? "Scanning…" : "Scan", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let u = panel.url { path = u.path }
    }

    @MainActor
    func scan() async {
        loading = true; defer { loading = false }
        results = []
        let p = path; let m = mode
        results = await Task.detached {
            m == .dirs ? topChildren(of: p, limit: 30) : topFilesRecursive(under: p, limit: 30)
        }.value
        StorageCache.shared.saveScan(path: p, mode: m == .dirs ? "dirs" : "files", results: results)
        cachedAt = Date()
    }

    private func reseedFromCache() {
        let cached = StorageCache.shared.loadedScan(path: path, mode: mode == .dirs ? "dirs" : "files")
        results = cached?.0 ?? []
        cachedAt = cached?.1
    }
}

// ===========================================================================
// MARK: - Storage: Clean
// ===========================================================================

struct CleanCategory: Identifiable {
    let id = UUID()
    let name: String
    let desc: String
    let path: String?
    let action: CleanAction
    var size: Int64 = -1
    var selected: Bool = true
    var available: Bool = true
}

enum CleanAction {
    case wipeContents(String)
    case runCommand(String, [String])
}

func whichExists(_ cmd: String) -> Bool {
    let (s, _) = runShell("/usr/bin/which", [cmd])
    return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Locate Homebrew without hardcoding (Intel Macs use /usr/local, Apple Silicon /opt/homebrew).
func brewExecutablePath() -> String? {
    for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

/// Detect if Xcode is currently running. Wiping DerivedData while Xcode has an
/// open project can confuse the build system mid-flight.
func isXcodeRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
}

@MainActor
final class CleanModel: ObservableObject {
    @Published var cats: [CleanCategory] = []
    @Published var log: String = ""
    @Published var working = false

    init() {
        let home = NSHomeDirectory()
        var list: [CleanCategory] = [
            .init(name: "Xcode DerivedData",
                  desc: "Build intermediates. Safe to wipe — Xcode regenerates them.",
                  path: "\(home)/Library/Developer/Xcode/DerivedData",
                  action: .wipeContents("\(home)/Library/Developer/Xcode/DerivedData")),
            .init(name: "iOS Simulator caches",
                  desc: "Removes simulators no longer paired with an installed runtime.",
                  path: nil,
                  action: .runCommand("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])),
            .init(name: "Homebrew cleanup",
                  desc: "Old keg-only versions + downloaded bottle cache.",
                  path: nil,
                  action: .runCommand(brewExecutablePath() ?? "/opt/homebrew/bin/brew", ["cleanup", "-s"])),
            .init(name: "npm cache",
                  desc: "Cached package tarballs. Re-downloads on demand.",
                  path: "\(home)/.npm",
                  action: .runCommand("/usr/bin/env", ["npm", "cache", "clean", "--force"])),
            .init(name: "pnpm store",
                  desc: "Unreferenced packages in the pnpm content-addressable store.",
                  path: "\(home)/Library/pnpm",
                  action: .runCommand("/usr/bin/env", ["pnpm", "store", "prune"])),
            .init(name: "yarn cache",
                  desc: "Cached package archives.",
                  path: nil,
                  action: .runCommand("/usr/bin/env", ["yarn", "cache", "clean"])),
            .init(name: "pip cache",
                  desc: "Cached wheel files.",
                  path: "\(home)/Library/Caches/pip",
                  action: .runCommand("/usr/bin/env", ["pip", "cache", "purge"])),
            .init(name: "User caches (Xcode/Homebrew/Yarn/pip)",
                  desc: "Specific regenerable cache folders in ~/Library/Caches.",
                  path: "\(home)/Library/Caches",
                  action: .wipeContents("__SPECIAL_USER_CACHES__")),
        ]
        for i in list.indices {
            switch list[i].action {
            case .wipeContents(let p):
                if p != "__SPECIAL_USER_CACHES__" {
                    list[i].available = FileManager.default.fileExists(atPath: p)
                }
            case .runCommand(let exe, _):
                // Cheap path-exists check is fine on main. The PATH-resolving
                // `/usr/bin/env` form (npm/pnpm/yarn/pip etc.) is deferred to
                // a background task below — `whichExists()` invokes NSTask
                // synchronously, and doing that during `@StateObject` init
                // blocks the main thread inside an AttributeGraph update,
                // which aborts SwiftUI with EXC_CRASH/SIGABRT. We stay
                // optimistic (`available = true`) until the async resolve
                // completes; user only sees a brief flicker on first paint.
                if !exe.hasSuffix("/env") {
                    list[i].available = FileManager.default.fileExists(atPath: exe)
                }
            }
            if !list[i].available { list[i].selected = false }
        }
        cats = list

        // Resolve PATH-resolved command availability off the main thread.
        // `whichExists` blocks until `/usr/bin/which` exits; doing it on main
        // is what crashed the app when CleanView happened to be the restored
        // selected pane on launch.
        Task.detached(priority: .utility) { [weak self] in
            let resolved: [(Int, Bool)] = list.enumerated().compactMap { (i, c) in
                guard case .runCommand(let exe, let args) = c.action,
                      exe.hasSuffix("/env"),
                      let cmd = args.first else { return nil }
                return (i, whichExists(cmd))
            }
            await MainActor.run {
                guard let self else { return }
                for (i, ok) in resolved where i < self.cats.count {
                    self.cats[i].available = ok
                    if !ok { self.cats[i].selected = false }
                }
            }
        }
    }

    func measure() async {
        working = true; defer { working = false }
        log = "Measuring sizes…\n"
        for i in cats.indices {
            guard cats[i].available else { cats[i].size = 0; continue }
            let p = cats[i].path
            let sz: Int64 = await Task.detached {
                guard let p = p, FileManager.default.fileExists(atPath: p) else { return Int64(0) }
                return dirSize(p)
            }.value
            cats[i].size = sz
        }
        let total = cats.filter { $0.selected && $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
        log += "Selected total ≈ \(total.human)\n"
    }

    func apply() async {
        working = true; defer { working = false }
        log = "Running selected cleanups…\n"
        for i in cats.indices where cats[i].selected && cats[i].available {
            let name = cats[i].name
            log += "\n▸ \(name)\n"
            let result: String = await Task.detached { [action = self.cats[i].action] in
                switch action {
                case .wipeContents(let p):
                    if p == "__SPECIAL_USER_CACHES__" {
                        let base = "\(NSHomeDirectory())/Library/Caches"
                        var msgs: [String] = []
                        for sub in ["com.apple.dt.Xcode", "Homebrew", "Yarn", "pip"] {
                            let target = "\(base)/\(sub)"
                            if FileManager.default.fileExists(atPath: target) {
                                let (_, code) = runShell("/bin/rm", ["-rf", target])
                                msgs.append("  rm \(target) → exit \(code)")
                            }
                        }
                        return msgs.joined(separator: "\n")
                    } else {
                        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: p) else {
                            return "  (nothing to do)"
                        }
                        for e in entries {
                            let full = (p as NSString).appendingPathComponent(e)
                            _ = runShell("/bin/rm", ["-rf", full])
                        }
                        return "  wiped contents of \(p)"
                    }
                case .runCommand(let exe, let args):
                    let (out, code) = runShell(exe, args)
                    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty
                        ? "  exit \(code)"
                        : trimmed.split(separator: "\n").prefix(6).map { "  \($0)" }.joined(separator: "\n") + "\n  exit \(code)"
                }
            }.value
            log += result + "\n"
            if let p = cats[i].path {
                cats[i].size = await Task.detached { dirSize(p) }.value
            }
        }
        log += "\nDone."
    }
}

struct CleanView: View {
    @StateObject private var m = CleanModel()
    @State private var showConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(spacing: 0) {
                        ForEach($m.cats) { $c in
                            HStack(alignment: .center, spacing: 12) {
                                Toggle("", isOn: $c.selected).labelsHidden().disabled(!c.available)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(c.name).font(.body.weight(.medium))
                                        if !c.available {
                                            Text("not present").font(.caption2).foregroundStyle(.secondary)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    Text(c.desc).font(.caption).foregroundStyle(.secondary)
                                    if let p = c.path {
                                        Text(p).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Text(c.size < 0 ? "—" : c.size.human)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(minWidth: 80, alignment: .trailing)
                                    .foregroundStyle(c.size > 0 ? .primary : .secondary)
                            }
                            .padding(.vertical, 10)
                            if c.id != m.cats.last?.id { Divider() }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Output").headerText()
                        ScrollView {
                            Text(m.log.isEmpty ? "(no output yet)" : m.log)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, maxHeight: 220)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Clean")
        .navigationSubtitle("Reclaim space from regenerable dev caches")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await m.measure() }
                } label: {
                    Label("Recalculate", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .disabled(m.working)

                Button {
                    showConfirm = true
                } label: {
                    Label("Apply selected", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.working || !m.cats.contains(where: { $0.selected }))
            }
        }
        .task { await m.measure() }
        .confirmationDialog("Apply selected cleanups?",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("Apply", role: .destructive) { Task { await m.apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let wipingDerived = m.cats.contains { $0.selected && $0.name == "Xcode DerivedData" }
            if wipingDerived && isXcodeRunning() {
                Text("⚠️ Xcode is currently running. Wiping DerivedData mid-build can confuse Xcode — quit it first, or expect to re-build from scratch.\n\nCaches and build outputs regenerate automatically; this is safe but not instantly reversible.")
            } else {
                Text("Caches and build outputs regenerate automatically; this is safe but not instantly reversible.")
            }
        }
    }
}

// ===========================================================================
// MARK: - Storage: Sweep
// ===========================================================================

struct SweepPlan: Identifiable, Hashable {
    let id = UUID()
    let action: String       // "archive" | "trash"
    let src: String
    let dest: String?
    let ageDays: Int
    let size: Int64
}

func bucketFor(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg","jpeg","png","gif","heic","webp","tif","tiff","bmp","svg","raw": return "images"
    case "mp4","mov","m4v","avi","mkv","webm","flv","wmv": return "video"
    case "mp3","m4a","wav","flac","aac","ogg","opus":      return "audio"
    case "zip","tar","gz","tgz","bz2","xz","7z","rar":     return "archives"
    case "pdf","doc","docx","xls","xlsx","ppt","pptx","txt","rtf","md","csv","epub","key": return "docs"
    case "js","ts","tsx","jsx","py","rb","go","rs","c","h","cpp","hpp","sh","json","yml","yaml","toml","html","css": return "code"
    case "dmg","pkg","app","iso":                          return "installers"
    default: return "other"
    }
}

func planSweep(root: String, archiveDays: Int, trashDays: Int) -> [SweepPlan] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
    var out: [SweepPlan] = []
    let now = Date()
    let archiveRoot = (root as NSString).appendingPathComponent("_archive")

    for n in names {
        if n == "_archive" || n == ".DS_Store" || n == ".localized" { continue }
        // red-team: PDF ops and other tools write into ~/Downloads/Trove/<op>/.
        // A directory's mtime updates only when its immediate children are added
        // or removed — it does NOT bubble up from deep edits. After 30 days
        // without a brand-new op subfolder, the top-level `Trove/` would be
        // older than `archiveDays` and Sweep would move the entire tree into
        // `_archive/.../folders/Trove/`, silently breaking every Stage entry
        // and PDFOpsRecents URL that still points at the unarchived path. Skip
        // our own output dir unconditionally.
        if n == "Trove" { continue }
        let full = (root as NSString).appendingPathComponent(n)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
        let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
        let mod = (attrs[.modificationDate] as? Date) ?? now
        let ageDays = Int(now.timeIntervalSince(mod) / 86400)
        let size: Int64
        if isDir.boolValue { size = dirSize(full) }
        else { size = (attrs[.size] as? NSNumber)?.int64Value ?? 0 }

        if ageDays >= trashDays {
            out.append(SweepPlan(action: "trash", src: full, dest: nil, ageDays: ageDays, size: size))
        } else if ageDays >= archiveDays {
            let url = URL(fileURLWithPath: full)
            let bucket = isDir.boolValue ? "folders" : bucketFor(url)
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"
            let ym = fmt.string(from: mod)
            let dest = "\(archiveRoot)/\(ym)/\(bucket)"
            out.append(SweepPlan(action: "archive", src: full, dest: dest, ageDays: ageDays, size: size))
        }
    }
    out.sort { $0.ageDays > $1.ageDays }
    return out
}

/// Pick a destination path that doesn't collide. If `dest/name` exists,
/// returns `dest/name (2)`, `(3)`, etc. Prevents the silent `mv -n` data-skip bug.
func uniqueArchivePath(dir: String, fileName: String) -> String {
    let fm = FileManager.default
    let primary = "\(dir)/\(fileName)"
    if !fm.fileExists(atPath: primary) { return primary }
    let ns = fileName as NSString
    let stem = ns.deletingPathExtension
    let ext = ns.pathExtension
    for i in 2...9999 {
        let cand = ext.isEmpty
            ? "\(dir)/\(stem) (\(i))"
            : "\(dir)/\(stem) (\(i)).\(ext)"
        if !fm.fileExists(atPath: cand) { return cand }
    }
    return "\(dir)/\(UUID().uuidString)-\(fileName)"  // last-resort
}

func executeSweep(_ plans: [SweepPlan]) -> String {
    var log: [String] = []
    var trashUrls: [URL] = []
    for plan in plans {
        if plan.action == "trash" {
            trashUrls.append(URL(fileURLWithPath: plan.src))
        } else if let dest = plan.dest {
            do {
                try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                let fileName = (plan.src as NSString).lastPathComponent
                let target = uniqueArchivePath(dir: dest, fileName: fileName)
                try FileManager.default.moveItem(atPath: plan.src, toPath: target)
                let collisionNote = (target == "\(dest)/\(fileName)") ? "" : "  (renamed to avoid collision)"
                log.append("archived  \(fileName)  →  _archive/\(URL(fileURLWithPath: dest).lastPathComponent)/\(collisionNote)")
            } catch {
                log.append("error moving \(plan.src): \(error.localizedDescription)")
            }
        }
    }
    for u in trashUrls {
        do {
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: u, resultingItemURL: &resultURL)
            log.append("trashed   \(u.lastPathComponent)")
        } catch {
            log.append("error trashing \(u.path): \(error.localizedDescription)")
        }
    }
    return log.joined(separator: "\n")
}

struct SweepView: View {
    @State private var target: String = "\(NSHomeDirectory())/Downloads"
    @State private var archiveDays: Int = 30
    @State private var trashDays: Int = 180
    @State private var plans: [SweepPlan] = []
    @State private var log: String = ""
    @State private var working = false
    @State private var showConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "tray").foregroundStyle(.secondary)
                            Text(target).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Menu("Folder") {
                                Button("Downloads") { target = "\(NSHomeDirectory())/Downloads" }
                                Button("Desktop")   { target = "\(NSHomeDirectory())/Desktop" }
                                Button("Custom…")   { pick() }
                            }
                        }
                        HStack(spacing: 18) {
                            Stepper(value: $archiveDays, in: 7...365) {
                                HStack { Text("Archive after"); Text("\(archiveDays) days").foregroundStyle(.tint).font(.body.monospacedDigit()) }
                            }
                            Stepper(value: $trashDays, in: max(archiveDays+7, 30)...730) {
                                HStack { Text("Trash after"); Text("\(trashDays) days").foregroundStyle(.tint).font(.body.monospacedDigit()) }
                            }
                            Spacer()
                        }
                    }
                }

                // Quick-win card: reclaim space from installer leftovers
                // (.dmg/.pkg/.mpkg/.iso/.xip) that everyone forgets to delete
                // after running them. Trash, not rm — recoverable for 30 days.
                InstallerSweepCard(target: target)

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Plan").headerText()
                            Spacer()
                            if !plans.isEmpty {
                                let totA = plans.filter { $0.action == "archive" }.reduce(Int64(0)) { $0 + $1.size }
                                let totT = plans.filter { $0.action == "trash" }.reduce(Int64(0)) { $0 + $1.size }
                                Text("\(plans.filter{$0.action=="archive"}.count) archive (\(totA.human)), \(plans.filter{$0.action=="trash"}.count) trash (\(totT.human))")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if plans.isEmpty && !working {
                            Text("Hit Preview to see what would be moved or trashed. Nothing changes until you press Apply.")
                                .foregroundStyle(.secondary).padding(.vertical, 4)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(plans) { p in
                                        HStack(spacing: 10) {
                                            Image(systemName: p.action == "trash" ? "trash" : "archivebox")
                                                .foregroundStyle(p.action == "trash" ? Color.red : Color.orange)
                                                .frame(width: 18)
                                            Text((p.src as NSString).lastPathComponent).lineLimit(1)
                                            Spacer()
                                            Text("\(p.ageDays)d").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            Text(p.size.human).font(.system(.callout, design: .monospaced)).frame(width: 80, alignment: .trailing)
                                        }
                                        .padding(.vertical, 5)
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxHeight: 320)
                        }
                    }
                }

                if !log.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Result").headerText()
                            ScrollView {
                                Text(log).font(.system(.callout, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 80, maxHeight: 200)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Sweep")
        .navigationSubtitle((target as NSString).lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await preview() } } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(working)

                Button { showConfirm = true } label: {
                    Label("Apply", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || plans.isEmpty)
            }
        }
        .confirmationDialog("Apply sweep?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Apply", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items move into _archive/ or go to macOS Trash (recoverable).")
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: target)
        if panel.runModal() == .OK, let u = panel.url { target = u.path }
    }

    @MainActor
    func preview() async {
        working = true; defer { working = false }
        let t = target; let a = archiveDays; let tr = trashDays
        plans = await Task.detached { planSweep(root: t, archiveDays: a, trashDays: tr) }.value
        log = ""
    }

    @MainActor
    func apply() async {
        working = true; defer { working = false }
        let p = plans
        let result = await Task.detached { executeSweep(p) }.value
        log = result
        await preview()
    }
}

// ===========================================================================
// MARK: - Installer leftovers (Sweep sub-card)
// ===========================================================================

/// Reclaim disk space from installer files (.dmg / .pkg / .mpkg / .iso / .xip)
/// that pile up in ~/Downloads after you mount/run them. Trash (not rm) so the
/// user can recover for 30 days via Finder.
///
/// red-team: defaults to "trash all regardless of age" because the user
/// explicitly said "doesn't matter how old or new" — the optional age filter
/// is opt-in. Excludes .zip / .tar.gz on purpose: those are often
/// app downloads (Sketch, Things) or source archives, NOT just installers.
/// .dmg/.pkg/.mpkg/.iso/.xip are unambiguously installer formats.
struct InstallerSweepCard: View {
    let target: String
    @State private var found: [InstallerFile] = []
    @State private var scanning: Bool = false
    @State private var showConfirm: Bool = false
    @State private var useAgeFilter: Bool = false
    @State private var minAgeDays: Int = 30

    private static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    struct InstallerFile: Identifiable {
        let id = UUID()
        let url: URL
        let size: Int64
        let ageDays: Int
    }

    private var filtered: [InstallerFile] {
        useAgeFilter ? found.filter { $0.ageDays >= minAgeDays } : found
    }
    private var totalSize: Int64 { filtered.reduce(0) { $0 + $1.size } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
                    Text("Installer leftovers").headerText()
                    Spacer()
                    if scanning {
                        ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                    } else if filtered.isEmpty {
                        Text("None").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(filtered.count) · \(totalSize.human)")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                if !scanning && found.isEmpty {
                    Text("No .dmg / .pkg / .mpkg / .iso / .xip files in \((target as NSString).lastPathComponent). You're clean.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !scanning {
                    Text("Installer files left over after you mounted or ran them. Always safe to trash — macOS already copied the app out. Recoverable from Trash for 30 days.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Toggle(isOn: $useAgeFilter) {
                            Text("Older than").font(.callout)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        if useAgeFilter {
                            Stepper(value: $minAgeDays, in: 1...365) {
                                Text("\(minAgeDays) days")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.tint)
                            }
                            .controlSize(.small)
                        } else {
                            Text("(off → trash all)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showConfirm = true
                        } label: {
                            Label("Move \(filtered.count) to Trash · \(totalSize.human)",
                                  systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(filtered.isEmpty)
                    }
                }
            }
        }
        .task { await scan() }
        .onChange(of: target) { _ in Task { await scan() } }
        .confirmationDialog(
            "Move \(filtered.count) installer files (\(totalSize.human)) to Trash?",
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await trashAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recoverable from the Trash. Frees \(totalSize.human).")
        }
    }

    private func scan() async {
        scanning = true; defer { scanning = false }
        let dir = URL(fileURLWithPath: target)
        let exts = Self.installerExts
        let result: [InstallerFile] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // red-team-sec: scan one level deep only. Walking nested subdirs
            // inside ~/Downloads is a footgun — a user with a clone of a
            // build artifact repo in there could surface .iso files in /vendor/
            // that shouldn't be touched. Stay at top level.
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            let now = Date()
            var out: [InstallerFile] = []
            for u in entries {
                if !exts.contains(u.pathExtension.lowercased()) { continue }
                let vals = try? u.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .contentModificationDateKey
                ])
                guard vals?.isRegularFile == true else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                let mtime = vals?.contentModificationDate ?? now
                let days = Int(now.timeIntervalSince(mtime) / 86400)
                out.append(InstallerFile(url: u, size: size, ageDays: max(0, days)))
            }
            // Largest first — most-impactful trashable up top.
            out.sort { $0.size > $1.size }
            return out
        }.value
        self.found = result
    }

    private func trashAll() async {
        // Snapshot the originals *before* trashing — once trashed, the
        // InstallerFile array is replaced by the post-scan re-walk, and we'd
        // have nothing to restore from. red-team: capture the immutable URL
        // list here so the Undo closure can iterate it after the parent view
        // state has moved on.
        let items = filtered
        let originalURLs: [URL] = items.map(\.url)
        let totalToFree = items.reduce(Int64(0)) { $0 + $1.size }
        let trashedURLs: [URL] = await Task.detached(priority: .userInitiated) {
            var ok: [URL] = []
            for item in items {
                if (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil {
                    ok.append(item.url)
                }
            }
            return ok
        }.value
        let trashed = trashedURLs.count
        if trashed > 0 {
            SharedStore.stage.flash(
                "Trashed \(trashed) installer files · reclaimed \(totalToFree.human)",
                kind: .success,
                actionLabel: "Undo"
            ) {
                // red-team: trash-restore path. `trashItem` moves to
                // ~/.Trash/<filename> (or the user's per-volume .Trashes
                // mirror on external disks). For Downloads/Desktop/Documents
                // — the only roots InstallerSweepCard scans — those all
                // resolve to ~/.Trash, so deriving the trashed URL from
                // lastPathComponent is correct. If macOS renamed on collision
                // ("foo.dmg" → "foo 2.dmg"), our derived path misses; the
                // moveItem then throws, we silently skip, and the file
                // stays in Trash — recoverable manually, never destroyed.
                let homeTrash = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".Trash")
                Task.detached(priority: .userInitiated) {
                    var restored = 0
                    for original in originalURLs {
                        let untrashURL = homeTrash
                            .appendingPathComponent(original.lastPathComponent)
                        if (try? FileManager.default.moveItem(at: untrashURL,
                                                              to: original)) != nil {
                            restored += 1
                        }
                    }
                    await MainActor.run {
                        SharedStore.stage.flash(
                            "Restored \(restored) of \(originalURLs.count) installer file\(originalURLs.count == 1 ? "" : "s")",
                            kind: restored == originalURLs.count ? .success : .warning
                        )
                        Task { await scan() }
                    }
                }
            }
        } else {
            SharedStore.stage.flash("Nothing trashed — check Trash permissions", kind: .warning)
        }
        await scan()
    }
}
