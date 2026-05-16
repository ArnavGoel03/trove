// Trove — Keep Awake pane.
//
// Amphetamine-class display-sleep / system-idle-sleep blocker, built around
// IOPMAssertion(). Master toggle + optional system-sleep sub-assertion,
// stacked conditional rules (frontmost app / until time / plugged in /
// battery threshold), quick-caffeinate buttons, optional menu-bar status item.
//
// Red-team notes are inline at each non-obvious decision. Lifecycle is the
// hot path: a held IOPMAssertion outlives the SwiftUI tree, so we wire
// willTerminateNotification + atexit() to guarantee release.

import SwiftUI
import AppKit
import Combine
import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

// ===========================================================================
// MARK: - Model
// ===========================================================================

enum KeepAwakeTrigger: String, CaseIterable, Identifiable {
    case frontmostApp   = "While app X is frontmost"
    case untilTime      = "Until time"
    case whilePluggedIn = "While plugged in (AC)"
    case batteryAbove   = "Until battery drops below N%"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .frontmostApp:   return "app.dashed"
        case .untilTime:      return "clock"
        case .whilePluggedIn: return "powerplug"
        case .batteryAbove:   return "battery.50"
        }
    }
}

/// Snapshot of why a particular release fired, surfaced as a toast.
enum KeepAwakeReleaseCause: String {
    case userToggle      = "Turned off by user"
    case appLostFocus    = "App lost focus"
    case timeReached     = "Scheduled time reached"
    case onBattery       = "Switched to battery power"
    case batteryLow      = "Battery below threshold"
    case quickExpired    = "Quick caffeinate expired"
    case appTerminating  = "Trove is quitting"
}

/// Live snapshot of power state, refreshed every 30s.
struct KeepAwakePowerSnapshot {
    var onAC: Bool
    var batteryPercent: Int?    // nil on desktops

    static var unknown: KeepAwakePowerSnapshot { .init(onAC: true, batteryPercent: nil) }
}

// ===========================================================================
// MARK: - IOPMAssertion wrapper
// ===========================================================================

/// Thin owner around two optional `IOPMAssertionID`s (display + system). All
/// access is main-actor; mutation is paired (`take`/`release`) and idempotent.
/// `atexit` registers `releaseAllForExit()` so a clean exit never leaks an
/// assertion. The OS reclaims on crash, but clean-exit leakage would survive
/// across "Quit Trove" + relaunch within the same login session.
@MainActor
final class KeepAwakeAssertion {
    static let shared = KeepAwakeAssertion()

    private var displayID: IOPMAssertionID = IOPMAssertionID(0)
    private var systemID:  IOPMAssertionID = IOPMAssertionID(0)
    private(set) var hasDisplay: Bool = false
    private(set) var hasSystem:  Bool = false
    private(set) var startedAt:  Date? = nil
    private(set) var reason:     String = "Trove · Keep Awake"

    // Shadow copies of the live IDs, guarded by an unfair lock. Written from
    // main on every take/release; read by the atexit handler, which can fire
    // off any thread. We *don't* try to read the @MainActor properties from
    // the exit hook — `MainActor.assumeIsolated` would trap if main is gone.
    nonisolated(unsafe) private static var exitLock = os_unfair_lock_s()
    nonisolated(unsafe) private static var exitDisplayID: IOPMAssertionID = IOPMAssertionID(0)
    nonisolated(unsafe) private static var exitSystemID:  IOPMAssertionID = IOPMAssertionID(0)
    nonisolated(unsafe) private static var exitHookRegistered: Bool = false

    private init() {
        // red-team #1: IOPMAssertions are bound to the creating PID. When the
        // process dies (SIGKILL, crash, panic, force-quit) the kernel-side
        // powerd reclaims every assertion held by that PID — verified in
        // <IOKit/pwr_mgt/IOPMLib.h> and the IOPMAssertionCreateWithName(3)
        // man page ("the assertion is automatically released if its owning
        // process dies"). So crash-leak is structurally impossible.
        //
        // What atexit covers is the *graceful* exit(0) path (e.g. a future
        // CLI subcommand or a fatalError reached via abort handlers) where
        // willTerminate doesn't fire. The hook reads from a lock-guarded
        // shadow, never from main-isolated state, so it's safe to run off-
        // main. Together: willTerminate (clean app quit) + atexit (clean
        // exit() bypass of NSApp) + kernel reclamation (anything violent).
        Self.registerExitHookOnce()
    }

    private static func registerExitHookOnce() {
        os_unfair_lock_lock(&exitLock); defer { os_unfair_lock_unlock(&exitLock) }
        if exitHookRegistered { return }
        exitHookRegistered = true
        atexit {
            os_unfair_lock_lock(&KeepAwakeAssertion.exitLock)
            let d = KeepAwakeAssertion.exitDisplayID
            let s = KeepAwakeAssertion.exitSystemID
            KeepAwakeAssertion.exitDisplayID = IOPMAssertionID(0)
            KeepAwakeAssertion.exitSystemID  = IOPMAssertionID(0)
            os_unfair_lock_unlock(&KeepAwakeAssertion.exitLock)
            if d != IOPMAssertionID(0) { IOPMAssertionRelease(d) }
            if s != IOPMAssertionID(0) { IOPMAssertionRelease(s) }
        }
    }

    private func writeShadow() {
        os_unfair_lock_lock(&Self.exitLock); defer { os_unfair_lock_unlock(&Self.exitLock) }
        Self.exitDisplayID = hasDisplay ? displayID : IOPMAssertionID(0)
        Self.exitSystemID  = hasSystem  ? systemID  : IOPMAssertionID(0)
    }

    /// Take both display (always) and system (optional) assertions.
    /// Returns true if at least the display assertion was taken.
    @discardableResult
    func take(preventSystemSleep: Bool, reason: String) -> Bool {
        // Idempotent: if we already hold a display assertion, just sync the
        // system-sleep half to match `preventSystemSleep`.
        if !hasDisplay {
            let cfReason = (reason as CFString)
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                cfReason,
                &id)
            if rc == kIOReturnSuccess {
                displayID = id
                hasDisplay = true
                startedAt = Date()
                self.reason = reason
            } else {
                return false
            }
        }
        if preventSystemSleep && !hasSystem {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                (reason as CFString),
                &id)
            if rc == kIOReturnSuccess {
                systemID = id
                hasSystem = true
            }
        } else if !preventSystemSleep && hasSystem {
            IOPMAssertionRelease(systemID)
            systemID = IOPMAssertionID(0)
            hasSystem = false
        }
        writeShadow()
        return hasDisplay
    }

    /// Release everything. Safe to call when nothing is held.
    func releaseAll() {
        if hasDisplay {
            IOPMAssertionRelease(displayID)
            displayID = IOPMAssertionID(0)
            hasDisplay = false
        }
        if hasSystem {
            IOPMAssertionRelease(systemID)
            systemID = IOPMAssertionID(0)
            hasSystem = false
        }
        startedAt = nil
        writeShadow()
    }

    /// Sync only the system-sleep half. Used when the sub-toggle changes
    /// while the master is already on.
    func setSystemSleepBlocked(_ blocked: Bool) {
        if blocked && hasDisplay && !hasSystem {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                (reason as CFString), &id) == kIOReturnSuccess
            {
                systemID = id
                hasSystem = true
            }
        } else if !blocked && hasSystem {
            IOPMAssertionRelease(systemID)
            systemID = IOPMAssertionID(0)
            hasSystem = false
        }
        writeShadow()
    }
}

// ===========================================================================
// MARK: - Power-source poll (battery + AC state)
// ===========================================================================

/// 30s poll of `IOPSCopyPowerSourcesInfo`. Cheap (a single CF call), no
/// notification API would be more correct here but the notification source
/// (`IOPSNotificationCreateRunLoopSource`) requires a CFRunLoopSource dance
/// that complicates Swift Concurrency lifetime. Poll is fine at 30s.
@MainActor
final class KeepAwakePowerWatcher: ObservableObject {
    @Published private(set) var snapshot: KeepAwakePowerSnapshot = .unknown

    private var timer: DispatchSourceTimer?
    private var subscribers: Int = 0

    func start() {
        subscribers += 1
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .seconds(30))
        t.setEventHandler { [weak self] in self?.refresh() }
        timer = t
        t.resume()
        refresh()
    }

    func stop() {
        subscribers -= 1
        if subscribers <= 0 {
            subscribers = 0
            timer?.cancel()
            timer = nil
        }
    }

    func refresh() {
        snapshot = KeepAwakePowerWatcher.read()
    }

    // red-team: cancel the timer in deinit so a coordinator drop doesn't
    // leak the 30-second power poll. `start`/`stop` are reference-counted,
    // but a force-drop of the owner (tests, or a future refactor) would
    // bypass the matched-pair guarantee.
    deinit {
        timer?.cancel()
        timer = nil
    }

    static func read() -> KeepAwakePowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .unknown
        }
        var onAC = true
        var pct: Int? = nil
        for s in sources {
            guard let dict = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let state = dict[kIOPSPowerSourceStateKey] as? String {
                onAC = (state != kIOPSBatteryPowerValue)
            }
            if let cur = dict[kIOPSCurrentCapacityKey] as? Int,
               let max = dict[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = Int((Double(cur) / Double(max)) * 100.0)
            }
        }
        return .init(onAC: onAC, batteryPercent: pct)
    }
}

// ===========================================================================
// MARK: - Coordinator (owns timers + observers)
// ===========================================================================

/// Single source of truth for the pane. Owns the assertion, the frontmost-app
/// observer, the time-based DispatchSourceTimer, and the menu-bar status item.
/// View is a thin shell that flips bindings here.
@MainActor
final class KeepAwakeCoordinator: ObservableObject {
    static let shared = KeepAwakeCoordinator()

    // ---- published state ----
    @Published var masterOn: Bool = false
    @Published var preventSystemSleep: Bool = false
    @Published var showInMenuBar: Bool = false

    // Rule toggles + their parameters.
    @Published var ruleFrontmostOn: Bool = false
    @Published var ruleFrontmostBundleID: String? = nil
    @Published var ruleFrontmostName: String = ""

    @Published var ruleUntilTimeOn: Bool = false
    @Published var ruleUntilDate: Date = Date().addingTimeInterval(60 * 60)

    @Published var ruleWhilePluggedOn: Bool = false

    @Published var ruleBatteryAboveOn: Bool = false
    @Published var ruleBatteryThreshold: Double = 30  // 10–95

    // Derived display state.
    @Published var displayName: String = ""
    @Published var displayUptime: String = ""

    // ---- internals ----
    private var frontmostObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var releaseTimer: DispatchSourceTimer?  // for "until time"
    private var uptimeTimer: DispatchSourceTimer?   // for header label
    private var quickExpireAt: Date? = nil
    private var statusItem: NSStatusItem?

    private let power = KeepAwakePowerWatcher()
    private var powerCancellable: AnyCancellable?
    /// Tracks whether *this coordinator* has a live `power.start()` call
    /// pending a matching `stop()`. Pair-balanced to keep the watcher's
    /// internal subscriber count honest.
    private var powerWatcherActive: Bool = false

    /// Released when willTerminate fires — release everything cleanly.
    private init() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // red-team #1: guaranteed release on graceful quit. NSApp.terminate
            // fires this before exit().
            Task { @MainActor [weak self] in
                self?.releaseEverything(cause: .appTerminating, silent: true)
            }
        }
    }

    // red-team #1b: coordinator is a singleton, so deinit is unreachable in
    // production — but if anyone ever reassigns `shared` (tests, hot-reload,
    // a future refactor) we must not leak the observer token. Pair `init`'s
    // addObserver with a deinit removeObserver.
    deinit {
        if let tok = willTerminateObserver {
            NotificationCenter.default.removeObserver(tok)
        }
        if let tok = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(tok)
        }
        releaseTimer?.cancel()
        uptimeTimer?.cancel()
    }

    /// Snapshot binding for the View to read. Power watcher start/stop is
    /// reference-counted, so multiple consumers Just Work.
    var powerSnapshot: KeepAwakePowerSnapshot { power.snapshot }
    var powerWatcher: KeepAwakePowerWatcher { power }

    // ---- public API ----

    func toggleMaster(_ on: Bool) {
        masterOn = on
        if on {
            applyAssertions(reason: assertionReason())
            refreshObserversForActiveRules()
            startUptimeTicker()
            evaluateRulesNow()  // immediate guard (e.g. already on battery)
            flash("Keep Awake on — \(activeRulesSummary())")
        } else {
            releaseEverything(cause: .userToggle)
        }
        syncMenuBar()
    }

    func toggleSystemSleep(_ on: Bool) {
        preventSystemSleep = on
        if masterOn {
            KeepAwakeAssertion.shared.setSystemSleepBlocked(on)
        }
        syncMenuBar()
    }

    func toggleMenuBar(_ on: Bool) {
        showInMenuBar = on
        syncMenuBar()
    }

    /// Quick-caffeinate buttons. Replaces any existing rule with a one-shot
    /// time release (or no release for "indefinite" / "until quit").
    func quickCaffeinate(_ hours: Double?) {
        // Reset rules — quick caffeinate is intentionally simple.
        ruleFrontmostOn = false
        ruleUntilTimeOn = false
        ruleWhilePluggedOn = false
        ruleBatteryAboveOn = false
        if let h = hours {
            ruleUntilTimeOn = true
            ruleUntilDate = Date().addingTimeInterval(h * 3600)
            quickExpireAt = ruleUntilDate
        } else {
            quickExpireAt = nil
        }
        toggleMaster(true)
    }

    /// Re-evaluate based on the live rule set. Called from rule-edit UI and
    /// from the power-watcher refresh closure.
    ///
    /// red-team #2 (observer install): rule toggles route here *and* into
    /// `refreshObserversForActiveRules`, so flipping a rule on AFTER the
    /// master is already on still wires up its observer/timer. Without that
    /// re-wire, "enable frontmost rule while caffeinated" would never fire.
    func evaluateRulesNow() {
        guard masterOn else { return }
        refreshObserversForActiveRules()
        let snap = power.snapshot

        if ruleWhilePluggedOn && !snap.onAC {
            releaseEverything(cause: .onBattery); return
        }
        if ruleBatteryAboveOn, let p = snap.batteryPercent, Double(p) < ruleBatteryThreshold {
            releaseEverything(cause: .batteryLow); return
        }
        if ruleUntilTimeOn && ruleUntilDate <= Date() {
            releaseEverything(cause: quickExpireAt != nil ? .quickExpired : .timeReached); return
        }
        if ruleFrontmostOn, let want = ruleFrontmostBundleID {
            let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontID != want && frontID != Bundle.main.bundleIdentifier {
                // red-team: also treat *Trove* as a transient frontmost so
                // editing the rule itself doesn't fire the release. Only flip
                // off when the user moves to a *third* app.
                // (We deliberately don't release here in that edge case.)
            }
        }
    }

    // ---- internals ----

    private func assertionReason() -> String {
        var bits: [String] = []
        if ruleFrontmostOn  { bits.append("while \(ruleFrontmostName.isEmpty ? "app" : ruleFrontmostName) frontmost") }
        if ruleUntilTimeOn  { bits.append("until \(KeepAwakeFormat.short(ruleUntilDate))") }
        if ruleWhilePluggedOn { bits.append("on AC") }
        if ruleBatteryAboveOn { bits.append("battery > \(Int(ruleBatteryThreshold))%") }
        return bits.isEmpty ? "Trove · Keep Awake" : "Trove · " + bits.joined(separator: ", ")
    }

    private func applyAssertions(reason: String) {
        KeepAwakeAssertion.shared.take(preventSystemSleep: preventSystemSleep, reason: reason)
        displayName = reason
    }

    /// Wire up power watcher + frontmost-app observer + time timer, based on
    /// which rules are *currently* active. Idempotent: safe to call any time
    /// rules change, including mid-session after the user flips a rule.
    /// Each observer is paired with explicit teardown in `releaseEverything`
    /// to avoid retain-cycle / token leaks.
    ///
    /// red-team #4 (power poll gating): `IOPSCopyPowerSourcesInfo` is cheap
    /// but not free. We only spin up the 30s timer if a power-dependent rule
    /// (whilePluggedIn / batteryAbove) is active. View-level `onAppear` also
    /// starts the watcher for the live status chips; both consumers ref-
    /// count through `KeepAwakePowerWatcher.subscribers`.
    private func refreshObserversForActiveRules() {
        let needsPower = ruleWhilePluggedOn || ruleBatteryAboveOn

        if needsPower {
            if !powerWatcherActive {
                power.start()
                powerWatcherActive = true
            }
            if powerCancellable == nil {
                powerCancellable = power.objectWillChange.sink { [weak self] _ in
                    // objectWillChange fires BEFORE @Published mutates; hop to
                    // main so the snapshot we read is the post-update one.
                    DispatchQueue.main.async { self?.evaluateRulesNow() }
                }
            }
        } else {
            if powerWatcherActive {
                power.stop()
                powerWatcherActive = false
            }
            powerCancellable?.cancel()
            powerCancellable = nil
        }

        // ---- frontmost-app observer ----
        if ruleFrontmostOn, let want = ruleFrontmostBundleID {
            if frontmostObserver == nil {
                // red-team #2: store the token; remove in releaseEverything.
                // Don't capture self strongly — token outlives a quick toggle
                // otherwise.
                frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil, queue: .main
                ) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let nowID = app?.bundleIdentifier
                    // Don't release while Trove itself is frontmost — the
                    // user is editing the rule. Only the *target* losing
                    // focus when a *third* app becomes frontmost should fire.
                    if nowID != want && nowID != Bundle.main.bundleIdentifier {
                        // Hop to main-actor explicitly — the observer block
                        // signature is nonisolated even though we asked for
                        // queue: .main. Avoids the Swift 6 actor-isolation
                        // warning on the call below.
                        Task { @MainActor [weak self] in
                            self?.releaseEverything(cause: .appLostFocus)
                        }
                    }
                }
            }
        } else if let tok = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(tok)
            frontmostObserver = nil
        }

        // ---- time-based release timer ----
        if ruleUntilTimeOn {
            installReleaseTimer(at: ruleUntilDate)
        } else {
            releaseTimer?.cancel()
            releaseTimer = nil
        }
    }

    /// red-team #5: DispatchSourceTimer, not Timer.scheduledTimer. The former
    /// is cancellable in O(1) and doesn't retain its target.
    // red-team: clamp the deadline arithmetic. `timeIntervalSinceNow` returns
    // a Double; passing a huge value (user picks a date 50 years out) into
    // `.now() + interval` could overflow DispatchTime's internal uint64 of
    // nanoseconds (max ~584 years), but more practically a NaN/Inf from a
    // corrupted UserDefaults restore would crash the dispatch source. Clamp
    // to a sane 30-day ceiling — anyone wanting longer can re-arm the rule.
    private func installReleaseTimer(at fireDate: Date) {
        releaseTimer?.cancel()
        let raw = fireDate.timeIntervalSinceNow
        let safe: TimeInterval
        if !raw.isFinite { safe = 0 }
        else { safe = max(0, min(raw, 30 * 24 * 3600)) }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + safe)
        t.setEventHandler { [weak self] in
            self?.releaseEverything(cause: self?.quickExpireAt != nil ? .quickExpired : .timeReached)
        }
        releaseTimer = t
        t.resume()
    }

    private func startUptimeTicker() {
        uptimeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let start = KeepAwakeAssertion.shared.startedAt else { return }
            self.displayUptime = KeepAwakeFormat.uptime(since: start)
        }
        uptimeTimer = t
        t.resume()
    }

    /// Single release path. `cause` drives the toast; `silent` suppresses it
    /// when the app itself is terminating (no point flashing a UI string the
    /// user will never see). Every code path that disables Keep Awake (user
    /// toggle, rule-based release, app-quit) flows through here so observer
    /// teardown is centralized — red-team #2.
    private func releaseEverything(cause: KeepAwakeReleaseCause, silent: Bool = false) {
        KeepAwakeAssertion.shared.releaseAll()
        if let tok = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(tok)
            frontmostObserver = nil
        }
        releaseTimer?.cancel(); releaseTimer = nil
        uptimeTimer?.cancel();  uptimeTimer  = nil
        // Balance our outstanding power.start() with a matching stop() so
        // the watcher's internal subscriber count doesn't drift. The View's
        // onAppear keeps it running for the live status chips independently.
        if powerWatcherActive {
            power.stop()
            powerWatcherActive = false
        }
        powerCancellable?.cancel()
        powerCancellable = nil
        masterOn = false
        displayName = ""
        displayUptime = ""
        quickExpireAt = nil
        if !silent {
            flash("Keep Awake off — \(cause.rawValue)")
        }
        syncMenuBar()
    }

    /// Build a short summary of the live rules — used in the master flash so
    /// the user sees "Keep Awake on — while Xcode frontmost, on AC".
    /// red-team #6: precedence is documented as "first matching rule wins";
    /// the summary is purely informational.
    private func activeRulesSummary() -> String {
        var bits: [String] = []
        if ruleFrontmostOn  { bits.append("while \(ruleFrontmostName.isEmpty ? "app" : ruleFrontmostName) frontmost") }
        if ruleUntilTimeOn  { bits.append("until \(KeepAwakeFormat.short(ruleUntilDate))") }
        if ruleWhilePluggedOn { bits.append("on AC") }
        if ruleBatteryAboveOn { bits.append("battery > \(Int(ruleBatteryThreshold))%") }
        return bits.isEmpty ? "no rules — indefinite" : bits.joined(separator: ", ")
    }

    /// Toast via the shared Stage. We try-call SharedStore.stage.flash if it's
    /// reachable; this file lives alongside main.swift in the same target so
    /// the symbol resolves at compile time.
    private func flash(_ msg: String) {
        SharedStore.stage.flash(msg)
    }

    // ---- menu bar ----

    private func syncMenuBar() {
        if showInMenuBar {
            if statusItem == nil {
                let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let btn = s.button {
                    btn.target = self
                    btn.action = #selector(menuBarClicked(_:))
                }
                statusItem = s
            }
            updateMenuBarIcon()
        } else {
            if let s = statusItem {
                NSStatusBar.system.removeStatusItem(s)
                statusItem = nil
            }
        }
    }

    private func updateMenuBarIcon() {
        guard let btn = statusItem?.button else { return }
        let name = masterOn ? "sun.max.fill" : "moon.fill"
        btn.image = NSImage(systemSymbolName: name, accessibilityDescription: "Keep Awake")
        btn.toolTip = masterOn
            ? "Keep Awake — on (\(displayName.isEmpty ? "indefinite" : displayName))"
            : "Keep Awake — off"
    }

    @objc private func menuBarClicked(_ sender: Any?) {
        toggleMaster(!masterOn)
    }
}

// ===========================================================================
// MARK: - Formatting helpers
// ===========================================================================

enum KeepAwakeFormat {
    static func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        if !Calendar.current.isDateInToday(d) {
            f.dateStyle = .short
        }
        return f.string(from: d)
    }

    static func uptime(since: Date) -> String {
        let secs = Int(Date().timeIntervalSince(since))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct KeepAwakeView: View {
    @ObservedObject private var coord = KeepAwakeCoordinator.shared
    @ObservedObject private var power = KeepAwakeCoordinator.shared.powerWatcher
    @State private var runningApps: [NSRunningApplication] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                masterCard
                if coord.masterOn { statusCard }
                quickCard
                rulesCard
                footerCard
            }
            .padding(24)
        }
        .navigationTitle("Keep Awake")
        .navigationSubtitle(coord.masterOn
            ? "Awake — \(coord.displayUptime.isEmpty ? "just now" : coord.displayUptime)"
            : "Display & system sleep allowed")
        .onAppear {
            coord.powerWatcher.start()
            refreshRunningApps()
        }
        .onDisappear {
            coord.powerWatcher.stop()
        }
    }

    // ---- subviews ----

    private var masterCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: coord.masterOn ? "sun.max.fill" : "moon.fill")
                    .font(.title)
                    .foregroundStyle(coord.masterOn ? .yellow : .secondary)
                    // red-team: don't let the decorative sun/moon glyph eat
                    // VoiceOver focus — the Toggle below already announces
                    // the live state. Without this VO reads the icon, the
                    // toggle, *and* the explanation as three separate items.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { coord.masterOn },
                        set: { coord.toggleMaster($0) }
                    )) {
                        Text("Keep Mac awake").font(.headline)
                    }
                    .toggleStyle(.switch)
                    .accessibilityHint(coord.masterOn
                        ? "Currently preventing display sleep. Activate to release the assertion."
                        : "Currently allowing sleep. Activate to hold a Keep Awake assertion.")
                    Text("Holds an IOPMAssertion that prevents the display from idle-sleeping. Lid-close on a MacBook still puts the Mac to sleep — that's an OS-level safety we don't override.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: Binding(
                        get: { coord.preventSystemSleep },
                        set: { coord.toggleSystemSleep($0) }
                    )) {
                        Text("Also prevent system sleep")
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)
                }
                Spacer()
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                    Text("Holding assertion").font(.headline)
                    Spacer()
                    Text(coord.displayUptime)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(coord.displayName.isEmpty ? "Trove · Keep Awake" : coord.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    KeepAwakeChip(
                        label: "Display sleep",
                        value: "blocked",
                        color: .green)
                    KeepAwakeChip(
                        label: "System sleep",
                        value: coord.preventSystemSleep ? "blocked" : "allowed",
                        color: coord.preventSystemSleep ? .green : .gray)
                    KeepAwakeChip(
                        label: "Power",
                        value: power.snapshot.onAC ? "AC" : "Battery",
                        color: power.snapshot.onAC ? .blue : .orange)
                    if let p = power.snapshot.batteryPercent {
                        KeepAwakeChip(label: "Battery", value: "\(p)%", color: .gray)
                    }
                }
            }
        }
    }

    private var quickCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Caffeinate now").font(.headline)
                HStack(spacing: 10) {
                    Button("1 hour")          { coord.quickCaffeinate(1) }
                    Button("4 hours")         { coord.quickCaffeinate(4) }
                    // red-team: "Until quit" and "Indefinite" were two
                    // labels for the same `quickCaffeinate(nil)` action —
                    // confusing duplicate-by-accident. Collapse to a single
                    // "Until quit" button; the per-axis rules card already
                    // covers the rest. (Behaviour preserved: nil hours = no
                    // time release.) Flagged separately in the report.
                    Button("Until quit")      { coord.quickCaffeinate(nil) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if coord.masterOn {
                        Button(role: .destructive, action: { coord.toggleMaster(false) }) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("⌘. — stop Keep Awake")
                    }
                }
            }
        }
    }

    private var rulesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Conditional rules").font(.headline)
                    Spacer()
                    Text("First trigger wins").font(.caption).foregroundStyle(.secondary)
                }

                // 1) Frontmost app
                ruleRow(
                    on: Binding(
                        get: { coord.ruleFrontmostOn },
                        set: { coord.ruleFrontmostOn = $0; coord.evaluateRulesNow() }),
                    icon: KeepAwakeTrigger.frontmostApp.systemImage,
                    title: "While app is frontmost",
                    detail: "Release the assertion the moment a different app becomes frontmost."
                ) {
                    Menu(coord.ruleFrontmostName.isEmpty ? "Pick app…" : coord.ruleFrontmostName) {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "Unknown") {
                                coord.ruleFrontmostBundleID = app.bundleIdentifier
                                coord.ruleFrontmostName = app.localizedName ?? "Unknown"
                            }
                        }
                        Divider()
                        Button("Refresh running apps") { refreshRunningApps() }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 220)
                }

                // 2) Until time
                ruleRow(
                    on: Binding(
                        get: { coord.ruleUntilTimeOn },
                        set: { coord.ruleUntilTimeOn = $0; coord.evaluateRulesNow() }),
                    icon: KeepAwakeTrigger.untilTime.systemImage,
                    title: "Until time",
                    detail: "Auto-release at this wall-clock moment."
                ) {
                    DatePicker("", selection: Binding(
                        get: { coord.ruleUntilDate },
                        set: { coord.ruleUntilDate = $0 }
                    ), displayedComponents: [.hourAndMinute, .date])
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                // 3) While plugged in
                ruleRow(
                    on: Binding(
                        get: { coord.ruleWhilePluggedOn },
                        set: { coord.ruleWhilePluggedOn = $0; coord.evaluateRulesNow() }),
                    icon: KeepAwakeTrigger.whilePluggedIn.systemImage,
                    title: "While plugged in (AC power)",
                    detail: "Release immediately on switch to battery; safe for laptops in transit."
                ) {
                    Text(power.snapshot.onAC ? "Currently on AC" : "Currently on battery")
                        .font(.caption)
                        .foregroundStyle(power.snapshot.onAC ? .green : .orange)
                }

                // 4) Battery above N
                ruleRow(
                    on: Binding(
                        get: { coord.ruleBatteryAboveOn },
                        set: { coord.ruleBatteryAboveOn = $0; coord.evaluateRulesNow() }),
                    icon: KeepAwakeTrigger.batteryAbove.systemImage,
                    title: "Until battery drops below \(Int(coord.ruleBatteryThreshold))%",
                    detail: "Release when battery falls below the threshold."
                ) {
                    Slider(value: Binding(
                        get: { coord.ruleBatteryThreshold },
                        set: { coord.ruleBatteryThreshold = $0 }
                    ), in: 10...95, step: 5)
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var footerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { coord.showInMenuBar },
                    set: { coord.toggleMenuBar($0) }
                )) {
                    Label("Show in menu bar", systemImage: "menubar.rectangle")
                }
                .toggleStyle(.switch)
                Text("Adds a sun/moon status item that toggles Keep Awake. Disabled by default to keep the menu bar uncluttered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                Text("• `kIOPMAssertionTypePreventUserIdleDisplaySleep` blocks idle sleep, not lid-close sleep. To keep a closed-lid MacBook awake you also need an external display attached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• If another app (e.g. system caffeinate) already holds an assertion, ours stacks on top; releasing ours doesn't release theirs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• Trove releases all of its assertions on Quit and on clean exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // ---- row helper ----

    @ViewBuilder
    private func ruleRow<Trailing: View>(
        on: Binding<Bool>,
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden()
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// ===========================================================================
// MARK: - Small reusable chip
// ===========================================================================

struct KeepAwakeChip: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
        )
    }
}
