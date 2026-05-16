// Trove — Account / Profile pane.
//
// Surface:
//   • Public `struct AccountView: View` with a no-arg init — drop into RootView.
//   • `AccountStore.shared` singleton holds prefs + auth state + delegate retention.
//   • `AccountStore.shared.prefs.showFlash`, `.confirmDestructive` for callers.
//
// Persistence:
//   • ~/Library/Application Support/Trove/account.json   (atomic, non-sensitive)
//   • Keychain item `com.arnavgoel.trove` / account=userIdentifier (identityToken)
//
// Sign in with Apple gracefully degrades when the binary isn't signed with a
// Developer Team — error is surfaced inline, the rest of the pane keeps working.

import SwiftUI
import AppKit
import AuthenticationServices
import Security
import Foundation

// ===========================================================================
// MARK: - Persistence model
// ===========================================================================

struct AccountPrefs: Codable, Equatable {
    var showFlash: Bool = true
    var confirmDestructive: Bool = true
}

struct AccountIdentity: Codable, Equatable {
    var userIdentifier: String
    var fullName: String?
    var email: String?
    // identityToken is intentionally NOT here — it lives in Keychain.
}

struct AccountFile: Codable {
    var prefs: AccountPrefs
    var identity: AccountIdentity?

    static let empty = AccountFile(prefs: AccountPrefs(), identity: nil)
}

// ===========================================================================
// MARK: - Keychain helper (Security framework)
// ===========================================================================

enum AccountKeychain {
    static let service = "com.arnavgoel.trove"

    @discardableResult
    static func set(account: String, data: Data) -> OSStatus {
        // Delete first so attribute changes don't trip duplicate errors.
        _ = delete(account: account)
        // red-team-sec: `kSecAttrAccessibleAfterFirstUnlock` migrates with the
        // Keychain via Time Machine / Migration Assistant onto a different
        // Mac, which leaks the identityToken off-device. The token is bound
        // to this Mac's Apple ID session — there's zero legitimate reason for
        // it to follow the Keychain across devices. Use the
        // `ThisDeviceOnly` variant so it's discarded on migration.
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(q as CFDictionary)
    }
}

// ===========================================================================
// MARK: - AccountStore — singleton, ObservableObject
// ===========================================================================

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var prefs: AccountPrefs = AccountPrefs()
    @Published var identity: AccountIdentity? = nil
    @Published var lastAuthError: String? = nil
    @Published var isAuthorizing: Bool = false

    /// The AS coordinator must outlive the request — `ASAuthorizationController`
    /// only weak-refs its delegate. Stash it here while a request is in flight.
    fileprivate var pendingCoordinator: AccountSIWACoordinator?

    private init() {
        // Seed published defaults immediately; load() can block on slow disks.
        // Defer to a detached task and patch back on MainActor, matching the
        // pattern used by ProfileSync.init().
        Task.detached(priority: .utility) { [weak self] in
            await MainActor.run { self?.load() }
        }
    }

    // ---- file path -------------------------------------------------------

    var fileURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Trove", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("account.json")
    }

    // ---- load / save -----------------------------------------------------

    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard let data = boundedRead(url) else { throw CocoaError(.fileReadNoSuchFile) }
            let parsed = try JSONDecoder().decode(AccountFile.self, from: data)
            self.prefs = parsed.prefs
            self.identity = parsed.identity
        } catch {
            // Corrupt → quarantine and start fresh, then surface via flash.
            let ts = Int(Date().timeIntervalSince1970)
            let bad = url.deletingLastPathComponent()
                .appendingPathComponent("account-corrupt-\(ts).json")
            try? FileManager.default.moveItem(at: url, to: bad)
            self.prefs = AccountPrefs()
            self.identity = nil
            // The Stage flash is a global side-channel for status — reuse it.
            #if canImport(SwiftUI)
            SharedStore.stage.flash("Account file corrupt — quarantined to \(bad.lastPathComponent)")
            #endif
        }
    }

    func save() {
        let file = AccountFile(prefs: prefs, identity: identity)
        do {
            let data = try JSONEncoder().encode(file)
            try atomicWrite(data, to: fileURL)
        } catch {
            SharedStore.stage.flash("Account save failed: \(error.localizedDescription)")
        }
    }

    /// Write to tmp, then `replaceItem` for atomicity.
    private func atomicWrite(_ data: Data, to dest: URL) throws {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".account.json.tmp-\(UUID().uuidString.prefix(6))")
        try data.write(to: tmp, options: [.atomic])
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        // red-team-sec: account.json contains the user's Apple ID identifier,
        // email, and full name. Default FileManager-created files inherit the
        // process umask (typically 644 = world-readable). Tighten to 600 so
        // other local users (and other macOS apps without TCC permission to
        // ~/Library/Application Support) can't read PII out of band.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                              ofItemAtPath: dest.path)
    }

    // ---- prefs mutation helpers (so views can bind) ---------------------

    func setShowFlash(_ v: Bool)         { prefs.showFlash = v; save() }
    func setConfirmDestructive(_ v: Bool) { prefs.confirmDestructive = v; save() }

    // ---- Sign in with Apple ---------------------------------------------

    func startSignInWithApple() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let coord = AccountSIWACoordinator(
            onSuccess: { [weak self] cred in self?.handleSIWASuccess(cred) },
            onFailure: { [weak self] err  in self?.handleSIWAFailure(err)  }
        )
        controller.delegate = coord
        controller.presentationContextProvider = coord
        pendingCoordinator = coord
        isAuthorizing = true
        lastAuthError = nil
        controller.performRequests()
    }

    fileprivate func handleSIWASuccess(_ cred: ASAuthorizationAppleIDCredential) {
        let identifier = cred.user
        let id = AccountIdentity(
            userIdentifier: identifier,
            fullName: cred.fullName?.formatted(),
            email: cred.email
        )
        identity = id
        if let token = cred.identityToken {
            AccountKeychain.set(account: identifier, data: token)
        }
        save()
        isAuthorizing = false
        lastAuthError = nil
        pendingCoordinator = nil
        SharedStore.stage.flash("Signed in with Apple")
    }

    fileprivate func handleSIWAFailure(_ err: Error) {
        isAuthorizing = false
        pendingCoordinator = nil

        // The classic "no Developer Team entitlement" symptom is
        // ASAuthorizationError.unknown / .failed coming back instantly.
        if let asErr = err as? ASAuthorizationError {
            switch asErr.code {
            case .canceled:
                lastAuthError = nil
                return
            default:
                lastAuthError = "Sign in with Apple needs a Developer Team signing identity. Until then, your local profile from macOS is being used."
                return
            }
        }
        lastAuthError = err.localizedDescription
    }

    func signOut() {
        // Order-independent: try both, swallow individual failures.
        if let id = identity?.userIdentifier {
            _ = AccountKeychain.delete(account: id)
        }
        identity = nil
        lastAuthError = nil
        // red-team: signing out mid-SIWA-flow leaked the SIWA coordinator
        // (still pinned by `pendingCoordinator`) and left `isAuthorizing=true`
        // forever — the spinner kept turning. Clear the in-flight handshake so
        // a subsequent Sign In starts from a clean slate.
        isAuthorizing = false
        pendingCoordinator = nil
        save()
        SharedStore.stage.flash("Signed out")
    }
}

// ===========================================================================
// MARK: - SIWA coordinator (delegate retention via AccountStore)
// ===========================================================================

final class AccountSIWACoordinator: NSObject,
                                     ASAuthorizationControllerDelegate,
                                     ASAuthorizationControllerPresentationContextProviding {
    let onSuccess: (ASAuthorizationAppleIDCredential) -> Void
    let onFailure: (Error) -> Void

    init(onSuccess: @escaping (ASAuthorizationAppleIDCredential) -> Void,
         onFailure: @escaping (Error) -> Void) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
            onSuccess(cred)
        } else {
            onFailure(NSError(domain: "Account", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"]))
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        onFailure(error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// ===========================================================================
// MARK: - System identity probe
// ===========================================================================

struct AccountSystemInfo {
    let fullName: String
    let shortName: String
    let hostName: String
    let osVersion: String
    let chip: String
    let memory: Int64
    let uptime: TimeInterval

    static func snapshot() -> AccountSystemInfo {
        AccountSystemInfo(
            fullName:  NSFullUserName(),
            shortName: NSUserName(),
            hostName:  Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip:      Self.uname(),
            memory:    Int64(ProcessInfo.processInfo.physicalMemory),
            uptime:    ProcessInfo.processInfo.systemUptime
        )
    }

    /// Read the CPU architecture via `sysctlbyname("hw.machine", …)`. Pure
    /// in-process syscall (microseconds, no fork), so this is safe to call
    /// from anywhere — including SwiftUI view init on the main thread, which
    /// is exactly where the old `Process()` + `uname -m` chain crashed Trove
    /// on 2026-05-16 06:03 (`@State` default expression evaluated during
    /// `AccountView.init`).
    private static func uname() -> String {
        if let cached = cachedUname { return cached }
        var size = 0
        if sysctlbyname("hw.machine", nil, &size, nil, 0) != 0 || size == 0 {
            cachedUname = "unknown"
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.machine", &bytes, &size, nil, 0) != 0 {
            cachedUname = "unknown"
            return "unknown"
        }
        let out = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = out.isEmpty ? "unknown" : out
        cachedUname = resolved
        return resolved
    }
    private static var cachedUname: String?
}

private func formatUptime(_ t: TimeInterval) -> String {
    let total = Int(t)
    let d = total / 86_400
    let h = (total % 86_400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// ===========================================================================
// MARK: - Avatar resolver
// ===========================================================================

enum AccountAvatar {
    /// Try OS-provided picture → ~/.profile-image override → nil (caller draws initials).
    static func systemImage() -> NSImage? {
        // (a) Apple Pictures path (varies by macOS; just try a couple of guesses).
        let candidates = [
            "/Library/User Pictures/\(NSUserName()).tif",
            "/Users/\(NSUserName())/Library/Application Support/com.apple.preferences.users/avatar/\(NSUserName()).tif",
            "/var/db/dslocal/nodes/Default/users/\(NSUserName()).plist",  // not an image, skipped below
        ]
        for path in candidates {
            if path.hasSuffix(".plist") { continue }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOf: url) {
                return img
            }
        }
        // (b) User-provided override.
        let override = NSHomeDirectory() + "/.profile-image"
        if FileManager.default.fileExists(atPath: override) {
            if let img = NSImage(byReferencingFile: override), img.isValid {
                return img
            }
        }
        return nil
    }

    /// Deterministic accent color from a string (used for initials avatars).
    static func accentColor(for seed: String) -> Color {
        var hash: UInt64 = 1469598103934665603  // FNV-1a offset
        for b in seed.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap { $0.first }.map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }
}

// ===========================================================================
// MARK: - AccountView (public surface)
// ===========================================================================

public struct AccountView: View {
    @StateObject private var store = AccountStore.shared
    @State private var sys = AccountSystemInfo.snapshot()
    @State private var uptimeTicker: Date = Date()
    // red-team: capture boot ONCE; computed-prop version recomputed each call,
    // making `sys.uptime + Date().timeIntervalSince(boot)` collapse to ~2×uptime
    // that never grows with the ticker.
    @State private var bootMoment: Date = Date()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroCard
                signInCard
                identityCard
                prefsCard
                Spacer(minLength: 8)
            }
            .padding(18)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .navigationTitle("Account")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    sys = AccountSystemInfo.snapshot()
                    uptimeTicker = Date()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read local system identity")

                if store.identity != nil {
                    Button(role: .destructive) {
                        store.signOut()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            uptimeTicker = Date()
        }
    }

    private var subtitle: String {
        if let id = store.identity {
            return "Signed in as \(id.fullName ?? id.email ?? id.userIdentifier)"
        }
        return "Signed in locally as \(sys.shortName)"
    }

    // ---- Hero -----------------------------------------------------------

    private var heroCard: some View {
        Card {
            HStack(alignment: .top, spacing: 18) {
                AccountAvatarView(name: displayName, size: 84)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.title2.weight(.semibold))
                    Text(secondaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: store.identity == nil
                              ? "lock.laptopcomputer"
                              : "checkmark.seal.fill")
                        Text(store.identity == nil ? "Local profile" : "Verified Apple ID")
                    }
                    .font(.caption)
                    .foregroundStyle(store.identity == nil
                                     ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                     : AnyShapeStyle(Color.green))
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var displayName: String {
        if let n = store.identity?.fullName, !n.isEmpty { return n }
        let f = sys.fullName
        return f.isEmpty ? sys.shortName : f
    }

    private var secondaryLine: String {
        if let email = store.identity?.email, !email.isEmpty { return email }
        if store.identity != nil { return "Apple ID linked" }
        return "Signed in locally"
    }

    // ---- Sign in with Apple --------------------------------------------

    @ViewBuilder
    private var signInCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Sign in with Apple", systemImage: "applelogo")
                    .font(.headline)

                if let id = store.identity {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in as \(id.fullName ?? id.email ?? "Apple user")")
                                .font(.callout.weight(.medium))
                            Text(id.userIdentifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.signOut()
                        } label: {
                            Text("Sign out")
                        }
                    }
                } else {
                    SignInWithAppleButton(
                        onRequest: { req in
                            req.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(let auth):
                                if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                                    store.handleSIWASuccess(cred)
                                }
                            case .failure(let err):
                                store.handleSIWAFailure(err)
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 36)
                    .frame(maxWidth: 280)

                    if store.isAuthorizing {
                        ProgressView().controlSize(.small)
                    }

                    if let err = store.lastAuthError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    } else {
                        Text("When this app is signed with a Developer Team, Sign in with Apple will link your Apple ID. Until then, the local profile below is used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // ---- System identity ------------------------------------------------

    private var identityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("System identity", systemImage: "person.crop.rectangle")
                    .font(.headline)

                let _ = uptimeTicker  // re-eval when ticker fires
                AccountInfoGrid(rows: [
                    ("Full name",   sys.fullName),
                    ("Short name",  sys.shortName),
                    ("Host name",   sys.hostName),
                    ("macOS",       sys.osVersion),
                    ("Chip",        sys.chip),
                    ("Memory",      sys.memory.human),
                    // red-team: use captured `bootMoment` (anchored at View init)
                    // rather than a recomputed Date — otherwise uptime is doubled
                    // and frozen at boot value instead of ticking up.
                    ("Uptime",      formatUptime(Date().timeIntervalSince(bootMoment) + sys.uptime)),
                ])
            }
        }
    }

    // red-team: removed `boot` computed property — it recomputed on every read,
    // so `Date().timeIntervalSince(boot)` was effectively zero each call and the
    // displayed uptime was 2×snapshot-uptime that never advanced. Replaced by
    // `bootMoment` @State above.

    // ---- Preferences ---------------------------------------------------

    private var prefsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Preferences", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Toggle(isOn: Binding(
                    get: { store.prefs.showFlash },
                    set: { store.setShowFlash($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show transient banners")
                        Text("Brief status messages under the title bar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { store.prefs.confirmDestructive },
                    set: { store.setConfirmDestructive($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Confirm before destructive actions")
                        Text("Ask before clearing, deleting, or sweeping")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider().padding(.vertical, 4)

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(store.fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }
}

// ===========================================================================
// MARK: - Reusable pieces
// ===========================================================================

private struct AccountAvatarView: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let img = AccountAvatar.systemImage() {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [
                                AccountAvatar.accentColor(for: name),
                                AccountAvatar.accentColor(for: name + "!")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Text(AccountAvatar.initials(name))
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .overlay(
            Circle().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}

private struct AccountInfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(row.1)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                if idx < rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
    }
}
