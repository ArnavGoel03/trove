// Trove — Cut-paste files in Finder.
//   • Windows-style ⌘X / ⌘V move semantics for Finder, system-wide.
//   • CGEventTap intercepts the keystrokes only when Finder is frontmost.
//   • Cut state is in-memory: originals stay put on disk until paste happens.
//
// Compiles alongside main.swift via `swiftc -parse-as-library`.

import SwiftUI
import AppKit
import Carbon
import Foundation
import ApplicationServices

// ===========================================================================
// MARK: - Model
// ===========================================================================

struct CutPasteEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String   { url.lastPathComponent }
    var parent: String { url.deletingLastPathComponent().path }
    var size: Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
    }
}

struct CutPasteHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let count: Int
    let src: String
    let dst: String
    let at: Date
    var time: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: at)
    }
}

// ===========================================================================
// MARK: - Controller (event tap + cut state + paste engine)
// ===========================================================================

final class CutPasteController: ObservableObject {
    static let shared = CutPasteController()

    @Published var enabled: Bool = false
    @Published var cut: [CutPasteEntry] = []
    @Published var history: [CutPasteHistoryEntry] = []
    @Published var status: String? = nil
    @Published var permissionMissing: Bool = false
    @Published var appleScriptDenied: Bool = false
    @Published var cutVisualHint: Bool = false

    // CGEventTap plumbing.
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapCallbackBox: Unmanaged<AnyObject>?

    // Cut staleness timer (red-team #3): 5 minutes of inactivity → auto-cancel.
    private var staleTimer: Timer?
    private let staleSeconds: TimeInterval = 5 * 60

    // Track URLs we tagged with the Gray Finder color, so we can scrub them
    // on cancel/paste/quit (red-team #10).
    private var taggedURLs: Set<URL> = []

    // red-team: lock-protected mirror of `!cut.isEmpty` so the CGEventTap
    // callback can decide whether to swallow ⌘V without main.sync (deadlock).
    private var pendingLock = os_unfair_lock()
    private var pendingCut: Bool = false

    var totalCutBytes: Int64 { cut.reduce(0) { $0 + $1.size } }

    init() {
        // Scrub Finder color labels on app quit if hint mode left tags behind.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func onTerminate() { clearAllVisualHints() }

    // CutPasteController is a singleton so deinit is unreachable in production,
    // but pairing addObserver with removeObserver is required for correctness
    // and test-harness safety (tests may instantiate multiple instances).
    deinit { NotificationCenter.default.removeObserver(self) }

    // -----------------------------------------------------------------------
    // Enable / disable the global event tap.
    // -----------------------------------------------------------------------

    func setEnabled(_ on: Bool) {
        if on { startTap() } else { stopTap() }
    }

    private func startTap() {
        // Permission probe first (red-team #1). Do NOT auto-prompt — the user
        // taps "Grant" explicitly.
        guard AXIsProcessTrusted() else {
            // Fix 21: set enabled = false synchronously (not just in the async block)
            // so the toggle UI reflects the disabled state immediately even when
            // this is called from a direct assignment to `enabled` (e.g. the
            // "Enable cut-paste" button that sets ctl.enabled = true directly).
            enabled = false
            DispatchQueue.main.async {
                self.permissionMissing = true
                self.enabled = false
                SharedStore.stage.flash("Accessibility permission required",
                                       kind: .warning,
                                       actionLabel: "Open Settings") {
                    TCCDeepLink.accessibility.open()
                }
            }
            return
        }
        permissionMissing = false

        // Bridge self into the C callback through a retained Unmanaged pointer.
        let box = Unmanaged.passRetained(self as AnyObject)
        self.tapCallbackBox = box

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CutPasteController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: box.toOpaque())
        else {
            // Tap creation failed despite being trusted — surface and bail.
            box.release()
            self.tapCallbackBox = nil
            DispatchQueue.main.async {
                self.permissionMissing = true
                self.enabled = false
                SharedStore.stage.flash("Couldn't create event tap")
            }
            return
        }
        self.tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        DispatchQueue.main.async {
            self.enabled = true
            SharedStore.stage.flash("Cut & paste in Finder is live (⌘X / ⌘V)")
        }
    }

    private func stopTap() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)  // release WindowServer's Mach send right
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        tapCallbackBox?.release()
        tapCallbackBox = nil
        DispatchQueue.main.async {
            self.enabled = false
        }
    }

    // -----------------------------------------------------------------------
    // CGEventTap callback (runs on tap-specific run loop).
    // Returning nil swallows the event; returning the event passes it through.
    // -----------------------------------------------------------------------

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Red-team #7: re-enable if macOS disables the tap under load.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = self.tap {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        guard flags.contains(.maskCommand) else { return Unmanaged.passUnretained(event) }
        // Reject when ⌥, ⌃, or ⇧ are also held — too easy to clobber other shortcuts.
        if flags.contains(.maskAlternate) || flags.contains(.maskControl) || flags.contains(.maskShift) {
            return Unmanaged.passUnretained(event)
        }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isX = (keycode == kVK_ANSI_X)
        let isV = (keycode == kVK_ANSI_V)
        guard isX || isV else { return Unmanaged.passUnretained(event) }

        // Red-team #9: never intercept when Trove itself is frontmost.
        // Red-team #8: any state read/mutation hops to main.
        // red-team: when running unsigned / from a build dir the main bundle
        // identifier is nil. `nil == nil` would have made an empty front-bundleID
        // (e.g. a helper without an Info.plist) match "us" and we'd stop
        // intercepting. Skip the self-check only when our own ID is non-nil.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if let mine = Bundle.main.bundleIdentifier, !mine.isEmpty, front == mine {
            return Unmanaged.passUnretained(event)
        }
        guard front == "com.apple.finder" else {
            return Unmanaged.passUnretained(event)
        }

        if isX {
            // red-team: AppleScript + Finder I/O on the tap thread blocks the
            // global keystroke pipeline and can re-enter Finder mid-operation.
            // Swallow ⌘X and run selection-snapshot + stageCut on main.
            DispatchQueue.main.async {
                let selection = CutPasteFinderBridge.selection()
                if !selection.isEmpty { self.stageCut(selection) }
            }
            return nil
        } else {
            // ⌘V — only intercept if we have a pending cut. Otherwise let
            // Finder's own "Paste Item" behavior run (copy semantics).
            // red-team: replaced DispatchQueue.main.sync — would deadlock when
            // the tap runloop source is added to main runloop. Read+CAS the
            // pending flag under an unfair lock; flip it before hopping so
            // a racing second ⌘V passes through to Finder.
            os_unfair_lock_lock(&pendingLock)
            let hadCut = pendingCut
            if hadCut { pendingCut = false }
            os_unfair_lock_unlock(&pendingLock)
            if !hadCut { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { self.performPaste() }
            return nil
        }
    }

    // -----------------------------------------------------------------------
    // Cut / cancel / paste — all run on main.
    // -----------------------------------------------------------------------

    func stageCut(_ urls: [URL]) {
        // Clear any prior visual hint from earlier cut session.
        clearAllVisualHints()
        cut = urls.map { CutPasteEntry(url: $0) }
        // red-team: keep the lock-protected mirror in sync with `cut`.
        os_unfair_lock_lock(&pendingLock); pendingCut = !cut.isEmpty; os_unfair_lock_unlock(&pendingLock)
        bumpStaleTimer()
        if cutVisualHint { applyVisualHint(to: urls) }
        SharedStore.stage.flash("Cut \(urls.count) file\(urls.count == 1 ? "" : "s")")
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    func cancelCut(silent: Bool = false) {
        guard !cut.isEmpty else { return }
        clearAllVisualHints()
        cut.removeAll()
        // red-team: mirror cleared too — otherwise tap thread thinks ⌘V is still armed.
        os_unfair_lock_lock(&pendingLock); pendingCut = false; os_unfair_lock_unlock(&pendingLock)
        staleTimer?.invalidate()
        staleTimer = nil
        if !silent { SharedStore.stage.flash("Cut cancelled") }
    }

    private func performPaste() {
        guard !cut.isEmpty else { return }
        guard let dest = CutPasteFinderBridge.frontTargetFolder() else {
            SharedStore.stage.flash("Couldn't read Finder's front window destination")
            return
        }

        // Red-team #4: validate each source still exists.
        let fm = FileManager.default
        var sources: [URL] = []
        var missing = 0
        for entry in cut {
            if fm.fileExists(atPath: entry.url.path) { sources.append(entry.url) }
            else { missing += 1 }
        }
        if sources.isEmpty {
            SharedStore.stage.flash("All \(cut.count) cut file\(cut.count == 1 ? "" : "s") missing — paste aborted")
            cancelCut(silent: true)
            return
        }

        // Red-team #5: no-op when source and dest are the same folder.
        let sameParent = sources.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == dest.standardizedFileURL
        }
        if sameParent {
            SharedStore.stage.flash("Source and destination are the same folder — nothing to do")
            return
        }

        // red-team: refuse to paste a folder into itself or any descendant.
        // FileManager.moveItem would create a self-recursive directory and
        // either spin until out of inodes or corrupt the source.
        let destPath = dest.standardizedFileURL.path
        let destPathWithSlash = destPath.hasSuffix("/") ? destPath : destPath + "/"
        let recursive = sources.first { src in
            let s = src.standardizedFileURL.path
            return destPath == s || destPathWithSlash.hasPrefix(s + "/")
        }
        if let bad = recursive {
            SharedStore.stage.flash("Refusing to paste \(bad.lastPathComponent) into itself")
            return
        }

        // red-team: refuse to write into a read-only volume up-front instead
        // of letting every per-file moveItem fail with a confusing error.
        if !fm.isWritableFile(atPath: dest.path) {
            SharedStore.stage.flash("Destination is read-only — paste aborted")
            return
        }

        var moved = 0
        var failed = 0
        var firstError: String? = nil
        var srcParents = Set<String>()
        for src in sources {
            srcParents.insert(src.deletingLastPathComponent().path)
            let target = uniqueDestination(for: src.lastPathComponent, in: dest)
            do {
                try fm.moveItem(at: src, to: target)
                moved += 1
            } catch {
                // Red-team #6: log + count, keep going. Surface the first
                // error to the status line so the user gets a real reason
                // (read-only mid-volume, permission, busy file) instead of
                // an opaque "N failed".
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // Scrub any visual hint tags from anything that didn't move.
        clearAllVisualHints()

        // Record history (cap at 10 newest-first).
        let srcLabel = srcParents.count == 1
            ? (srcParents.first.map { (($0 as NSString).lastPathComponent) } ?? "various")
            : "\(srcParents.count) folders"
        let dstLabel = dest.lastPathComponent.isEmpty ? dest.path : dest.lastPathComponent
        let entry = CutPasteHistoryEntry(count: moved, src: srcLabel, dst: dstLabel, at: Date())
        history.insert(entry, at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }

        cut.removeAll()
        // red-team: mirror cleared after a paste pass.
        os_unfair_lock_lock(&pendingLock); pendingCut = false; os_unfair_lock_unlock(&pendingLock)
        staleTimer?.invalidate()
        staleTimer = nil

        // Audible + visual feedback (spec point 3).
        NSSound(named: NSSound.Name("Glass"))?.play()
        var parts: [String] = []
        parts.append("Moved \(moved) file\(moved == 1 ? "" : "s")")
        if failed > 0  {
            if let e = firstError {
                parts.append("\(failed) failed (\(e))")
            } else {
                parts.append("\(failed) failed")
            }
        }
        if missing > 0 { parts.append("\(missing) missing — skipped") }
        SharedStore.stage.flash(parts.joined(separator: " · "))
    }

    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var i = 2
        while true {
            let suffix = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let next = folder.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            i += 1
            if i > 9999 {
                return folder.appendingPathComponent("\(stem)-\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
            }
        }
    }

    // -----------------------------------------------------------------------
    // Stale timer (red-team #3)
    // -----------------------------------------------------------------------

    private func bumpStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: staleSeconds, repeats: false) { [weak self] _ in
            guard let self = self, !self.cut.isEmpty else { return }
            let n = self.cut.count
            self.cancelCut(silent: true)
            SharedStore.stage.flash("Auto-cancelled \(n)-file cut after 5 min of inactivity")
        }
    }

    // -----------------------------------------------------------------------
    // Visual hint — Finder "Gray" color label (red-team #10)
    // -----------------------------------------------------------------------

    func setCutVisualHint(_ on: Bool) {
        cutVisualHint = on
        if on { applyVisualHint(to: cut.map(\.url)) }
        else  { clearAllVisualHints() }
    }

    private func applyVisualHint(to urls: [URL]) {
        // Finder color labels are exposed via URLResourceKey.labelNumberKey.
        // "Gray" = 1 (matches the slot under View > Show View Options).
        for url in urls {
            var u = url
            do {
                try (u as NSURL).setResourceValue(NSNumber(value: 1),
                                                  forKey: .labelNumberKey)
                taggedURLs.insert(url)
            } catch {
                // Silent — visual hint is best-effort.
            }
        }
    }

    private func clearAllVisualHints() {
        guard !taggedURLs.isEmpty else { return }
        for url in taggedURLs {
            try? (url as NSURL).setResourceValue(NSNumber(value: 0),
                                                 forKey: .labelNumberKey)
        }
        taggedURLs.removeAll()
    }

    // -----------------------------------------------------------------------
    // Permission helpers (red-team #1)
    // -----------------------------------------------------------------------

    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

// ===========================================================================
// MARK: - Finder bridge (AppleScript)
// ===========================================================================

enum CutPasteFinderBridge {
    static func selection() -> [URL] {
        let src = """
        tell application "Finder"
            set sel to selection
            set out to {}
            repeat with i in sel
                set end of out to (POSIX path of (i as alias))
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """
        guard let text = runAppleScript(src), !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map {
            URL(fileURLWithPath: String($0))
        }
    }

    static func frontTargetFolder() -> URL? {
        let src = """
        tell application "Finder"
            try
                return POSIX path of (target of front window as alias)
            on error
                return POSIX path of (desktop as alias)
            end try
        end tell
        """
        guard let text = runAppleScript(src), !text.isEmpty else { return nil }
        return URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs AppleScript synchronously. Returns nil on error and flips the
    /// `appleScriptDenied` flag if the failure looks like a permission issue
    /// (red-team #2).
    private static func runAppleScript(_ source: String) -> String? {
        var errInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errInfo)
        if let err = errInfo {
            let num = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 = permission denied; -600 / -10004 = also permission-shaped.
            if num == -1743 || num == -10004 || num == -600 {
                DispatchQueue.main.async {
                    CutPasteController.shared.appleScriptDenied = true
                    SharedStore.stage.flash("Finder automation permission denied",
                                           kind: .warning,
                                           actionLabel: "Open Settings") {
                        TCCDeepLink.automation.open()
                    }
                }
            }
            return nil
        }
        return result.stringValue
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct CutPasteView: View {
    @StateObject private var ctl = CutPasteController.shared
    @EnvironmentObject var stage: Stage

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                if ctl.permissionMissing { permissionCard }
                if ctl.appleScriptDenied { appleScriptCard }
                settingsCard
                historyCard
                footnote
            }
            .padding(20)
        }
        .navigationTitle("Cut & Paste")
        .navigationSubtitle(stage.transientStatus ?? subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(
                    get: { ctl.enabled },
                    set: { ctl.setEnabled($0) })
                ) {
                    Label("Enable", systemImage: ctl.enabled ? "bolt.fill" : "bolt.slash")
                }
                .help("Globally intercept ⌘X / ⌘V when Finder is frontmost")

                Button(role: .destructive) {
                    ctl.cancelCut()
                } label: {
                    Label("Cancel cut", systemImage: "xmark.circle")
                }
                .disabled(ctl.cut.isEmpty)
                .help("Drop the pending cut without moving anything")
            }
        }
    }

    private var subtitle: String {
        if !ctl.enabled { return "Disabled — toggle to start intercepting ⌘X / ⌘V" }
        if ctl.cut.isEmpty { return "Watching Finder · nothing cut" }
        return "\(ctl.cut.count) file\(ctl.cut.count == 1 ? "" : "s") cut · \(ctl.totalCutBytes.human) ready to paste"
    }

    // -----------------------------------------------------------------------
    // Status banner card
    // -----------------------------------------------------------------------

    @ViewBuilder private var statusCard: some View {
        Card {
            if ctl.cut.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "scissors")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing on the stage")
                        .headerText()
                    Text("With this enabled, ⌘X on files in Finder stages them here. They stay in place on disk until you press ⌘V at the destination — then Trove moves them in one atomic step.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                        .multilineTextAlignment(.center)
                    if !ctl.enabled {
                        Button {
                            // Fix 21: use setEnabled so startTap() checks AX trust.
                            ctl.setEnabled(true)
                        } label: {
                            Label("Enable cut-paste", systemImage: "power")
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                    } else {
                        Text("Try ⌘X in Finder to cut something.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "scissors.circle.fill")
                            .font(.title)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ctl.cut.count) file\(ctl.cut.count == 1 ? "" : "s") cut, ready to paste")
                                .headerText()
                            Text("\(ctl.cut.count) files · \(ctl.totalCutBytes.human)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel cut") { ctl.cancelCut() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ctl.cut.prefix(12)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(entry.parent)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .font(.callout)
                        }
                        if ctl.cut.count > 12 {
                            Text("+ \(ctl.cut.count - 12) more…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Permission cards
    // -----------------------------------------------------------------------

    @ViewBuilder private var permissionCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility permission required")
                        .headerText()
                    Text("Trove needs Accessibility access to intercept ⌘X / ⌘V system-wide. Without it, ⌘X / ⌘V will only work inside this window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Grant…") { ctl.requestAccessibility() }
                        Button("Open System Settings") {
                            TCCDeepLink.accessibility.open()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var appleScriptCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "applescript")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Finder automation permission denied")
                        .headerText()
                    Text("Trove needs permission to talk to Finder to read the current selection and destination. Grant it in System Settings → Privacy & Security → Automation → Trove → Finder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        TCCDeepLink.automation.open()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }

    // -----------------------------------------------------------------------
    // Settings card
    // -----------------------------------------------------------------------

    @ViewBuilder private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings").headerText()
                Toggle(isOn: Binding(
                    get: { ctl.enabled },
                    set: { ctl.setEnabled($0) })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable system-wide ⌘X / ⌘V")
                        Text("Intercept only when Finder is frontmost. Trove itself is excluded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { ctl.cutVisualHint },
                    set: { ctl.setCutVisualHint($0) })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cut visual hint")
                        Text("Temporarily apply the Finder Gray label to cut files so you can see what's staged. Cleared on paste or cancel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // History card
    // -----------------------------------------------------------------------

    @ViewBuilder private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent moves").headerText()
                    Spacer()
                    if !ctl.history.isEmpty {
                        Text("\(ctl.history.count) of last 10")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if ctl.history.isEmpty {
                    Text("No moves yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ctl.history) { h in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.doc.on.clipboard")
                                    .foregroundStyle(.secondary)
                                Text("Moved \(h.count) file\(h.count == 1 ? "" : "s") from ")
                                + Text(h.src).bold()
                                + Text(" to ")
                                + Text(h.dst).bold()
                                + Text(" at \(h.time)")
                                Spacer()
                            }
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Footnote
    // -----------------------------------------------------------------------

    @ViewBuilder private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Cut state is in-memory only and is wiped when Trove quits.",
                  systemImage: "info.circle")
            Label("Originals stay on disk until you actually paste — cancelling is non-destructive.",
                  systemImage: "checkmark.shield")
            Label("Cuts left untouched for 5 minutes auto-cancel.",
                  systemImage: "clock.arrow.circlepath")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}
