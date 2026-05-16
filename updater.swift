// Trove — auto-update checker.
//
// Polls the **GitHub Releases API** directly — no separate manifest hosting,
// no format mismatch. The repo at `Self.repoOwner/Self.repoName` is the
// single source of truth: every `gh release create vX.Y.Z` is a self-
// publishing event, and the in-app checker compares `tag_name` (stripped of
// the leading `v`) to `CFBundleShortVersionString`. Override the endpoint
// with `TROVE_UPDATE_URL` for testing.
//
// Defensive contract (the whole reason this file is shaped this way):
//   • Every error path is recoverable. No `try!`, no `as!`, no force-unwrap.
//   • Bad data from GitHub (missing fields, wrong types, empty assets,
//     huge release notes) maps to `status = "Up to date"` — never a crash.
//   • Network failures (DNS, timeout, offline, 403 rate limit, 5xx) are
//     swallowed quietly on the auto path and surfaced on the manual path.
//   • All UI state writes go through `@MainActor`. No publishing from
//     background threads.
//   • This module never blocks the main thread. URLSession is async-await,
//     decoding runs on the URLSession completion's executor.

import SwiftUI
import AppKit
import Foundation

// ===========================================================================
// MARK: - Release model (maps GitHub's /releases/latest response)
// ===========================================================================

/// Subset of the GitHub Release JSON we actually read. Every field is
/// optional so a partial / malformed response can still decode without
/// throwing — the consumer treats missing fields as "no update offer".
struct GitHubRelease: Decodable, Equatable {
    let tagName: String?
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: String?
    let prerelease: Bool?
    let draft: Bool?
    let assets: [Asset]?

    struct Asset: Decodable, Equatable {
        let name: String?
        let browserDownloadURL: String?
        let size: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName     = "tag_name"
        case name
        case body
        case htmlURL     = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case assets
    }

    /// Semver-ish version, with any leading `v` stripped. Returns nil if the
    /// tag is empty or doesn't contain at least one numeric segment.
    var versionString: String? {
        guard let raw = tagName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        // Reject if no digit in the first segment.
        let first = stripped.split(separator: ".").first.map(String.init) ?? stripped
        guard first.contains(where: { $0.isNumber }) else { return nil }
        return stripped
    }

    /// Preferred download URL: the first `.zip` asset, falling back to the
    /// first `.dmg`, finally to the release's `html_url` page. Never crashes
    /// on missing assets.
    var preferredDownloadURL: String? {
        if let assets = assets {
            if let zip = assets.first(where: { ($0.name ?? "").lowercased().hasSuffix(".zip") }),
               let u = zip.browserDownloadURL { return u }
            if let dmg = assets.first(where: { ($0.name ?? "").lowercased().hasSuffix(".dmg") }),
               let u = dmg.browserDownloadURL { return u }
        }
        return htmlURL
    }

    /// Truncated release notes (≤ 800 chars) so a runaway release body
    /// can't blow up the SwiftUI layout. Strips trailing whitespace.
    var displayNotes: String {
        let raw = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count <= 800 { return raw }
        return String(raw.prefix(800)) + "…"
    }
}

// ===========================================================================
// MARK: - Checker
// ===========================================================================

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var autoCheckEnabled: Bool
    @Published private(set) var includePrereleases: Bool
    @Published private(set) var lastCheck: Date?
    @Published private(set) var latestAvailable: GitHubRelease?
    @Published private(set) var status: String = "Not yet checked"
    @Published private(set) var checking: Bool = false

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// Repo coordinates. If the repo gets renamed or transferred, change here
    /// (and only here) — the URL builder reads these.
    static let repoOwner = "ArnavGoel03"
    static let repoName  = "trove"

    /// Default endpoint. The build can override at runtime by setting
    /// `TROVE_UPDATE_URL` — useful for pointing at a forked repo, a
    /// localhost test server, or a private mirror.
    private static var defaultEndpoint: String {
        "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases"
    }

    private static let keyAutoCheck    = "updater.autoCheckEnabled"
    private static let keyPrereleases  = "updater.includePrereleases"
    private static let keyLastCheck    = "updater.lastCheckAt"

    private init() {
        let d = UserDefaults.standard
        // Default ON; persist as soon as the user toggles.
        if d.object(forKey: Self.keyAutoCheck) == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = d.bool(forKey: Self.keyAutoCheck)
        }
        self.includePrereleases = d.bool(forKey: Self.keyPrereleases)
        if let t = d.object(forKey: Self.keyLastCheck) as? Date {
            self.lastCheck = t
        }
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /// Called from `AppDelegate.applicationDidFinishLaunching`. No-op when
    /// auto-check is off OR we checked < 6h ago. Wrapped in a do/catch-like
    /// `Task` so any error inside `check(quiet:)` (there shouldn't be any —
    /// every error path is handled) silently degrades instead of bubbling.
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

    func setIncludePrereleases(_ on: Bool) {
        includePrereleases = on
        UserDefaults.standard.set(on, forKey: Self.keyPrereleases)
        // Re-check immediately so the UI reflects the new policy.
        Task { await self.check(quiet: true) }
    }

    /// Trigger a check. `quiet=true` suppresses error noise (auto path);
    /// `quiet=false` (manual button) surfaces a one-line status message.
    func check(quiet: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        status = "Checking…"

        // Resolve endpoint. If a user-supplied URL is malformed or fails the
        // allowlist check, fall back to the default rather than crashing.
        // Fix: parse the URL and check scheme, host (exact), and path prefix to
        // prevent SSRF via userinfo bypass (e.g. https://api.github.com/repos/@evil.com).
        let overrideRaw = ProcessInfo.processInfo.environment["TROVE_UPDATE_URL"].flatMap {
            $0.isEmpty ? nil : $0
        }
        let endpoint: String
        if let raw = overrideRaw,
           let overrideURL = URL(string: raw),
           overrideURL.scheme == "https",
           overrideURL.host == "api.github.com",
           overrideURL.path.hasPrefix("/repos/") {
            endpoint = raw
        } else {
            if overrideRaw != nil {
                // Override present but doesn't pass the strict allowlist — fall back silently.
            }
            endpoint = Self.defaultEndpoint
        }
        guard let baseURL = URL(string: endpoint) else {
            await markUpToDate()
            return
        }

        // If we're allowing prereleases, fetch the full list and pick the
        // newest by tag. Otherwise the `/releases/latest` endpoint excludes
        // drafts and prereleases for free.
        let url: URL
        if includePrereleases {
            url = baseURL
        } else {
            url = baseURL.appendingPathComponent("latest")
        }

        // Build the request with defensible defaults: short timeout (so a
        // hung connection never wedges the auto path), no-cache (we always
        // want fresh state), and an explicit Accept header.
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Trove/\(Self.currentVersion() ?? "dev")", forHTTPHeaderField: "User-Agent")

        var suppressStamp = false
        do {
            // Use download(for:) so the response streams to a temp file instead
            // of accumulating the full body in memory before the size cap fires.
            let (tmpURL, resp) = try await URLSession.shared.download(for: req)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            // Hard cap: GitHub's /releases/latest payload is ~5-15 KB. The
            // full /releases list with 100 entries is ~1-3 MB. Anything
            // bigger than 4 MB is either a mistake or hostile — refuse to load.
            let fileSize = (try? tmpURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize <= 4 * 1024 * 1024 else {
                await markUpToDate()
                return
            }
            guard let data = try? Data(contentsOf: tmpURL) else {
                await markUpToDate()
                return
            }
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // Fix 12: also suppress on 429 (rate limit) and captive-portal HTML responses.
            let mimeType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isCaptivePortal = statusCode == 200 && mimeType.hasPrefix("text/html")
            suppressStamp = (statusCode == 403) || (statusCode == 429)
                || (500..<600).contains(statusCode) || isCaptivePortal
            if isCaptivePortal {
                // Don't ingest HTML as JSON.
                await markUpToDate()
            } else {
                await ingest(data: data, response: resp, quiet: quiet)
            }
        } catch {
            // DNS, timeout, offline, certificate errors — silently degrade.
            if quiet {
                await markUpToDate()
            } else {
                await setStatus("Check failed: \(error.localizedDescription)")
                await clearAvailable()
            }
        }
        if !suppressStamp { stampCheck() }
    }

    // -----------------------------------------------------------------------
    // Ingest + decide
    // -----------------------------------------------------------------------

    /// Parse the response and update `latestAvailable` / `status`. Never
    /// throws — every error path falls through to "up to date".
    private func ingest(data: Data, response: URLResponse, quiet: Bool) async {
        guard let http = response as? HTTPURLResponse else {
            await markUpToDate()
            return
        }

        switch http.statusCode {
        case 200..<300:
            break  // proceed to decode
        case 404:
            // Repo public but no releases yet — clean "up to date".
            await markUpToDate()
            return
        case 403:
            // Rate limit. Don't badge the UI; we'll try again in 6h.
            if quiet {
                await markUpToDate()
            } else {
                await setStatus("GitHub rate-limited the check. Try again later.")
                await clearAvailable()
            }
            return
        default:
            if quiet {
                await markUpToDate()
            } else {
                await setStatus("Check failed (HTTP \(http.statusCode))")
                await clearAvailable()
            }
            return
        }

        // Decode. Either a single object (/latest) or an array (full list,
        // for the prerelease-aware path). Either way, pick the newest tag
        // that we'd actually offer.
        let decoder = JSONDecoder()
        let release: GitHubRelease?
        if includePrereleases {
            release = (try? decoder.decode([GitHubRelease].self, from: data))
                .flatMap { list in
                    list
                        .filter { ($0.draft ?? false) == false }
                        .sorted { lhs, rhs in
                            // Sort by version desc; nil versions go last.
                            switch (lhs.versionString, rhs.versionString) {
                            case (let l?, let r?): return versionIsNewer(l, than: r)
                            case (.some, .none):   return true
                            case (.none, .some):   return false
                            case (.none, .none):   return false
                            }
                        }
                        .first
                }
        } else {
            release = try? decoder.decode(GitHubRelease.self, from: data)
        }

        guard let r = release else {
            // JSON unparseable / unexpected shape. Treat as up-to-date.
            await markUpToDate()
            return
        }
        // Drafts are excluded by /latest; the prerelease-aware path filtered
        // them above. Defensive check anyway.
        if r.draft == true {
            await markUpToDate()
            return
        }

        if shouldOffer(r) {
            await MainActor.run {
                self.latestAvailable = r
                self.status = "Update available: \(r.versionString ?? "?")"
            }
        } else {
            await markUpToDate()
        }
    }

    // -----------------------------------------------------------------------
    // Version policy
    // -----------------------------------------------------------------------

    private func shouldOffer(_ r: GitHubRelease) -> Bool {
        guard let remote = r.versionString else { return false }
        guard let local = Self.currentVersion() else { return false }
        return versionIsNewer(remote, than: local)
    }

    /// Reads `CFBundleShortVersionString` from the running bundle. Returns
    /// nil if the key is missing (impossible in a real build, defensive).
    static func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Numeric segment compare: "1.10" > "1.9". Non-numeric suffix
    /// ("-beta", "+sha") is stripped per segment.
    fileprivate func versionIsNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".")
        let bParts = b.split(separator: ".")
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? Int(aParts[i].prefix(while: { $0.isNumber })) ?? 0 : 0
            let bv = i < bParts.count ? Int(bParts[i].prefix(while: { $0.isNumber })) ?? 0 : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // -----------------------------------------------------------------------
    // State helpers (all main-actor)
    // -----------------------------------------------------------------------

    private func markUpToDate() async {
        await MainActor.run {
            self.latestAvailable = nil
            self.status = "Up to date"
        }
    }

    private func setStatus(_ s: String) async {
        await MainActor.run { self.status = s }
    }

    private func clearAvailable() async {
        await MainActor.run { self.latestAvailable = nil }
    }

    private func stampCheck() {
        let now = Date()
        lastCheck = now
        UserDefaults.standard.set(now, forKey: Self.keyLastCheck)
    }
}

// ===========================================================================
// MARK: - Settings card
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

                Text("Trove polls the GitHub Releases page at github.com/\(UpdateChecker.repoOwner)/\(UpdateChecker.repoName). New versions show a Download button here that opens the release page in your browser. Auto-install (Sparkle) is on the roadmap once Apple Developer enrollment is complete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { checker.autoCheckEnabled },
                    set: { checker.setAutoCheck($0) }
                )) {
                    Text("Check for updates automatically on launch")
                }

                Toggle(isOn: Binding(
                    get: { checker.includePrereleases },
                    set: { checker.setIncludePrereleases($0) }
                )) {
                    Text("Include pre-releases")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)

                if let info = checker.latestAvailable, let v = info.versionString {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Trove \(v) available")
                                    .font(.body.weight(.medium))
                                if info.prerelease == true {
                                    Text("PRE")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.orange.opacity(0.25), in: Capsule())
                                }
                            }
                            if !info.displayNotes.isEmpty {
                                Text(info.displayNotes)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Download") {
                            if let s = info.preferredDownloadURL, let url = URL(string: s) {
                                // Fix 10: only open https URLs — reject file://, javascript://, etc.
                                guard url.scheme == "https" else { return }
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
                    if let v = UpdateChecker.currentVersion() {
                        Text("Current: \(v)").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let last = checker.lastCheck {
                        Text("•").font(.caption).foregroundStyle(.tertiary)
                        Text("Checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
