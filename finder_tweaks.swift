// Finder Tweaks — one-stop pane for the dozen Finder defaults that
// Windows refugees enable on day 1, plus a "Copy current Finder path" action.
//
// Step-up vs TinkerTool / OnyX / "Mac tips" blog recipes:
//   1. Plain-English explanations next to every toggle (not cryptic defaults keys).
//   2. Every toggle is reversible — reads current state, applies change, offers revert.
//   3. Live "Copy Finder Path" with ~ substitution (⌘⇧C).
//   4. "Reveal Path in Stage" sends the path as a Stage text item.

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - Shell + defaults
// ===========================================================================

/// Tiny shell-runner: returns stdout (trimmed), stderr, and exit code.
/// We use `/usr/bin/defaults`, `/usr/bin/killall`, and `/usr/bin/osascript`
/// — all sandbox-safe, no third-party deps.
enum FinderShell {
    struct Result {
        let stdout: String
        let stderr: String
        let code: Int32
        var ok: Bool { code == 0 }
    }

    static func run(_ path: String, _ args: [String]) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe
        do {
            try task.run()
        } catch {
            return Result(stdout: "", stderr: "launch failed: \(error)", code: -1)
        }
        task.waitUntilExitOffMain()
        // R5 fix #21: close pipe read handles after consuming data.
        defer {
            outPipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return Result(stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
                      stderr: err.trimmingCharacters(in: .whitespacesAndNewlines),
                      code: task.terminationStatus)
    }
}

/// Thin typed wrapper around the `defaults` CLI for the kinds of values we read/write.
enum FinderDefaults {
    enum Value {
        case bool(Bool)
        case float(Double)
        case string(String)

        var writeTokens: [String] {
            switch self {
            case .bool(let b):   return ["-bool",   b ? "true" : "false"]
            case .float(let d):  return ["-float",  String(d)]
            case .string(let s): return ["-string", s]
            }
        }
    }

    /// `domain == nil` → use `-g` (NSGlobalDomain).
    @discardableResult
    static func write(domain: String?, key: String, value: Value) -> FinderShell.Result {
        var args: [String] = ["write"]
        if let d = domain { args.append(d) } else { args.append("-g") }
        args.append(key)
        args.append(contentsOf: value.writeTokens)
        return FinderShell.run("/usr/bin/defaults", args)
    }

    /// Removes a key so the system reverts to its built-in default.
    @discardableResult
    static func delete(domain: String?, key: String) -> FinderShell.Result {
        var args: [String] = ["delete"]
        if let d = domain { args.append(d) } else { args.append("-g") }
        args.append(key)
        return FinderShell.run("/usr/bin/defaults", args)
    }

    /// Reads a key; returns nil if the key isn't set (exit 1 from `defaults read`).
    static func readRaw(domain: String?, key: String) -> String? {
        var args: [String] = ["read"]
        if let d = domain { args.append(d) } else { args.append("-g") }
        args.append(key)
        let r = FinderShell.run("/usr/bin/defaults", args)
        return r.ok ? r.stdout : nil
    }

    static func readBool(domain: String?, key: String) -> Bool? {
        guard let raw = readRaw(domain: domain, key: key) else { return nil }
        // `defaults read` for booleans yields "0" / "1" or "YES" / "NO" / "true" / "false".
        switch raw.lowercased() {
        case "1", "true", "yes":  return true
        case "0", "false", "no":  return false
        default:                  return nil
        }
    }
}

// ===========================================================================
// MARK: - Toggle definitions
// ===========================================================================

/// What `defaults write` should look like to turn this tweak ON.
/// Going OFF is modeled as `revertWrite` — sometimes that's "set false", sometimes
/// "set to a different string value" (NewWindowTarget), sometimes "delete the key".
struct FinderTweak: Identifiable {
    enum Restart { case finder, dock, none }
    enum DefaultOff { case bool, customString(String), deleteKey, float(Double) }

    let id: String
    let title: String
    let explanation: String        // plain-English "what this does + why a Windows refugee wants it"
    let domain: String?            // nil = -g (NSGlobalDomain)
    let key: String
    let onValue: FinderDefaults.Value
    let off: DefaultOff
    let restart: Restart
    let warning: String?           // shown on the row + triggers a destructive confirm when ENABLING
    let isApplyAll: Bool           // included in the "Apply all switcher defaults" button

    /// Read whether the tweak is currently ON.
    /// For string-valued keys (NewWindowTarget) we treat "current value matches onValue" as ON.
    func readState() -> Bool {
        switch onValue {
        case .bool(let want):
            return FinderDefaults.readBool(domain: domain, key: key) == want
        case .string(let want):
            return FinderDefaults.readRaw(domain: domain, key: key) == want
        case .float(let want):
            guard let raw = FinderDefaults.readRaw(domain: domain, key: key),
                  let v = Double(raw) else { return false }
            return abs(v - want) < 0.0001
        }
    }

    /// Apply ON or OFF. Returns the shell error message if it failed, else nil.
    func apply(_ on: Bool) -> String? {
        let r: FinderShell.Result
        if on {
            r = FinderDefaults.write(domain: domain, key: key, value: onValue)
        } else {
            switch off {
            case .bool:
                r = FinderDefaults.write(domain: domain, key: key, value: .bool(false))
            case .customString(let s):
                r = FinderDefaults.write(domain: domain, key: key, value: .string(s))
            case .float(let d):
                r = FinderDefaults.write(domain: domain, key: key, value: .float(d))
            case .deleteKey:
                r = FinderDefaults.delete(domain: domain, key: key)
            }
        }
        return r.ok ? nil : (r.stderr.isEmpty ? "defaults exited \(r.code)" : r.stderr)
    }
}

enum FinderTweakCatalog {
    static let all: [FinderTweak] = [
        // 1. Show all file extensions (global)
        FinderTweak(
            id: "ext",
            title: "Show all file extensions",
            explanation: "Always display .txt, .png, .app, etc. across every app — no more mystery files. On Windows this is the first checkbox everyone flips.",
            domain: nil,                              // -g
            key: "AppleShowAllExtensions",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 2. Show hidden files
        FinderTweak(
            id: "hidden",
            title: "Show hidden files",
            explanation: "Reveal dotfiles like .env, .gitignore, ~/.zshrc in Finder. Same as ⌘⇧. but persistent.",
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 3. Path bar
        FinderTweak(
            id: "pathbar",
            title: "Show path bar",
            explanation: "Always-visible breadcrumb strip at the bottom of every Finder window. Drag from it, ⌘-click to copy any ancestor path.",
            domain: "com.apple.finder",
            key: "ShowPathbar",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 4. Status bar
        FinderTweak(
            id: "statusbar",
            title: "Show status bar",
            explanation: "Bottom strip with item count + free space. Closest thing macOS has to Explorer's status bar.",
            domain: "com.apple.finder",
            key: "ShowStatusBar",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 5. New windows at Home
        FinderTweak(
            id: "newhome",
            title: "New windows open at Home",
            explanation: "⌘N opens your home folder instead of Recents. Way more useful when you actually know your filesystem.",
            domain: "com.apple.finder",
            key: "NewWindowTarget",
            onValue: .string("PfHm"),
            off: .customString("PfRe"),               // PfRe = Recents (the macOS default)
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 6. .DS_Store on network drives
        FinderTweak(
            id: "dsstore",
            title: "Disable .DS_Store on network drives",
            explanation: "Stops Finder from littering SMB / NFS shares with .DS_Store turds. Your Linux/Windows colleagues will thank you.",
            domain: "com.apple.desktopservices",
            key: "DSDontWriteNetworkStores",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 7. POSIX path in title bar
        FinderTweak(
            id: "posixtitle",
            title: "Show full POSIX path in title bar",
            explanation: "Window title shows /Users/you/Documents/Foo instead of just \"Foo\". Useful when you have a dozen folders named the same thing.",
            domain: "com.apple.finder",
            key: "_FXShowPosixPathInTitle",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 8. Gatekeeper / quarantine — SECURITY tradeoff
        FinderTweak(
            id: "quarantine",
            title: "Disable \"are you sure\" download prompt",
            explanation: "Turns off the quarantine flag that triggers Gatekeeper's first-run warning on every downloaded file. Faster, but you lose a real safety net — every downloaded binary runs without ceremony. Takes effect after the next log out / log in.",
            domain: "com.apple.LaunchServices",
            key: "LSQuarantine",
            onValue: .bool(false),
            off: .bool,                               // OFF == LSQuarantine true, the secure default
            restart: .none,
            warning: "Security tradeoff: this is the warning that catches drive-by downloads. Already-downloaded files keep their quarantine flag.",
            isApplyAll: false                         // never bulk-apply this one
        ),
        // 9. Dock auto-hide animation speed (compound key — we model the main one
        //    and apply the companion `autohide-delay` alongside in onValue handling below).
        FinderTweak(
            id: "dockspeed",
            title: "Faster Dock auto-hide animation",
            explanation: "Cuts the show/hide animation from 0.5s + 0.5s delay to 0.15s + 0s. Dock feels instant — closest you'll get to a real Windows-style autohide.",
            domain: "com.apple.dock",
            key: "autohide-time-modifier",
            onValue: .float(0.15),
            off: .deleteKey,                          // revert removes the override
            restart: .dock,
            warning: nil,
            isApplyAll: true
        ),
        // 10. Disable window resize/open animation (snappier feel, no visual noise)
        FinderTweak(
            id: "noanim",
            title: "Disable window open/close animation",
            explanation: "Sets the window animation duration to 0 — Finder windows open and close instantly instead of zooming in from the Dock. Much closer to Windows behavior.",
            domain: "NSGlobalDomain",
            key: "NSAutomaticWindowAnimationsEnabled",
            onValue: .bool(false),
            off: .bool,
            restart: .none,
            warning: nil,
            isApplyAll: true
        ),
        // 11. ⌘Q quits Finder (instead of just closing windows)
        FinderTweak(
            id: "cmdqfinder",
            title: "⌘Q quits Finder",
            explanation: "Without this, ⌘Q in Finder does nothing. Enable it to make Finder behave like every other app — ⌘Q terminates the process. You can always relaunch it.",
            domain: "com.apple.finder",
            key: "QuitMenuItem",
            onValue: .bool(true),
            off: .bool,
            restart: .finder,
            warning: nil,
            isApplyAll: true
        ),
        // 12. Expanded save/open dialogs by default
        FinderTweak(
            id: "expandsave",
            title: "Expanded save dialogs by default",
            explanation: "Shows the full filesystem navigator when saving files instead of the minimal name-only dialog. Windows refugees miss this every single day.",
            domain: "NSGlobalDomain",
            key: "NSNavPanelExpandedStateForSaveMode",
            onValue: .bool(true),
            off: .bool,
            restart: .none,
            warning: nil,
            isApplyAll: true
        ),
        // 13. Disable Resume (don't reopen windows from last session)
        FinderTweak(
            id: "noresume",
            title: "Disable window resume across app restarts",
            explanation: "Prevents macOS from reopening the windows each app had open last session. Speeds up restarts and avoids \"why did this open automatically?\" surprise.",
            domain: "com.apple.systempreferences",
            key: "NSQuitAlwaysKeepsWindows",
            onValue: .bool(false),
            off: .bool,
            restart: .none,
            warning: nil,
            isApplyAll: false
        ),
    ]
}

// ===========================================================================
// MARK: - AppleScript for current Finder path
// ===========================================================================

enum FinderPath {
    enum Outcome {
        case ok(String)             // POSIX path
        case noWindow
        case automationDenied       // -1743 (or generic permission text)
        case error(String)
    }

    /// Async version — never blocks main. The synchronous DispatchGroup.wait
    /// could stall main for up to 5 s (SECURITY: AppleScript calls Finder via
    /// XPC, which can deadlock if main is busy). Run entirely off-main and
    /// return the outcome via async/await so callers can stay on @MainActor.
    static func currentPathAsync() async -> Outcome {
        return await Task.detached(priority: .userInitiated) {
            let src = #"tell application "Finder" to get POSIX path of (target of front window as alias)"#
            guard let script = NSAppleScript(source: src) else {
                return Outcome.error("Could not compile AppleScript")
            }
            var errInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errInfo)

            if let info = errInfo {
                let num = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                let msg = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
                if num == -1728 || msg.localizedCaseInsensitiveContains("can't get target of front window") {
                    return .noWindow
                }
                if num == -1743 || num == 1002
                    || msg.localizedCaseInsensitiveContains("not authorized")
                    || msg.localizedCaseInsensitiveContains("not allowed") {
                    return .automationDenied
                }
                return .error("AppleScript error \(num): \(msg)")
            }
            guard let path = descriptor.stringValue, !path.isEmpty else {
                return .noWindow
            }
            return .ok(path)
        }.value
    }

    // Keep the synchronous variant for any callers that are already off-main.
    static func currentPath() -> Outcome {
        let src = #"tell application "Finder" to get POSIX path of (target of front window as alias)"#
        guard let script = NSAppleScript(source: src) else {
            return .error("Could not compile AppleScript")
        }
        var errInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errInfo)

        if let info = errInfo {
            let num = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
            if num == -1728 || msg.localizedCaseInsensitiveContains("can't get target of front window") {
                return .noWindow
            }
            if num == -1743 || num == 1002
                || msg.localizedCaseInsensitiveContains("not authorized")
                || msg.localizedCaseInsensitiveContains("not allowed") {
                return .automationDenied
            }
            return .error("AppleScript error \(num): \(msg)")
        }
        guard let path = descriptor.stringValue, !path.isEmpty else {
            return .noWindow
        }
        return .ok(path)
    }

    /// `/Users/foo/Bar` → `~/Bar`. Leaves anything outside $HOME untouched.
    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// ===========================================================================
// MARK: - View model
// ===========================================================================

/// State for a single tweak row.
struct FinderTweakRowState: Identifiable {
    let id: String                  // == FinderTweak.id
    var on: Bool
    var error: String?
    // red-team: capture the raw on-disk value at the moment the user flips the
    // toggle ON, so disabling restores *that exact value* instead of stomping
    // it with a hardcoded "false" / default string. Nil means the key was
    // unset on enable (system default), so disable should `defaults delete`
    // rather than write false. Cleared after restore so a subsequent
    // enable→disable cycle re-captures fresh state.
    var priorRawOnEnable: String?
}

@MainActor
final class FinderTweaksModel: ObservableObject {
    @Published var rows: [FinderTweakRowState] = []
    @Published var lastPath: String? = nil
    @Published var pathStatus: String? = nil
    /// Set when the most recent `currentPath()` call returned `.automationDenied`.
    /// Drives the inline "Open System Settings" deep-link button next to the
    /// pathStatus error message. Reset to false whenever pathStatus is cleared
    /// or replaced by a non-permission error.
    @Published var pathAutomationDenied: Bool = false
    @Published var didConfirmRestart: Bool = false        // once-per-session NSAlert gate
    @Published var isRevertingAll: Bool = false

    let tweaks: [FinderTweak] = FinderTweakCatalog.all

    init() {
        // Seed rows synchronously so the UI has stable identity (one row per
        // tweak) before the actual state lands. Initial `on` is `false`; the
        // real value gets patched in by `refreshAll()`, which dispatches its
        // shell reads to a background task. Same pattern as `CleanModel.init`
        // — this is the canonical fix for `@StateObject` init blocking main.
        rows = tweaks.map { FinderTweakRowState(id: $0.id, on: false, error: nil) }
        refreshAll()
    }

    /// Re-read every row's current state from `defaults`. Shell reads run on
    /// a background task; the @Published `rows` array is replaced on main
    /// when the snapshot lands. Safe to call from main — never blocks. Called
    /// on `.task` and on tab-return so the UI reflects external `defaults
    /// write` calls.
    func refreshAll() {
        let snapshot = tweaks
        Task.detached(priority: .userInitiated) { [weak self] in
            let new = snapshot.map { t in
                FinderTweakRowState(id: t.id, on: t.readState(), error: nil)
            }
            await MainActor.run { self?.rows = new }
        }
    }

    /// Refresh a single row's state from disk (used after apply). Shell read
    /// happens off-main; the patched row is published on main.
    func refresh(_ id: String) {
        guard let t = tweaks.first(where: { $0.id == id }) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let newOn = t.readState()
            await MainActor.run {
                guard let self else { return }
                if let idx = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[idx].on = newOn
                }
            }
        }
    }

    func tweak(_ id: String) -> FinderTweak? { tweaks.first(where: { $0.id == id }) }

    /// Asks the user once per session whether killing Finder/Dock is OK.
    /// Returns true if we may proceed.
    func confirmRestartIfNeeded() -> Bool {
        if didConfirmRestart { return true }
        let a = NSAlert()
        a.messageText = "Some toggles need to restart Finder or the Dock to take effect."
        a.informativeText = "Trove will run `killall Finder` / `killall Dock` automatically. " +
            "Open Finder operations may be interrupted — save anything in progress."
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        let resp = a.runModal()
        if resp == .alertFirstButtonReturn {
            didConfirmRestart = true
            return true
        }
        return false
    }

    /// Destructive-confirm for enabling the Gatekeeper toggle.
    /// Returns true if the user accepted.
    func confirmGatekeeperDisable() -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Really disable the download quarantine warning?"
        a.informativeText = "This is the macOS check that catches drive-by downloads. With it off, every downloaded executable runs the first time you double-click it — no warning. You can turn this back on at any time."
        a.addButton(withTitle: "Disable Quarantine")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Toggle a single row. Confirms run on main (NSAlert), shell work runs
    /// off-main (every FinderShell / FinderDefaults call blocks on a child
    /// process and would fire `preconditionNotMainThread` if invoked
    /// synchronously from the toggle's button action).
    func setRow(_ id: String, to on: Bool) {
        guard let idx = rows.firstIndex(where: { $0.id == id }),
              let t = tweak(id) else { return }

        // ---- Phase 1 (main): user confirmations require NSAlert ---------
        if t.id == "quarantine" && on {
            if !confirmGatekeeperDisable() {
                // red-team-sec: resolve true on-disk state asynchronously
                // rather than hard-coding `false`; an external `defaults
                // write` (e.g. enterprise MDM) could disagree with the UI.
                refresh(id)
                return
            }
        }
        if t.restart != .none {
            if !confirmRestartIfNeeded() {
                rows[idx].on = !on
                return
            }
        }

        // Optimistic UI flip so the toggle is responsive while shell work
        // runs. If apply() errors, we revert on the main hop below.
        let wasOn = rows[idx].on
        let priorSnapshot = rows[idx].priorRawOnEnable
        rows[idx].on = on

        // ---- Phase 2 (background): shell work --------------------------
        let tweakRef = t
        Task.detached(priority: .userInitiated) { [weak self] in
            // Snapshot prior raw value on OFF→ON transitions.
            let newPrior: String? = (on && !wasOn)
                ? FinderDefaults.readRaw(domain: tweakRef.domain, key: tweakRef.key)
                : nil

            // Apply the tweak's on/off semantics, restoring the user's
            // pre-enable raw value when toggling OFF if we have a snapshot.
            let applyErr: String?
            if on {
                applyErr = tweakRef.apply(true)
            } else if let prior = priorSnapshot {
                applyErr = Self.restorePriorRawSync(tweak: tweakRef, raw: prior)
            } else {
                applyErr = tweakRef.apply(false)
            }

            // Companion writes for the Dock speed toggle.
            if tweakRef.id == "dockspeed" {
                if on {
                    _ = FinderDefaults.write(domain: "com.apple.dock",
                                             key: "autohide-delay",
                                             value: .float(0.0))
                } else {
                    _ = FinderDefaults.delete(domain: "com.apple.dock", key: "autohide-delay")
                }
            }

            // Restart the affected process so the change takes effect.
            switch tweakRef.restart {
            case .finder: _ = FinderShell.run("/usr/bin/killall", ["Finder"])
            case .dock:   _ = FinderShell.run("/usr/bin/killall", ["Dock"])
            case .none:   break
            }

            // ---- Phase 3 (main): publish result -----------------------
            await MainActor.run {
                guard let self else { return }
                guard let idx = self.rows.firstIndex(where: { $0.id == id }) else { return }
                if let err = applyErr {
                    self.rows[idx].error = err
                    self.rows[idx].on = wasOn   // revert
                    return
                }
                self.rows[idx].error = nil
                if let snap = newPrior { self.rows[idx].priorRawOnEnable = snap }
                if !on { self.rows[idx].priorRawOnEnable = nil }
                // cfprefsd caches writes for ~100ms; defer the re-read so
                // the badge reflects committed state.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.refresh(id)
                }
            }
        }
    }

    /// Write `raw` back to the tweak's key using the tweak's declared value-type.
    /// Used to restore a captured pre-enable value on disable, so we don't stomp
    /// non-default user customizations with a hardcoded fallback.
    // red-team: we have to match the tweak's value-type because `defaults write`
    // is typed — passing "1" with -string when the rest of macOS expects -bool
    // would silently change the key's type and break readers. Booleans come
    // out of `defaults read` as 0/1, floats as decimals, strings as the
    // verbatim payload.
    /// Renamed to `restorePriorRawSync` + `nonisolated static` because the
    /// new `setRow` calls it from a `Task.detached` closure that runs off
    /// the main actor; the method only depends on its inputs.
    nonisolated static func restorePriorRawSync(tweak t: FinderTweak, raw: String) -> String? {
        let value: FinderDefaults.Value
        switch t.onValue {
        case .bool:
            switch raw.lowercased() {
            case "1", "true", "yes":  value = .bool(true)
            case "0", "false", "no":  value = .bool(false)
            default:
                // Unparseable — safest fallback is the modeled OFF behavior.
                return t.apply(false)
            }
        case .float:
            guard let d = Double(raw) else { return t.apply(false) }
            value = .float(d)
        case .string:
            value = .string(raw)
        }
        let r = FinderDefaults.write(domain: t.domain, key: t.key, value: value)
        return r.ok ? nil : (r.stderr.isEmpty ? "defaults exited \(r.code)" : r.stderr)
    }

    /// Apply every non-warning tweak in one shot. Single confirm covers them all.
    /// Now async: confirm runs on main, all shell work runs off-main, results
    /// publish back on main. Caller wraps in `Task { … }`.
    func applyAllSwitcherDefaults() async -> (applied: Int, failed: Int) {
        if !confirmRestartIfNeeded() { return (0, 0) }

        // Snapshot the (tweak, wasOn) pairs we need from main BEFORE going off
        // main, so the background task is self-contained and `Sendable`.
        let pairs: [(FinderTweak, Bool)] = tweaks
            .filter { $0.isApplyAll }
            .map { t in (t, rows.first(where: { $0.id == t.id })?.on ?? false) }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            var applied = 0, failed = 0
            var snapshots: [(String, String)] = []   // (rowId, priorRaw)
            var errors:    [(String, String)] = []   // (rowId, err)
            var nfr = false, ndr = false

            for (t, wasOn) in pairs {
                if !wasOn, let raw = FinderDefaults.readRaw(domain: t.domain, key: t.key) {
                    snapshots.append((t.id, raw))
                }
                if let err = t.apply(true) {
                    errors.append((t.id, err))
                    failed += 1
                    continue
                }
                if t.id == "dockspeed" {
                    _ = FinderDefaults.write(domain: "com.apple.dock",
                                             key: "autohide-delay",
                                             value: .float(0.0))
                }
                applied += 1
                switch t.restart {
                case .finder: nfr = true
                case .dock:   ndr = true
                case .none:   break
                }
            }
            if nfr { _ = FinderShell.run("/usr/bin/killall", ["Finder"]) }
            if ndr { _ = FinderShell.run("/usr/bin/killall", ["Dock"]) }

            await MainActor.run {
                guard let self else { return }
                for (id, raw) in snapshots {
                    if let idx = self.rows.firstIndex(where: { $0.id == id }) {
                        self.rows[idx].priorRawOnEnable = raw
                    }
                }
                for (id, err) in errors {
                    if let idx = self.rows.firstIndex(where: { $0.id == id }) {
                        self.rows[idx].error = err
                    }
                }
                self.refreshAll()
            }
            return (applied, failed)
        }.value
    }

    // -----------------------------------------------------------------------
    // Revert all to system defaults
    // -----------------------------------------------------------------------

    /// Destructive-confirm for reverting every tweak back to its system default.
    func confirmRevertAll() -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Revert all Finder tweaks to macOS defaults?"
        a.informativeText = "This will undo all active toggles and restart Finder and the Dock. Your previous customisations cannot be recovered unless you re-apply them manually."
        a.addButton(withTitle: "Revert All")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Revert every currently-active tweak back to its OFF state, then restart.
    func revertAllToDefaults() async -> (reverted: Int, failed: Int) {
        // Phase 1: confirm on main (NSAlert must be main).
        guard confirmRevertAll() else { return (0, 0) }
        isRevertingAll = true
        defer { Task { @MainActor [weak self] in self?.isRevertingAll = false } }

        // Snapshot which tweaks are ON so we can turn them off.
        let activeRows = rows.filter { $0.on }
        let activePairs: [(FinderTweak, FinderTweakRowState)] = activeRows.compactMap { state in
            guard let t = tweak(state.id) else { return nil }
            return (t, state)
        }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            var reverted = 0, failed = 0
            var nfr = false, ndr = false
            for (t, state) in activePairs {
                // Restore prior raw value if we captured one, otherwise apply(false).
                let err: String?
                if let prior = state.priorRawOnEnable {
                    err = FinderTweaksModel.restorePriorRawSync(tweak: t, raw: prior)
                } else {
                    err = t.apply(false)
                }
                if err != nil { failed += 1; continue }
                reverted += 1
                switch t.restart {
                case .finder: nfr = true
                case .dock:   ndr = true
                case .none:   break
                }
            }
            if nfr { _ = FinderShell.run("/usr/bin/killall", ["Finder"]) }
            if ndr { _ = FinderShell.run("/usr/bin/killall", ["Dock"]) }
            await MainActor.run { self?.refreshAll() }
            return (reverted, failed)
        }.value
    }

    // -----------------------------------------------------------------------
    // Path actions (fully off-main via async API)
    // -----------------------------------------------------------------------

    /// Fetch path off-main, then copy to clipboard on @MainActor.
    func copyCurrentFinderPath() async -> String? {
        let outcome = await FinderPath.currentPathAsync()
        // Apply result on @MainActor (this method is already @MainActor via class isolation).
        return applyPathOutcome(outcome) { tilde in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(tilde, forType: .string)
        }
    }

    /// Fetch path off-main, then send to Stage on @MainActor.
    func sendCurrentFinderPathToStage(via stage: Stage) async -> String? {
        let outcome = await FinderPath.currentPathAsync()
        return applyPathOutcome(outcome) { tilde in
            stage.addText(tilde)
        }
    }

    /// Common outcome handler — must be called on @MainActor.
    @MainActor
    @discardableResult
    private func applyPathOutcome(_ outcome: FinderPath.Outcome,
                                  onSuccess: (String) -> Void) -> String? {
        switch outcome {
        case .ok(let p):
            let tilde = FinderPath.tildify(p)
            lastPath = tilde
            pathStatus = nil
            pathAutomationDenied = false
            onSuccess(tilde)
            return tilde
        case .noWindow:
            pathStatus = "No Finder window open."
            pathAutomationDenied = false
            return nil
        case .automationDenied:
            pathStatus = "Finder automation not allowed — grant in System Settings → Privacy & Security → Automation → Trove → Finder."
            pathAutomationDenied = true
            return nil
        case .error(let msg):
            pathStatus = msg
            pathAutomationDenied = false
            return nil
        }
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct FinderTweaksView: View {
    @EnvironmentObject var stage: Stage
    @StateObject private var model = FinderTweaksModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !finderRunning {
                    finderNotRunningCard
                }
                headerCard
                pathActionsCard
                togglesSection
            }
            .padding(24)
        }
        .navigationTitle("Finder Tweaks")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar() }
        .task { model.refreshAll() }
        .onAppear { model.refreshAll() }
    }

    private var finderRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty
    }

    private var finderNotRunningCard: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.orange)
                Text("Finder isn't running")
                    .headerText()
                Text("Toggles still work (they write to defaults), but \"Copy current Finder path\" and any restart-Finder side effects won't fire until Finder is back. Trove can re-launch it for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
                Button {
                    NSWorkspace.shared.launchApplication("Finder")
                } label: {
                    Label("Launch Finder", systemImage: "play.fill")
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private var subtitle: String {
        if let s = stage.transientStatus { return s }
        if let p = model.lastPath { return p }
        let onCount = model.rows.filter { $0.on }.count
        return "\(onCount) of \(model.rows.count) tweaks active"
    }

    // -----------------------------------------------------------------------
    // Header — bulk apply
    // -----------------------------------------------------------------------

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "wand.and.rays")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Day-1 Finder defaults").headerText()
                        Text("Plain-English toggles for the same `defaults write` recipes every Mac-tips blog tells you to copy-paste. Every change is reversible.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            Task {
                                let r = await model.applyAllSwitcherDefaults()
                                if r.failed == 0 {
                                    stage.flash("Applied \(r.applied) Finder tweaks")
                                } else {
                                    stage.flash("Applied \(r.applied), \(r.failed) failed — see rows")
                                }
                            }
                        } label: {
                            Label("Apply all switcher defaults", systemImage: "checkmark.circle.fill")
                        }
                        .controlSize(.large)
                        .help("Turns on all non-security toggles at once and restarts Finder/Dock once.")

                        // Destructive revert — only show when at least one tweak is ON.
                        if model.rows.contains(where: { $0.on }) {
                            Button(role: .destructive) {
                                Task {
                                    let r = await model.revertAllToDefaults()
                                    if r.reverted > 0 {
                                        stage.flash("Reverted \(r.reverted) tweaks to macOS defaults")
                                    } else if r.failed > 0 {
                                        stage.flash("Revert had \(r.failed) errors — check individual rows", kind: .warning)
                                    }
                                }
                            } label: {
                                Label("Revert all to defaults", systemImage: "arrow.counterclockwise.circle")
                            }
                            .disabled(model.isRevertingAll)
                            .help("Undo all active tweaks and restart Finder/Dock.")
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Path actions
    // -----------------------------------------------------------------------

    private var pathActionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    Text("Current Finder path").headerText()
                    Spacer()
                    if let p = model.lastPath {
                        Text(p)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text("Grabs the path of the frontmost Finder window via AppleScript, substitutes `~` for your home folder, and either copies it or sends it to Stage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { @MainActor in
                            if let p = await model.copyCurrentFinderPath() {
                                stage.flash("Copied: \(p)")
                            } else if let err = model.pathStatus {
                                flashPathError(err)
                            }
                        }
                    } label: {
                        Label("Copy current Finder path", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("⌘⇧C — copies the frontmost Finder window's path to the clipboard with ~ substitution.")

                    Button {
                        Task { @MainActor in
                            if let p = await model.sendCurrentFinderPathToStage(via: stage) {
                                stage.flash("Sent to Stage: \(p)")
                            } else if let err = model.pathStatus {
                                flashPathError(err)
                            }
                        }
                    } label: {
                        Label("Send Finder path to Stage", systemImage: "tray.and.arrow.up")
                    }
                    .help("Adds the path as a text item on the Stage, ready to forward elsewhere.")

                    Spacer()
                }

                if let err = model.pathStatus {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if model.pathAutomationDenied {
                            // red-team: this is the deep-link hand-off. We
                            // show it only when the failure was specifically
                            // automation-denied so the user isn't pointed at
                            // the wrong Privacy sub-pane for unrelated errors
                            // (e.g. "No Finder window open").
                            Button {
                                TCCDeepLink.automation.open()
                            } label: {
                                Label("Open System Settings",
                                      systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Toggle rows
    // -----------------------------------------------------------------------

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Toggles").headerText()
                Spacer()
                Text("\(model.rows.filter { $0.on }.count) / \(model.rows.count) on")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(model.tweaks) { tweak in
                let state = model.rows.first { $0.id == tweak.id }
                    ?? FinderTweakRowState(id: tweak.id, on: false, error: nil)
                FinderTweakRow(tweak: tweak, state: state) { newValue in
                    model.setRow(tweak.id, to: newValue)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Toolbar
    // -----------------------------------------------------------------------

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refreshAll()
                stage.flash("Refreshed Finder tweak state")
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read every toggle's current state from `defaults` — handy if you changed something outside Trove.")

            Button {
                Task { @MainActor in
                    if let p = await model.copyCurrentFinderPath() {
                        stage.flash("Copied: \(p)")
                    } else if let err = model.pathStatus {
                        flashPathError(err)
                    }
                }
            } label: {
                Label("Copy Finder Path", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("⌘⇧C")
        }
    }

    /// Emit a toast for a Finder-path failure. When the error is the
    /// automation-denied case, attach an action button that deep-links into
    /// System Settings → Privacy → Automation; otherwise fall back to a
    /// plain warning so we don't mislead the user about which pane to open.
    private func flashPathError(_ err: String) {
        if model.pathAutomationDenied {
            stage.flash(err,
                        kind: .warning,
                        actionLabel: "Open Settings") {
                TCCDeepLink.automation.open()
            }
        } else {
            stage.flash(err, kind: .warning)
        }
    }
}

// ===========================================================================
// MARK: - Row
// ===========================================================================

private struct FinderTweakRow: View {
    let tweak: FinderTweak
    let state: FinderTweakRowState
    let onToggle: (Bool) -> Void

    private var statusBadge: some View {
        let on = state.on
        return HStack(spacing: 4) {
            Circle()
                .fill(on ? .green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(on ? "Active" : "Default")
                .font(.caption2.weight(.medium))
                .foregroundStyle(on ? .green : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.troveCardSolid.opacity(0.6))
        )
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var restartLabel: String? {
        switch tweak.restart {
        case .finder: return "Restarts Finder"
        case .dock:   return "Restarts Dock"
        case .none:   return nil
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if tweak.warning != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(tweak.warning ?? "")
                            }
                            Text(tweak.title).headerText()
                            statusBadge
                            if let r = restartLabel {
                                Text(r)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.troveCardSolid.opacity(0.6)))
                            }
                        }
                        Text(tweak.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let w = tweak.warning {
                            Text(w)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(defaultsHint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.on },
                        set: { onToggle($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                if let err = state.error {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// The `defaults write …` line, shown small + selectable so power users
    /// can verify what's actually being run.
    private var defaultsHint: String {
        let dom = tweak.domain ?? "-g"
        switch tweak.onValue {
        case .bool(let b):
            return "defaults write \(dom) \(tweak.key) -bool \(b)"
        case .float(let d):
            return "defaults write \(dom) \(tweak.key) -float \(d)"
        case .string(let s):
            return "defaults write \(dom) \(tweak.key) -string \(s)"
        }
    }
}
