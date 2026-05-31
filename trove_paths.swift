// Trove — central path resolver (power-user item #8: XDG_CONFIG_HOME).
//
// Until beta.14, every storage-touching pane built its own
// `~/Library/Application Support/Trove/…` URL inline. This central helper
// gives Trove one place to decide where config data lives, so users who
// want a dotfile-friendly layout (`~/.config/trove/`) can opt in without
// every pane growing its own conditional path.
//
// Resolution order (first hit wins, evaluated lazily on first access):
//
//   1. `$TROVE_CONFIG_HOME` — explicit override. Useful for portable
//      installs (USB stick, sandbox, CI), and unambiguous regardless of
//      what XDG_CONFIG_HOME is set to.
//   2. `$XDG_CONFIG_HOME/trove` — the XDG Base Directory spec.
//   3. `~/.config/trove/` — XDG default when `XDG_CONFIG_HOME` is unset
//      but the user has created `~/.config/trove/` to signal intent.
//   4. `~/Library/Application Support/Trove/` — macOS-native fallback.
//      This is where Trove has always stored data, so existing installs
//      keep working with no migration.
//
// All four destinations resolve through the same `appSupportDir` static,
// so panes never have to know which one is active. Call sites read
// `TrovePaths.appSupportDir` exactly the way they used to read the
// inline App Support URL.
//
// Notes
// -----
// • This file declares no `@main` and no Pane case; it's pure utility.
// • The chosen directory is created on first access (with
//   `withIntermediateDirectories: true`) so callers don't have to
//   pre-create it themselves.
// • The selection is evaluated once per process — flipping
//   `$XDG_CONFIG_HOME` mid-run will not retroactively move files.
//   Restart Trove to pick up env changes.

import Foundation

enum TrovePaths {

    /// Resolved App Support root. All Trove panes write their JSON
    /// stores under this directory.
    ///
    /// red-team-sec: validates each candidate URL via `pathIsSafe(_:)`
    /// before adopting it — a misconfigured `$TROVE_CONFIG_HOME=/` or
    /// `$XDG_CONFIG_HOME=/etc` would otherwise persuade Trove to drop
    /// files at the filesystem root.
    static let appSupportDir: URL = {
        let url = resolveAppSupportDir()
        // Best-effort: create the dir up front so call sites that go
        // straight to `appendingPathComponent(...)` + `write(to:)` work
        // without an explicit createDirectory step.
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Human-readable description of which resolution branch fired —
    /// surfaced in Settings → Storage and in the `--diagnostics` output
    /// so users can verify their XDG opt-in actually took effect.
    static let appSupportDirSource: String = {
        let env = ProcessInfo.processInfo.environment
        if let override = env["TROVE_CONFIG_HOME"], !override.isEmpty {
            return "TROVE_CONFIG_HOME=\(override)"
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return "XDG_CONFIG_HOME=\(xdg)/trove"
        }
        if FileManager.default.fileExists(atPath: dotConfigTrovePath()) {
            return "~/.config/trove (XDG default)"
        }
        return "~/Library/Application Support/Trove (macOS native)"
    }()

    /// Public for diagnostics and for the rare caller that needs to know
    /// whether XDG is in play (e.g. the Welcome sheet that explains
    /// where snippets are persisted).
    static var isUsingXDG: Bool {
        let s = appSupportDirSource
        return s.hasPrefix("TROVE_CONFIG_HOME=")
            || s.hasPrefix("XDG_CONFIG_HOME=")
            || s.hasPrefix("~/.config/trove")
    }

    // MARK: - internals

    private static func resolveAppSupportDir() -> URL {
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit Trove override.
        if let override = env["TROVE_CONFIG_HOME"], !override.isEmpty,
           let candidate = sanitize(rawPath: override) {
            return candidate
        }

        // 2. XDG_CONFIG_HOME (append "trove").
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty,
           let base = sanitize(rawPath: xdg) {
            return base.appendingPathComponent("trove", isDirectory: true)
        }

        // 3. ~/.config/trove/ — only honored when the user has actually
        //    created it (presence signals intent). If it doesn't exist,
        //    we DON'T create it speculatively; falling through to the
        //    macOS-native path preserves muscle memory for users who
        //    never asked for XDG.
        let dotConfig = dotConfigTrovePath()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotConfig, isDirectory: &isDir),
           isDir.boolValue {
            return URL(fileURLWithPath: dotConfig, isDirectory: true)
        }

        // 4. macOS-native fallback — the historical Trove location.
        let nativeBase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return nativeBase.appendingPathComponent("Trove", isDirectory: true)
    }

    /// `~/.config/trove` as an absolute filesystem path string.
    private static func dotConfigTrovePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trove", isDirectory: true).path
    }

    /// Reject obviously-unsafe override paths. We allow absolute paths
    /// and `~`-relative paths; we refuse anything that resolves to a
    /// system-critical root or is non-absolute after expansion.
    private static func sanitize(rawPath: String) -> URL? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        // Refuse a handful of obvious "wrong roots" so a mis-set env
        // var (`XDG_CONFIG_HOME=/`) can't drop files at the FS root.
        let rejected: Set<String> = [
            "/", "/etc", "/usr", "/bin", "/sbin", "/var", "/private",
            "/System", "/Library",
        ]
        if rejected.contains(expanded) { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
