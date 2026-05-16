// Trove — Permissions pane.
//
// Surface:
//   • Public `struct PermissionsView: View` with a no-arg init — drop into RootView.
//   • Type prefix `Perms*` everywhere else (PermsCategory, PermsStatus, PermsStore…).
//
// What it does:
//   • One-stop inventory of every macOS TCC (privacy) category — Accessibility,
//     Screen Recording, Mic, Camera, Photos, Files & Folders, Automation, Input
//     Monitoring, Reminders, Calendars, Contacts, Location, Notifications, Network.
//   • Per category: SF Symbol, plain-English explanation, deep-link button to the
//     exact System Settings sub-pane, and a self-check badge ("Granted" / "Not
//     granted" / "Unknown") for the categories whose API exposes a non-prompting
//     status query.
//   • Refresh on appear AND on NSApplication.didBecomeActiveNotification so the
//     pane reflects flips the user made in System Settings without closing the
//     Trove window.
//
// Red-team notes:
//   • PhotoKit:   we use `PHPhotoLibrary.authorizationStatus(for: .readWrite)` —
//     that overload is a query; the no-arg one triggers a prompt on first call.
//   • ScreenCapture: `CGPreflightScreenCaptureAccess()` only (query). The
//     `CGRequestScreenCaptureAccess()` cousin prompts — we never call it.
//   • AVCapture:  `authorizationStatus(for:)` only. `requestAccess` prompts.
//   • EventKit:   `EKEventStore.authorizationStatus(for:)` is a static call, no
//     store init needed — safe to hit on main.
//   • CoreLocation: `authorizationStatus()` class method is deprecated on iOS
//     but still ships on macOS and remains the only non-prompting status query
//     without spinning up a delegate-bound CLLocationManager.
//   • Notifications: getNotificationSettings is async via a completion handler —
//     wrap in withCheckedContinuation and hop back to main for UI.
//   • Files & Folders / Automation / Input Monitoring have no public TCC query
//     API at all — we ship the deep-link without a status badge.

import SwiftUI
import AppKit
import Foundation
import AVFoundation
import EventKit
import Contacts
import CoreLocation
import Photos
import UserNotifications
import ApplicationServices

// ===========================================================================
// MARK: - Status model
// ===========================================================================

enum PermsStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown        // no API to query (Files & Folders, Automation, Input Monitoring)
    case unsupported    // not applicable on this OS / build

    var label: String {
        switch self {
        case .granted:        return "Granted"
        case .denied:         return "Not granted"
        case .notDetermined:  return "Not asked"
        case .restricted:     return "Restricted"
        case .unknown:        return "Unknown"
        case .unsupported:    return "—"
        }
    }

    var color: Color {
        switch self {
        case .granted:        return .green
        case .denied:         return .red
        case .notDetermined:  return .orange
        case .restricted:     return .orange
        case .unknown:        return .secondary
        case .unsupported:    return .secondary
        }
    }

    var icon: String {
        switch self {
        case .granted:        return "checkmark.seal.fill"
        case .denied:         return "xmark.seal.fill"
        case .notDetermined:  return "questionmark.circle.fill"
        case .restricted:     return "exclamationmark.triangle.fill"
        case .unknown:        return "questionmark.circle"
        case .unsupported:    return "minus.circle"
        }
    }
}

// ===========================================================================
// MARK: - Category catalogue
// ===========================================================================

struct PermsCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let explanation: String
    let deepLink: String
    let hasQuery: Bool

    static func == (lhs: PermsCategory, rhs: PermsCategory) -> Bool { lhs.id == rhs.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum PermsCatalogue {
    static let prefBase = "x-apple.systempreferences:com.apple.preference.security?"

    static let all: [PermsCategory] = [
        PermsCategory(
            id: "accessibility",
            name: "Accessibility",
            symbol: "accessibility",
            explanation: "Lets an app control the keyboard, mouse, and other apps via the Accessibility API — global hotkeys, window-management tools, and automation rely on this.",
            deepLink: prefBase + "Privacy_Accessibility",
            hasQuery: true),
        PermsCategory(
            id: "screen",
            name: "Screen Recording",
            symbol: "rectangle.dashed.badge.record",
            explanation: "Read pixels from any window or display — screenshots, screen recorders, and pixel-color pickers need it.",
            deepLink: prefBase + "Privacy_ScreenCapture",
            hasQuery: true),
        PermsCategory(
            id: "mic",
            name: "Microphone",
            symbol: "mic.fill",
            explanation: "Capture audio from any input device. Voice memos, screen recorders with audio, and meeting apps request this.",
            deepLink: prefBase + "Privacy_Microphone",
            hasQuery: true),
        PermsCategory(
            id: "camera",
            name: "Camera",
            symbol: "camera.fill",
            explanation: "Capture video from the built-in or external camera. Video calls and document scanners use this.",
            deepLink: prefBase + "Privacy_Camera",
            hasQuery: true),
        PermsCategory(
            id: "photos",
            name: "Photos",
            symbol: "photo.on.rectangle.angled",
            explanation: "Read and/or write the user's Photos library. Distinct from Files — Photos has its own walled-off store.",
            deepLink: prefBase + "Privacy_Photos",
            hasQuery: true),
        PermsCategory(
            id: "files",
            name: "Files & Folders / Full Disk Access",
            symbol: "folder.fill.badge.gearshape",
            explanation: "Read files outside the app's own container. macOS gates Downloads, Desktop, Documents, iCloud Drive, Time Machine backups and more behind this.",
            deepLink: prefBase + "Privacy_AllFiles",
            hasQuery: false),
        PermsCategory(
            id: "automation",
            name: "Automation",
            symbol: "wand.and.stars",
            explanation: "Send AppleEvents to control other apps. Used by Shortcuts, automation scripts, and AppleScript runners.",
            deepLink: prefBase + "Privacy_Automation",
            hasQuery: false),
        PermsCategory(
            id: "input",
            name: "Input Monitoring",
            symbol: "keyboard",
            explanation: "Observe keystrokes system-wide even while another app is frontmost. Required for text-expanders and global hotkey listeners.",
            deepLink: prefBase + "Privacy_ListenEvent",
            hasQuery: false),
        PermsCategory(
            id: "reminders",
            name: "Reminders",
            symbol: "list.bullet.rectangle.portrait",
            explanation: "Read and write items in the system Reminders database.",
            deepLink: prefBase + "Privacy_Reminders",
            hasQuery: true),
        PermsCategory(
            id: "calendars",
            name: "Calendars",
            symbol: "calendar",
            explanation: "Read and write events in the system Calendar database.",
            deepLink: prefBase + "Privacy_Calendars",
            hasQuery: true),
        PermsCategory(
            id: "contacts",
            name: "Contacts",
            symbol: "person.crop.rectangle.stack",
            explanation: "Read and write entries in the system Contacts database.",
            deepLink: prefBase + "Privacy_Contacts",
            hasQuery: true),
        PermsCategory(
            id: "location",
            name: "Location",
            symbol: "location.fill",
            explanation: "Receive the device's geographic location. Even desktops have approximate location via Wi-Fi triangulation.",
            deepLink: prefBase + "Privacy_LocationServices",
            hasQuery: true),
        PermsCategory(
            id: "notifications",
            name: "Notifications",
            symbol: "bell.badge.fill",
            explanation: "Post user-visible banners, sounds, and badges from the app. The user controls per-app delivery here.",
            deepLink: prefBase + "Privacy_Notifications",
            hasQuery: true),
        PermsCategory(
            id: "network",
            name: "Network",
            symbol: "network",
            explanation: "macOS has no per-app TCC pane for outbound network. Manage via Network Extensions or third-party firewalls (Little Snitch, LuLu).",
            deepLink: prefBase + "Privacy_Advertising", // best available landing inside Privacy
            hasQuery: false),
    ]
}

// ===========================================================================
// MARK: - Store (runs queries, observes app-active flips)
// ===========================================================================

@MainActor
final class PermsStore: ObservableObject {
    @Published var statuses: [String: PermsStatus] = [:]
    @Published var lastRefresh: Date? = nil
    @Published var refreshing: Bool = false

    // red-team #1: `nonisolated(unsafe)` so the deinit (non-isolated by
    // construction on @MainActor classes) can read it to remove. We only
    // *write* this once in init under the main-actor context, so the
    // "unsafe" is fine in practice.
    nonisolated(unsafe) private var becomeActiveObserver: NSObjectProtocol?

    init() {
        // red-team #1: user may flip a permission in System Settings while
        // this pane is open. Re-query on every app-active to keep the UI
        // honest. We MUST remove the observer in deinit (`addObserver`
        // returns a token that NotificationCenter retains until removed —
        // it'd leak both the token and `self` otherwise).
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    deinit {
        // red-team #1: removeObserver(_:) is thread-safe and doesn't touch
        // any @MainActor-isolated state on `self`, so it's safe from a
        // non-isolated deinit. (Nonisolated removal is required because
        // Swift 6 forbids touching MainActor properties from deinit unless
        // the property is itself nonisolated.)
        if let o = becomeActiveObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    var grantedNames: [String] {
        PermsCatalogue.all
            .filter { statuses[$0.id] == .granted }
            .map { $0.name }
    }

    func refreshAll() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }

        // red-team: EventKit / Contacts / Photos status getters are cheap but
        // not strictly guaranteed main-thread-safe — push the whole batch to a
        // detached task and hop back to main only to write the dictionary.
        let snapshot = await Task.detached(priority: .userInitiated) { () -> [String: PermsStatus] in
            await PermsStore.querySnapshot()
        }.value

        statuses = snapshot
        lastRefresh = Date()
    }

    /// Pure query function — no UI side effects, safe to call from a detached task.
    private static func querySnapshot() async -> [String: PermsStatus] {
        var out: [String: PermsStatus] = [:]

        // Accessibility — synchronous, non-prompting.
        out["accessibility"] = AXIsProcessTrusted() ? .granted : .denied

        // Screen Recording — preflight is the query (does not prompt).
        out["screen"] = CGPreflightScreenCaptureAccess() ? .granted : .denied

        // Microphone / Camera — authorizationStatus(for:) never prompts.
        out["mic"] = mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
        out["camera"] = mapAV(AVCaptureDevice.authorizationStatus(for: .video))

        // Photos — the for:.readWrite overload is the query; bare overload prompts.
        out["photos"] = mapPhotos(PHPhotoLibrary.authorizationStatus(for: .readWrite))

        // Reminders / Calendars — static, doesn't init an EKEventStore.
        out["reminders"] = mapEK(EKEventStore.authorizationStatus(for: .reminder))
        out["calendars"] = mapEK(EKEventStore.authorizationStatus(for: .event))

        // Contacts — static.
        out["contacts"] = mapContacts(CNContactStore.authorizationStatus(for: .contacts))

        // Location — class-level authorizationStatus() is the only non-prompting
        // query without binding a CLLocationManager + delegate. Deprecated on iOS,
        // still current on macOS.
        out["location"] = mapLocation(CLLocationManager.authorizationStatus())

        // Notifications — async completion-handler API; bridge to async.
        out["notifications"] = await mapNotifications()

        // No-API categories:
        out["files"] = .unknown
        out["automation"] = .unknown
        out["input"] = .unknown
        out["network"] = .unsupported

        return out
    }

    // ----- mappers -----

    private static func mapAV(_ s: AVAuthorizationStatus) -> PermsStatus {
        switch s {
        case .authorized:      return .granted
        case .denied:          return .denied
        case .notDetermined:   return .notDetermined
        case .restricted:      return .restricted
        @unknown default:      return .unknown
        }
    }

    private static func mapPhotos(_ s: PHAuthorizationStatus) -> PermsStatus {
        switch s {
        case .authorized, .limited: return .granted
        case .denied:               return .denied
        case .notDetermined:        return .notDetermined
        case .restricted:           return .restricted
        @unknown default:           return .unknown
        }
    }

    private static func mapEK(_ s: EKAuthorizationStatus) -> PermsStatus {
        switch s {
        case .authorized, .fullAccess: return .granted
        case .writeOnly:               return .granted
        case .denied:                  return .denied
        case .notDetermined:           return .notDetermined
        case .restricted:              return .restricted
        @unknown default:              return .unknown
        }
    }

    private static func mapContacts(_ s: CNAuthorizationStatus) -> PermsStatus {
        switch s {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .limited:       return .granted
        @unknown default:    return .unknown
        }
    }

    private static func mapLocation(_ s: CLAuthorizationStatus) -> PermsStatus {
        switch s {
        case .authorizedAlways, .authorized: return .granted
        case .authorizedWhenInUse:           return .granted
        case .denied:                        return .denied
        case .notDetermined:                 return .notDetermined
        case .restricted:                    return .restricted
        @unknown default:                    return .unknown
        }
    }

    private static func mapNotifications() async -> PermsStatus {
        let s: UNAuthorizationStatus = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
        switch s {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied:                                return .denied
        case .notDetermined:                         return .notDetermined
        @unknown default:                            return .unknown
        }
    }
}

// ===========================================================================
// MARK: - View
// ===========================================================================

public struct PermissionsView: View {
    @StateObject private var store = PermsStore()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PermsHeaderCard(store: store)

                ForEach(PermsCatalogue.all) { cat in
                    PermsCategoryCard(
                        category: cat,
                        status: store.statuses[cat.id] ?? (cat.hasQuery ? .unknown : .unknown)
                    )
                }

                PermsCaveatCard()
            }
            .padding(24)
        }
        .navigationTitle("Permissions")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.refreshing)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await store.refreshAll()
        }
    }

    private var subtitle: String {
        let granted = store.grantedNames.count
        let total = PermsCatalogue.all.filter { $0.hasQuery }.count
        return "Trove: \(granted) of \(total) queryable permissions granted"
    }
}

// ===========================================================================
// MARK: - Header card (summary)
// ===========================================================================

struct PermsHeaderCard: View {
    @ObservedObject var store: PermsStore

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS Privacy & Security, all in one place").font(.headline)
                    Text("System Settings splits TCC categories across a dozen sub-panes. This view inventories every one, explains what it grants, and deep-links you straight to the right sub-pane.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    summaryLine
                        .font(.callout)
                        .padding(.top, 4)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var summaryLine: some View {
        let names = store.grantedNames
        if store.lastRefresh == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking what Trove has been granted…")
                    .foregroundStyle(.secondary)
            }
        } else if names.isEmpty {
            Label("Trove has not been granted any queryable permissions.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                (Text("Trove currently has: ").foregroundStyle(.secondary)
                 + Text(names.joined(separator: ", ")).fontWeight(.medium))
            }
        }
    }
}

// ===========================================================================
// MARK: - Per-category card
// ===========================================================================

struct PermsCategoryCard: View {
    let category: PermsCategory
    let status: PermsStatus

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.title2)
                    .frame(width: 28, alignment: .center)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(category.name).font(.headline)
                        badge
                    }
                    Text(category.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        // red-team: when the OS reports `.denied`, the user is
                        // actively blocked. Promote the deep-link button to
                        // `.borderedProminent` so it's the obvious next click.
                        // For `.granted` / `.unknown` (no-API) we keep the
                        // softer default style — the link is informational,
                        // not a remediation prompt. We branch on the modifier
                        // (rather than using a type-erased `AnyButtonStyle`,
                        // which doesn't exist in SwiftUI) so each branch
                        // resolves to a concrete `PrimitiveButtonStyle`.
                        if status == .denied {
                            Button {
                                openDeepLink(category.deepLink)
                            } label: {
                                Label("Open System Settings",
                                      systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                openDeepLink(category.deepLink)
                            } label: {
                                Label("Open in System Settings…",
                                      systemImage: "arrow.up.right.square")
                            }
                        }
                        if !category.hasQuery {
                            Text("No API — can't self-check.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer()
            }
        }
    }

    /// red-team #4: `x-apple.systempreferences:` URLs with Privacy_* anchors
    /// are NOT a documented API. Apple has shipped at least three URL schemes
    /// across macOS 12-26 (`com.apple.preference.security`,
    /// `com.apple.settings.PrivacySecurity.extension`, and the bare
    /// `com.apple.SystemSettings.PrivacySecurityExtension`). NSWorkspace.open
    /// returns `false` if the anchor is unrecognised but currently *still*
    /// opens the parent pane — but we belt-and-suspenders by trying multiple
    /// schemes in order and falling back to opening the Privacy root.
    private func openDeepLink(_ primary: String) {
        // Try the URL we shipped with.
        if let url = URL(string: primary), NSWorkspace.shared.open(url) {
            return
        }
        // Translate to the newer scheme (Ventura+) by replacing the bundle id.
        let translated = primary.replacingOccurrences(
            of: "com.apple.preference.security",
            with: "com.apple.settings.PrivacySecurity.extension")
        if translated != primary,
           let url = URL(string: translated),
           NSWorkspace.shared.open(url) {
            return
        }
        // Last resort: open the Privacy root pane (always exists).
        if let root = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"),
           NSWorkspace.shared.open(root) {
            return
        }
        // Absolute last resort — open System Settings with no anchor.
        if let app = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(app)
        }
    }

    @ViewBuilder private var badge: some View {
        if !category.hasQuery && status == .unknown {
            Label("No self-check", systemImage: PermsStatus.unknown.icon)
                .font(.caption)
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
        } else {
            Label(status.label, systemImage: status.icon)
                .font(.caption.weight(.medium))
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(status.color.opacity(0.15), in: Capsule())
                .foregroundStyle(status.color)
        }
    }
}

// ===========================================================================
// MARK: - Footer / caveat card
// ===========================================================================

struct PermsCaveatCard: View {
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why can't Trove list every app's permissions?").font(.headline)
                    Text("The macOS TCC database (`~/Library/Application Support/com.apple.TCC/TCC.db` and `/Library/Application Support/com.apple.TCC/TCC.db`) is owned by root and protected by SIP. Reading it requires Full Disk Access AND elevated privileges — neither is appropriate for a regular app. This pane shows what Trove itself has been granted (where the OS exposes a query) and gives you one-click access to every Privacy sub-pane so you can audit per-app grants there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tip: review Full Disk Access and Accessibility periodically — these are the highest-blast-radius grants on macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Spacer()
            }
        }
    }
}
