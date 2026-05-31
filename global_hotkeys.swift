// Trove — Global hotkeys (Carbon) with user-configurable bindings.
//
// Ships one app-wide shortcut by default:
//   ⌘⌥⇧T  →  capture full screen, write a PNG, add to Stage.
//
// Users can rebind it (or disable it entirely) from the Customize pane.
// Settings persist to UserDefaults.
//
// Carbon `RegisterEventHotKey` is the right mechanism here:
//   • No Accessibility permission needed (unlike CGEventTap).
//   • Fires on the main run-loop.
//   • Coexists with the AltTab pane's own hotkey (distinct EventHotKeyID).

import SwiftUI
import AppKit
import Carbon
import Foundation
import CoreGraphics  // for CGPreflightScreenCaptureAccess (post-hotkey TCC probe)

// ===========================================================================
// MARK: - Binding model
// ===========================================================================

/// A keyboard binding expressed as Carbon-API constants (cmdKey | shiftKey
/// etc. for modifiers, kVK_* for the key code).
struct HotkeyBinding: Equatable, Hashable, Codable {
    var modifiers: UInt32   // bitmask of cmdKey | optionKey | controlKey | shiftKey
    var keyCode: UInt32     // virtual keycode (kVK_*)

    enum CodingKeys: String, CodingKey { case modifiers, keyCode }

    init(modifiers: UInt32, keyCode: UInt32) {
        self.modifiers = modifiers; self.keyCode = keyCode
    }

    /// P1 fix: tolerant decoder. Stored as JSON in UserDefaults under
    /// `trove.windowSnap.bindings` (a `[String: HotkeyBinding]` map) and
    /// `hotkey.fullScreenToStage.binding` (a single binding). Adding a future
    /// field — e.g. `isEnabled` for per-direction disables — would otherwise
    /// silently reset every per-direction snap binding to the hardcoded default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.modifiers = (try? c.decodeIfPresent(UInt32.self, forKey: .modifiers)) ?? 0
        self.keyCode   = (try? c.decodeIfPresent(UInt32.self, forKey: .keyCode))   ?? 0
    }

    /// ⌘⌥⇧T — triple-modifier default avoids collisions with macOS Screenshot
    /// (⌘⇧2/3/4/5) and other common system shortcuts.
    /// Power-user item #8 — default global stop-recording chord.
    /// ⌘⇧. (period) — same chord as the in-app HUD's secondary stop,
    /// works globally even when Trove isn't frontmost.
    static let cmdShiftPeriod = HotkeyBinding(
        modifiers: UInt32(cmdKey | shiftKey),
        keyCode: UInt32(kVK_ANSI_Period))

    static let cmdOptShiftT = HotkeyBinding(
        modifiers: UInt32(cmdKey | optionKey | shiftKey),
        keyCode: UInt32(kVK_ANSI_T)
    )
    // Legacy name kept so existing UserDefaults round-trips still compile.
    @available(*, deprecated, renamed: "cmdOptShiftT")
    static let cmdShift2 = HotkeyBinding(
        modifiers: UInt32(cmdKey | shiftKey),
        keyCode: UInt32(kVK_ANSI_2)
    )

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    static func keyName(_ kc: UInt32) -> String {
        switch Int(kc) {
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_Tab:    return "Tab"
        case kVK_Space:  return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow:   return "↑"; case kVK_DownArrow:  return "↓"
        default: return "Key(\(kc))"
        }
    }
}

// ===========================================================================
// MARK: - Persisted settings
// ===========================================================================

@MainActor
final class HotkeySettings: ObservableObject {
    static let shared = HotkeySettings()

    @Published var fullScreenToStageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fullScreenToStageEnabled, forKey: Self.keyEnabled)
            TroveGlobalHotkeys.shared.rebind()
        }
    }
    @Published var fullScreenToStageBinding: HotkeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(fullScreenToStageBinding) {
                UserDefaults.standard.set(data, forKey: Self.keyBinding)
            }
            TroveGlobalHotkeys.shared.rebind()
        }
    }

    private static let keyEnabled = "hotkey.fullScreenToStage.enabled"
    private static let keyBinding = "hotkey.fullScreenToStage.binding"

    // Power-user item #8 — global stop-recording hotkey.
    @Published var recordingStopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(recordingStopEnabled,
                                       forKey: Self.kRecordingStopEnabled)
            TroveGlobalHotkeys.shared.rebind()
        }
    }
    @Published var recordingStopBinding: HotkeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(recordingStopBinding) {
                UserDefaults.standard.set(data, forKey: Self.kRecordingStopBinding)
            }
            TroveGlobalHotkeys.shared.rebind()
        }
    }
    private static let kRecordingStopEnabled = "hotkey.recordingStop.enabled"
    private static let kRecordingStopBinding = "hotkey.recordingStop.binding"

    private init() {
        let defaults = UserDefaults.standard
        // Fix 15: default to false on first launch — don't activate a global hotkey without consent.
        if defaults.object(forKey: Self.keyEnabled) == nil {
            self.fullScreenToStageEnabled = false
        } else {
            self.fullScreenToStageEnabled = defaults.bool(forKey: Self.keyEnabled)
        }
        // red-team-sec #3: don't trust the persisted blob blindly. A
        // misbehaving other process can't write our defaults (per-user
        // sandbox), but Migration Assistant / synced Defaults / a corrupted
        // plist can all produce nonsense. Validate ranges and fall back to
        // the default rather than handing Carbon a bad keycode/modifier.
        if let data = defaults.data(forKey: Self.keyBinding),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
           Self.isValid(binding: decoded) {
            self.fullScreenToStageBinding = decoded
        } else {
            self.fullScreenToStageBinding = .cmdOptShiftT
        }
        // Power-user item #8 — global stop-recording hotkey. Default off
        // (consent-first) but the binding default is ⌘⇧. so the user can
        // flip on with one tap.
        self.recordingStopEnabled = defaults.bool(forKey: Self.kRecordingStopEnabled)
        if let data = defaults.data(forKey: Self.kRecordingStopBinding),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
           Self.isValid(binding: decoded) {
            self.recordingStopBinding = decoded
        } else {
            self.recordingStopBinding = .cmdShiftPeriod
        }
    }

    /// Reject obviously-bogus persisted bindings.
    private static func isValid(binding: HotkeyBinding) -> Bool {
        // keyCode is a 16-bit virtual keycode. Valid kVK_* range is 0..0x7F
        // for ANSI/standard keys; numpad and special keys can go higher but
        // anything > 0xFF is definitely garbage.
        if binding.keyCode > 0xFF { return false }
        // Modifier mask must be a subset of the four Carbon mod bits we
        // actually support — anything else means corruption or a tampered
        // plist with extra bits set.
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        if binding.modifiers & ~allowed != 0 { return false }
        // Require at least one modifier — a bare keycode would shadow normal
        // typing.
        if binding.modifiers == 0 { return false }
        return true
    }
}

// ===========================================================================
// MARK: - Global hotkey controller (Carbon)
// ===========================================================================

@MainActor
final class TroveGlobalHotkeys: ObservableObject {
    static let shared = TroveGlobalHotkeys()

    @Published var lastRegisterError: String?
    // Fix #8: directions whose Carbon hotkey registration failed due to conflict.
    @Published var snapConflicts: [SnapDirection] = []

    private var installedHandler: EventHandlerRef?
    private var fullScreenHotkey: EventHotKeyRef?
    private var snapHotkeys: [SnapDirection: EventHotKeyRef] = [:]
    private let signature: OSType = 0x54524F56     // "TROV"
    private let idFullScreenToStage: UInt32 = 1
    private let idRecordingStop: UInt32 = 200    // Power-user item #8
    private var recordingStopHotkey: EventHotKeyRef?

    private init() {}

    /// Install the keyboard event handler and register hotkeys per current
    /// settings. Idempotent — calling multiple times is safe.
    func install() {
        installHandlerIfNeeded()
        rebind()
    }

    /// Called by HotkeySettings whenever the user changes the binding or
    /// enable flag. Re-registers Carbon hotkeys to match current settings.
    func rebind() {
        installHandlerIfNeeded()

        // red-team #2: order matters — null the cached ref BEFORE calling
        // Unregister, so a re-entrant rebind() (triggered from a `didSet`
        // observer firing during the unregister) can't see a dangling ref
        // and try to unregister it a second time.
        if let h = fullScreenHotkey {
            fullScreenHotkey = nil
            UnregisterEventHotKey(h)
        }

        // Unregister all snap hotkeys before re-registering.
        for (dir, h) in snapHotkeys {
            snapHotkeys[dir] = nil
            UnregisterEventHotKey(h)
        }
        snapHotkeys.removeAll()
        // Power-user item #8 — global stop-recording hotkey.
        if let h = recordingStopHotkey {
            recordingStopHotkey = nil
            UnregisterEventHotKey(h)
        }

        let settings = HotkeySettings.shared
        if settings.fullScreenToStageEnabled {
            let id = EventHotKeyID(signature: signature, id: idFullScreenToStage)
            var ref: EventHotKeyRef?
            let regStatus = RegisterEventHotKey(
                settings.fullScreenToStageBinding.keyCode,
                settings.fullScreenToStageBinding.modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if regStatus == noErr {
                fullScreenHotkey = ref
                lastRegisterError = nil
            } else {
                lastRegisterError = Self.describe(regStatus: regStatus)
            }
        } else {
            lastRegisterError = nil
        }

        // Power-user item #8 — global stop-recording hotkey.
        // Default: ⌘⇧. (period). User-configurable in Settings.
        if HotkeySettings.shared.recordingStopEnabled {
            let binding = HotkeySettings.shared.recordingStopBinding
            let id = EventHotKeyID(signature: signature, id: idRecordingStop)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, id,
                GetApplicationEventTarget(), 0, &ref)
            if st == noErr {
                recordingStopHotkey = ref
            }
        }

        // Register window-snap hotkeys if enabled.
        guard WindowSnapSettings.shared.enabled else {
            snapConflicts = []
            return
        }
        var conflicts: [SnapDirection] = []
        for dir in SnapDirection.allCases {
            // Use per-direction custom binding if present, else the built-in default.
            let binding = WindowSnapSettings.shared.binding(for: dir)
            let hkID = EventHotKeyID(signature: signature, id: dir.rawValue)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, hkID,
                GetApplicationEventTarget(), 0, &ref
            )
            if st == noErr, let ref = ref {
                snapHotkeys[dir] = ref
            } else if st == -9874 {
                // eventHotKeyExistsErr — collect for UI surfacing.
                conflicts.append(dir)
            }
        }
        snapConflicts = conflicts
    }

    /// red-team #4: humanise the Carbon OSStatus values RegisterEventHotKey
    /// commonly returns. Anything we don't recognise falls back to the raw
    /// code so the user still has something to search for.
    private static func describe(regStatus: OSStatus) -> String {
        switch regStatus {
        case -9874:
            // eventHotKeyExistsErr — most common case (another app or our
            // own previous registration owns this combo).
            return "That shortcut is already registered (by Trove or another app). Pick a different one."
        case -9868:
            // eventHotKeyInvalidErr
            return "That key combination isn't a valid hotkey. Pick a different one."
        case OSStatus(paramErr):
            return "Hotkey parameters were rejected by the OS. Pick a different one."
        case OSStatus(memFullErr):
            return "Out of memory installing the hotkey. Restart Trove."
        default:
            return "That shortcut couldn't be registered — try a different combination."
        }
    }

    // (lastRegisterError declared above with @Published — keep single source)

    // -----------------------------------------------------------------
    // MARK: Internals
    // -----------------------------------------------------------------

    private func installHandlerIfNeeded() {
        guard installedHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else {
                    return OSStatus(eventNotHandledErr)
                }
                let me = Unmanaged<TroveGlobalHotkeys>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var hkID = EventHotKeyID()
                let gp = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                guard gp == noErr else { return OSStatus(eventNotHandledErr) }
                if Thread.isMainThread {
                    me.dispatch(id: hkID.id)
                } else {
                    DispatchQueue.main.async { me.dispatch(id: hkID.id) }
                }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
        if status == noErr {
            installedHandler = handlerRef
        } else {
            // Surface InstallEventHandler failure — this is recoverable (e.g. the
            // event target temporarily unavailable) so we use @Published rather
            // than a crash. The settings card displays this as an orange banner.
            lastRegisterError = "Carbon event handler failed to install (OS error \(status)). " +
                                "Global hotkeys are inactive — try restarting Trove."
        }
    }

    private func dispatch(id: UInt32) {
        switch id {
        case idFullScreenToStage:
            captureFullScreenToStage()
        case idRecordingStop:
            // Power-user item #8 — global stop. Posts a notification the
            // Recorder pane listens for, so the same code path that the
            // HUD Stop button hits runs (including sendToStageOnStop /
            // preview sheet hooks).
            NotificationCenter.default.post(name: .troveStopRecordingNow, object: nil)
        default:
            if let dir = SnapDirection(rawValue: id) {
                WindowSnapper.snapFrontmost(to: dir)
            }
        }
    }

    /// Run `screencapture -x` silently, write to a temp PNG, load via NSImage,
    /// add to Stage. Off the main thread so a slow disk doesn't block input.
    private func captureFullScreenToStage() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trove-hk-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/sbin/screencapture"
            p.arguments = ["-x", "-t", "png", url.path]
            // red-team-sec: pin a literal absolute path so a hostile PATH
            // entry can't substitute a Trojan `screencapture`. `launchPath`
            // bypasses PATH on its own; null env removes any environment-
            // mediated injection vector and keeps screencapture's output
            // deterministic.
            p.environment = [:]
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    SharedStore.stage.flash("Screenshot hotkey failed: \(error.localizedDescription)")
                }
                return
            }
            p.waitUntilExitOffMain()
            // red-team: previously a non-zero terminationStatus (e.g. user
            // pressed Esc on the OS confirmation, or Screen Recording
            // permission revoked mid-session) was treated as success and we'd
            // try to load whatever 0-byte stub screencapture left behind,
            // flashing "produced no file" only via the NSImage failure path.
            // Inspect the status explicitly so the message matches the cause.
            if p.terminationStatus != 0 {
                DispatchQueue.main.async {
                    SharedStore.stage.flash(
                        "Screen Recording permission may be off",
                        kind: .warning,
                        actionLabel: "Open Settings") {
                        TCCDeepLink.screenRecording.open()
                    }
                }
                try? FileManager.default.removeItem(at: url)
                return
            }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: url.path),
                      let img = NSImage(contentsOf: url) else {
                    // red-team: 0-exit but no file is the same symptom Screen
                    // Recording denial produces (the OS just refuses to write
                    // the image rather than returning non-zero). Probe and
                    // surface the deep-link toast so the user has a fix.
                    if !CGPreflightScreenCaptureAccess() {
                        SharedStore.stage.flash(
                            "Screen Recording permission required",
                            kind: .warning,
                            actionLabel: "Open Settings") {
                            TCCDeepLink.screenRecording.open()
                        }
                    } else {
                        SharedStore.stage.flash("Screenshot hotkey produced no file")
                    }
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                SharedStore.stage.addImage(img)
                SharedStore.stage.flash("\(HotkeySettings.shared.fullScreenToStageBinding.displayString) → screen captured to Stage")
                // red-team: Stage now holds the image (NSImage holds onto its
                // backing data via the URL/CGImage source). The on-disk PNG
                // is no longer needed and accumulates in /tmp across sessions
                // since macOS only sweeps /tmp on reboot. Delete after a brief
                // delay so anything else reading the URL has a chance to
                // finish (Stage thumbnail decode, etc.).
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Window Snap directions + settings
// ===========================================================================

/// Rectangle-compatible snap targets. Each maps to a unique Carbon hotkey ID.
enum SnapDirection: UInt32, CaseIterable {
    case leftHalf          = 10
    case rightHalf         = 11
    case topHalf           = 12
    case bottomHalf        = 13
    case topLeftQuarter    = 14
    case topRightQuarter   = 15
    case bottomLeftQuarter = 16
    case bottomRightQuarter = 17
    case maximize          = 18
    case center            = 19

    /// Default Rectangle-style binding for each direction.
    var defaultBinding: HotkeyBinding {
        let ctrlOpt = UInt32(controlKey | optionKey)
        switch self {
        case .leftHalf:           return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_LeftArrow))
        case .rightHalf:          return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_RightArrow))
        case .topHalf:            return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_UpArrow))
        case .bottomHalf:         return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_DownArrow))
        case .topLeftQuarter:     return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_U))
        case .topRightQuarter:    return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_I))
        case .bottomLeftQuarter:  return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_J))
        case .bottomRightQuarter: return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_K))
        case .maximize:           return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_F))
        case .center:             return HotkeyBinding(modifiers: ctrlOpt, keyCode: UInt32(kVK_ANSI_C))
        }
    }

    var label: String {
        switch self {
        case .leftHalf:           return "Left half"
        case .rightHalf:          return "Right half"
        case .topHalf:            return "Top half"
        case .bottomHalf:         return "Bottom half"
        case .topLeftQuarter:     return "Top-left quarter"
        case .topRightQuarter:    return "Top-right quarter"
        case .bottomLeftQuarter:  return "Bottom-left quarter"
        case .bottomRightQuarter: return "Bottom-right quarter"
        case .maximize:           return "Maximize"
        case .center:             return "Center"
        }
    }
}

@MainActor
final class WindowSnapSettings: ObservableObject {
    static let shared = WindowSnapSettings()

    private static let enabledKey  = "trove.windowSnap.enabled"
    private static let bindingsKey = "trove.windowSnap.bindings"  // JSON [String:HotkeyBinding]

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            TroveGlobalHotkeys.shared.rebind()
        }
    }

    /// Per-direction custom bindings. Falls back to `dir.defaultBinding` for any missing key.
    @Published var customBindings: [SnapDirection: HotkeyBinding] = [:] {
        didSet {
            // Persist as JSON dict [rawValue: HotkeyBinding].
            let raw: [String: HotkeyBinding] = Dictionary(uniqueKeysWithValues:
                customBindings.map { (String($0.key.rawValue), $0.value) })
            if let data = try? JSONEncoder().encode(raw) {
                UserDefaults.standard.set(data, forKey: Self.bindingsKey)
            }
            TroveGlobalHotkeys.shared.rebind()
        }
    }

    /// Resolved binding for a direction (custom override or default).
    func binding(for dir: SnapDirection) -> HotkeyBinding {
        customBindings[dir] ?? dir.defaultBinding
    }

    private init() {
        let ud = UserDefaults.standard
        if ud.object(forKey: Self.enabledKey) == nil {
            self.enabled = false
        } else {
            self.enabled = ud.bool(forKey: Self.enabledKey)
        }
        // Restore persisted per-direction bindings.
        if let data = ud.data(forKey: Self.bindingsKey),
           let raw = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            var map: [SnapDirection: HotkeyBinding] = [:]
            for (k, v) in raw {
                if let rv = UInt32(k), let dir = SnapDirection(rawValue: rv),
                   Self.isValidBinding(v) {
                    map[dir] = v
                }
            }
            self.customBindings = map
        }
    }

    private static func isValidBinding(_ b: HotkeyBinding) -> Bool {
        guard b.keyCode <= 0xFF else { return false }
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard b.modifiers & ~allowed == 0, b.modifiers != 0 else { return false }
        return true
    }
}

// ===========================================================================
// MARK: - Settings UI
// ===========================================================================

/// A row that lets the user toggle + rebind a single hotkey. Lives in the
/// Customize pane. The "Record" button captures the next ⌘/⌥/⌃/⇧+ key.
struct HotkeySettingsCard: View {
    @ObservedObject private var settings = HotkeySettings.shared
    @ObservedObject private var controller = TroveGlobalHotkeys.shared
    @State private var recording = false
    @State private var recordedEvent: NSEvent?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(.tint)
                    Text("Global hotkeys").headerText()
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(isOn: $settings.fullScreenToStageEnabled) {
                            Text("Capture full screen → Stage").font(.body.weight(.medium))
                        }
                        Spacer()
                        Button {
                            recording.toggle()
                        } label: {
                            Text(recording
                                 ? "Press keys…"
                                 : settings.fullScreenToStageBinding.displayString)
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 80)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(recording ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!settings.fullScreenToStageEnabled)
                        .help("Click then press the shortcut you want (modifiers + key)")
                    }
                    Text("Works from any app while Trove is running. Default ⌘⌥⇧T.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let err = controller.lastRegisterError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .background(HotkeyRecorderHost(active: $recording) { event in
            // Translate the recorded NSEvent into Carbon modifiers + keycode.
            let mods = carbonModifierMask(from: event.modifierFlags)
            // Require at least one modifier so we don't accidentally bind a
            // bare letter that would block typing.
            guard mods != 0 else { return }
            // red-team: refuse to bind exactly ⇧+key (with no other modifier).
            // Shift alone is what users hold for capital letters — binding
            // `⇧A` would silently swallow every capital A typed anywhere in
            // any app while Trove is running. Require at least one of
            // Cmd/Opt/Ctrl so the chord is unambiguously "a hotkey".
            let nonShift = mods & ~UInt32(shiftKey)
            guard nonShift != 0 else { return }
            settings.fullScreenToStageBinding = HotkeyBinding(
                modifiers: mods,
                keyCode: UInt32(event.keyCode)
            )
            recording = false
        })
    }

    private func carbonModifierMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command)  { m |= UInt32(cmdKey) }
        if flags.contains(.option)   { m |= UInt32(optionKey) }
        if flags.contains(.control)  { m |= UInt32(controlKey) }
        if flags.contains(.shift)    { m |= UInt32(shiftKey) }
        return m
    }
}

/// Invisible NSView that, while `active` is true, installs a local key
/// monitor and forwards the next key-down to `onCapture`. Removed when the
/// view goes away or `active` flips to false. Used by `HotkeySettingsCard`.
private struct HotkeyRecorderHost: NSViewRepresentable {
    @Binding var active: Bool
    let onCapture: (NSEvent) -> Void

    final class Coord {
        var monitor: Any?
        var onCapture: ((NSEvent) -> Void)?
    }

    func makeCoordinator() -> Coord {
        let c = Coord()
        c.onCapture = onCapture
        return c
    }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.onCapture = onCapture
        if active && c.monitor == nil {
            // red-team-sec #5: while recording, this closure fires for EVERY
            // keystroke routed to our app (it's a LOCAL monitor, not a
            // global one — keystrokes from OTHER apps never reach us). We
            // pass the NSEvent only to the binding-capture callback and DO
            // NOT log, persist, or transmit it. The callback only reads
            // keyCode + modifierFlags; the typed character is never
            // dereferenced. Verify when modifying.
            c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                // red-team: Escape cancels recording without binding anything.
                // Previously pressing Esc with no modifiers was discarded
                // silently by the capture callback's "require modifier" guard,
                // but the recorder was still active — the user had to click
                // the button again to exit. Treat Escape as an explicit
                // cancel and tear down the monitor here so the UI returns to
                // its idle state immediately.
                if ev.keyCode == UInt16(kVK_Escape) && ev.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    if let m = c.monitor {
                        NSEvent.removeMonitor(m)
                        c.monitor = nil
                    }
                    DispatchQueue.main.async { active = false }
                    return nil
                }
                c.onCapture?(ev)
                // Swallow the event so it doesn't reach a focused field.
                return nil
            }
        } else if !active, let m = c.monitor {
            // red-team #1: clean removal on `recording = false`. SwiftUI
            // re-invokes updateNSView whenever the @Binding flips, so this
            // path runs synchronously and the monitor is gone before the
            // next keystroke arrives.
            NSEvent.removeMonitor(m)
            c.monitor = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coord) {
        // red-team #1: belt-and-suspenders — also remove on view teardown
        // in case `active` was still true when the parent disappeared.
        if let m = coordinator.monitor {
            NSEvent.removeMonitor(m)
            coordinator.monitor = nil
        }
    }
}

// ===========================================================================
// MARK: - Window Snap settings card
// ===========================================================================

/// Settings card that lets users toggle + rebind Rectangle-style global snap hotkeys.
/// Per-row recorder lets each direction be individually rebound; conflicts are surfaced.
struct WindowSnapSettingsCard: View {
    @ObservedObject private var settings = WindowSnapSettings.shared
    @ObservedObject private var hotkeys = TroveGlobalHotkeys.shared
    /// Which direction is currently being recorded (nil = none).
    @State private var recording: SnapDirection? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1").foregroundStyle(.tint)
                    Text("Window Snap").headerText()
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $settings.enabled) {
                        Text("Rectangle-style snap hotkeys").font(.body.weight(.medium))
                    }
                    Text("Registers global shortcuts while Trove is running. Default OFF — enable only if you're not using Rectangle or similar.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Surface hotkey conflicts so users know why a snap doesn't fire.
                if !hotkeys.snapConflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hotkeys.snapConflicts, id: \.rawValue) { dir in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(settings.binding(for: dir).displayString) is already used by another app (\(dir.label) snap inactive).")
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if settings.enabled {
                    // Per-direction rows with individual rebind buttons.
                    VStack(spacing: 2) {
                        ForEach(SnapDirection.allCases, id: \.rawValue) { dir in
                            snapBindingRow(dir)
                            if dir != SnapDirection.allCases.last {
                                Divider().padding(.leading, 4)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        // Single HotkeyRecorderHost shared across all rows; active only when `recording != nil`.
        .background(
            HotkeyRecorderHost(
                active: Binding(
                    get: { recording != nil },
                    set: { if !$0 { recording = nil } }
                )
            ) { event in
                guard let dir = recording else { return }
                let mods = carbonModifierMaskSnap(from: event.modifierFlags)
                let nonShift = mods & ~UInt32(shiftKey)
                guard nonShift != 0 else { return }
                // Conflict detection: refuse if another direction already uses this combo.
                let newBinding = HotkeyBinding(modifiers: mods, keyCode: UInt32(event.keyCode))
                let conflict = SnapDirection.allCases.first { other in
                    other != dir && settings.binding(for: other) == newBinding
                }
                if conflict != nil {
                    // Binding already used — flash a warning but don't apply.
                    Task { @MainActor in
                        SharedStore.stage.flash(
                            "\(newBinding.displayString) is already bound to \(conflict!.label) snap — pick a different key.",
                            kind: .warning
                        )
                    }
                } else {
                    settings.customBindings[dir] = newBinding
                }
                recording = nil
            }
        )
    }

    @ViewBuilder
    private func snapBindingRow(_ dir: SnapDirection) -> some View {
        let isRecording = recording == dir
        let binding = settings.binding(for: dir)
        let conflict = hotkeys.snapConflicts.contains(dir)
        let isCustom = settings.customBindings[dir] != nil
        HStack(spacing: 8) {
            Text(dir.label)
                .font(.caption)
                .frame(minWidth: 140, alignment: .leading)
            Spacer()
            // Rebind button
            Button {
                recording = isRecording ? nil : dir
            } label: {
                Text(isRecording ? "Press keys…" : binding.displayString)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 72)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    // P2: use troveCardFill token.
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isRecording
                                  ? Color.troveAccent.opacity(0.25)
                                  : (conflict ? Color.troveWarning.opacity(0.15) : Color.troveCardFill))
                    )
                    .foregroundStyle(conflict ? Color.troveWarning : .primary)
            }
            .buttonStyle(.plain)
            .help(conflict ? "Conflict — another app uses this chord" : "Click to rebind")
            // Reset to default button (only shown when custom override exists)
            if isCustom {
                Button {
                    settings.customBindings.removeValue(forKey: dir)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default: \(dir.defaultBinding.displayString)")
            }
        }
        .padding(.vertical, 3)
    }

    private func carbonModifierMaskSnap(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}
