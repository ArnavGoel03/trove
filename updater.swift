// Trove — auto-update checker.
//
// Light Sparkle-equivalent: on launch (and on demand) fetch a JSON manifest,
// compare versions, surface a banner + "Download" button if a newer release
// exists. No silent install — Gatekeeper requires the replacement bundle to
// be signed and notarized, which only happens after the user runs the
// `notarize-trove` flow with their Developer ID cert.
//
// Default: auto-check is ON.
// Override manifest URL with TROVE_UPDATE_URL env var (handy for testing).

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - Manifest schema
// ===========================================================================

struct UpdaterManifest: Codable, Hashable {
    let version: String        // e.g. "1.2.0"
    let buildNumber: Int?      // optional monotonic counter
    let downloadURL: String    // user clicks → opens in browser
    let releaseNotes: String?  // short markdown blurb shown in the card
    let mandatory: Bool?       // if true, the card emphasizes "please update"
    let releasedAt: String?    // ISO8601; informational only
    let minSystemVersion: String?  // e.g. "13.0" — skip if user's OS is older
}

// ===========================================================================
// MARK: - Checker
// ===========================================================================

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var autoCheckEnabled: Bool
    @Published private(set) var lastCheck: Date?
    @Published private(set) var latestAvailable: UpdaterManifest?
    @Published private(set) var status: String = "Not yet checked"
    @Published private(set) var checking: Bool = false

    // Default manifest URL — replace once you have a public release page.
    // Until then the check fails gracefully ("manifest not reachable") and
    // the user sees a friendly "you're on the latest" message.
    private static let defaultManifestURL = "https://trove.invalid/updates.json"

    private static let keyAutoCheck = "updater.autoCheckEnabled"
    private static let keyLastCheck = "updater.lastCheckAt"

    private init() {
        let d = UserDefaults.standard
        // red-team: default ON — user explicitly asked for this. Persist as
        // soon as the user flips it, so it sticks.
        if d.object(forKey: Self.keyAutoCheck) == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = d.bool(forKey: Self.keyAutoCheck)
        }
        if let t = d.object(forKey: Self.keyLastCheck) as? Date {
            self.lastCheck = t
        }
    }

    /// Called from `AppDelegate.applicationDidFinishLaunching` after the
    /// status item is up. No-op when the user has turned auto-check off, OR
    /// when we checked less than 6h ago (cheap throttle).
    func checkOnLaunchIfEligible() {
        guard autoCheckEnabled else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 6 * 3600 {
            return
        }
        Task { await self.check(quiet: true) }
    }

    func setAutoCheck(_ on: Bool) {
        autoCheckEnabled = on
        UserDefaults.standard.set(on, forKey: Self.keyAutoCheck)
    }

    /// Manually trigger a check. `quiet=true` suppresses error flashes for the
    /// auto-launch path (we don't want a noisy banner if the manifest URL
    /// hasn't been wired yet); `quiet=false` (manual button) surfaces errors.
    func check(quiet: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        status = "Checking…"

        let envURL = ProcessInfo.processInfo.environment["TROVE_UPDATE_URL"]
        let urlString = envURL?.isEmpty == false ? envURL! : Self.defaultManifestURL
        guard let url = URL(string: urlString) else {
            status = "Manifest URL is malformed"
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                status = "No HTTP response"
                return
            }
            if http.statusCode == 404 || http.statusCode >= 500 {
                // Manifest not deployed yet — treat as "no update" rather than
                // an error so the default placeholder doesn't badge the UI.
                status = "Up to date"
                latestAvailable = nil
                stampCheck()
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                status = quiet ? "Up to date" : "Check failed (HTTP \(http.statusCode))"
                return
            }
            let info = try JSONDecoder().decode(UpdaterManifest.self, from: data)
            stampCheck()
            if shouldOffer(info) {
                latestAvailable = info
                status = "Update available: \(info.version)"
            } else {
                latestAvailable = nil
                status = "Up to date"
            }
        } catch {
            // red-team: silent failure for the auto-check path — the user
            // doesn't need a "DNS failed" banner every launch when their
            // manifest URL isn't set up yet.
            status = quiet ? "Up to date" : "Check failed: \(error.localizedDescription)"
            latestAvailable = nil
        }
    }

    private func stampCheck() {
        let now = Date()
        lastCheck = now
        UserDefaults.standard.set(now, forKey: Self.keyLastCheck)
    }

    private func shouldOffer(_ info: UpdaterManifest) -> Bool {
        guard let current = currentVersion() else { return false }
        if !versionIsNewer(info.version, than: current) { return false }
        if let minOS = info.minSystemVersion,
           !systemMeetsMinimum(minOS) {
            return false
        }
        return true
    }

    private func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func systemMeetsMinimum(_ minSemver: String) -> Bool {
        let need = minSemver.split(separator: ".").compactMap { Int($0) }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let have = [v.majorVersion, v.minorVersion, v.patchVersion]
        for i in 0..<max(need.count, have.count) {
            let a = i < have.count ? have[i] : 0
            let b = i < need.count ? need[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return true
    }

    /// Pure semver-ish numeric compare. "1.10" > "1.9". Non-numeric segments
    /// are treated as 0 so a stray "-beta" suffix doesn't shadow the numeric
    /// prefix.
    private func versionIsNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").map { String($0) }
        let bParts = b.split(separator: ".").map { String($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? Int(aParts[i].prefix(while: { $0.isNumber })) ?? 0 : 0
            let bv = i < bParts.count ? Int(bParts[i].prefix(while: { $0.isNumber })) ?? 0 : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}

// ===========================================================================
// MARK: - Customize-pane card
// ===========================================================================

struct UpdateCheckerCard: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
                    Text("Updates").font(.headline)
                    Spacer()
                    Text(checker.status).font(.caption).foregroundStyle(.secondary)
                }

                Text("Trove can check a release manifest you control and offer to download newer versions. Auto-install requires a signed + notarized build — the download button just opens the release page in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { checker.autoCheckEnabled },
                    set: { checker.setAutoCheck($0) }
                )) {
                    Text("Check for updates automatically on launch")
                }

                if let info = checker.latestAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Trove \(info.version) available")
                                .font(.body.weight(.medium))
                            if let notes = info.releaseNotes, !notes.isEmpty {
                                Text(notes).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Open download page") {
                            if let url = URL(string: info.downloadURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button {
                        Task { await checker.check(quiet: false) }
                    } label: {
                        HStack(spacing: 6) {
                            if checker.checking { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text("Check now")
                        }
                    }
                    .disabled(checker.checking)
                    Spacer()
                    if let last = checker.lastCheck {
                        Text("Last checked: \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
