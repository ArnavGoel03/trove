// Trove — pure-Swift auto-installer (no Sparkle, no SPM, no Carthage).
//
// Flow:
//   1. Download Trove.zip from GitHub Releases via URLSession (5-min timeout,
//      200 MB hard cap).
//   2. Verify download is non-empty; optionally check SHA256.
//   3. Unzip to /tmp/trove-update-staging/ via /usr/bin/ditto (handles
//      macOS extended attributes; not plain `unzip`).
//   4. Validate Apple code signature: /usr/bin/codesign --verify --deep
//      --strict --verbose=2 on the extracted .app.
//   5. Detect Mac App Store build; refuse to self-update MAS copies.
//   6. Trash the currently-running .app bundle.
//   7. Move new .app into the original path.
//   8. Re-launch via NSWorkspace.shared.openApplication(at:).
//   9. Terminate the current process.
//
// Wire-up: see TODO at bottom of file.

import AppKit
import Foundation
import CryptoKit
import os

// ===========================================================================
// MARK: - AutoInstaller
// ===========================================================================

@MainActor
final class AutoInstaller: NSObject, URLSessionDownloadDelegate {

    static let shared = AutoInstaller()

    // -----------------------------------------------------------------------
    // MARK: Errors
    // -----------------------------------------------------------------------

    enum InstallError: LocalizedError {
        case downloadFailed(Int)
        case downloadEmpty
        case zipUnpackFailed(String)
        case appNotFound
        case codesignFailed(String)
        case bundleSwapFailed(String)
        case relaunchFailed
        case alreadyInProgress
        case onMacAppStoreBuild
        case invalidDownloadURL
        case versionMismatch(String)
        case foreignBundle(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let code):  return "Download failed (HTTP \(code))"
            case .downloadEmpty:             return "Downloaded file is empty"
            case .zipUnpackFailed(let msg):  return "Failed to unpack zip: \(msg)"
            case .appNotFound:               return "Trove.app not found in the downloaded archive"
            case .codesignFailed(let msg):   return "Code signature invalid: \(msg)"
            case .bundleSwapFailed(let msg): return "Could not swap app bundle: \(msg)"
            case .relaunchFailed:            return "Could not relaunch the updated app"
            case .alreadyInProgress:         return "An update is already in progress"
            case .onMacAppStoreBuild:        return "This copy was installed from the Mac App Store; updates come from there, not here"
            case .invalidDownloadURL:        return "Update URL must be an https://github.com URL"
            case .versionMismatch(let v):    return "Installed bundle reports version \(v), not the expected version — refusing to launch"
            case .foreignBundle(let id):     return "Installed bundle has unexpected identifier \(id) — refusing to launch"
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Published state
    // -----------------------------------------------------------------------

    @Published var progress: Double = 0.0
    @Published var status: String = "Idle"
    @Published var inProgress: Bool = false

    // -----------------------------------------------------------------------
    // MARK: Private
    // -----------------------------------------------------------------------

    private static let maxDownloadBytes: Int64 = 200 * 1024 * 1024  // 200 MB
    private static let downloadTimeout: TimeInterval = 300           // 5 min

    // P0 fix: use per-run UUID-namespaced staging paths instead of fixed /tmp
    // paths so two rapid installs (e.g. double-click of "Install Now") cannot
    // collide on the same file and leave a leaked continuation hanging forever.
    private static func makeStagingDir() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("trove-update-\(UUID().uuidString)", isDirectory: true)
    }
    private static func makeZipTmp(in dir: URL) -> URL {
        dir.appendingPathComponent("trove-update.zip", isDirectory: false)
    }

    // P0 fix: protect downloadContinuation with os_unfair_lock so concurrent
    // delegate callbacks (didFinish / didComplete arriving on different threads)
    // can never double-resume the continuation, which would trap.
    // The lock is `nonisolated(unsafe)` because URLSessionDownloadDelegate
    // callbacks arrive on arbitrary queues (not the @MainActor), yet they need
    // to mutate downloadContinuation atomically.
    nonisolated(unsafe) private var _contLock = os_unfair_lock_s()
    nonisolated(unsafe) private var downloadContinuation: CheckedContinuation<URL, Error>?

    private override init() {}

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Download, verify, swap, and relaunch. Throws on any failure.
    /// On success this method does NOT return — the process exits after
    /// handing off to the new app instance.
    func installUpdate(zipURL: URL, expectedVersion: String) async throws {
        // P0 fix: inProgress guard is the very first op so a double-click on
        // "Install Now" immediately throws on the second call — the first
        // downloadContinuation is never raced or leaked.
        guard !inProgress else { throw InstallError.alreadyInProgress }
        inProgress = true
        defer { inProgress = false }

        // Validate installation directory is writable.
        let bundleURL = Bundle.main.bundleURL
        try assertInstallableLocation(bundleURL)

        // Refuse MAS builds.
        try await assertNotMASBuild(bundleURL)

        // P0 fix: per-run unique staging directory so two rapid invocations
        // can never step on each other's staged files.
        let stagingDir = Self.makeStagingDir()
        let zipTmp = Self.makeZipTmp(in: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Cleanup staging artefacts whether we succeed or fail.
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

        // ── 1. Download ────────────────────────────────────────────────────
        await setStatus("Downloading update…")
        let localZip = try await downloadZip(from: zipURL, stagingDir: stagingDir, zipTmp: zipTmp)

        // ── 2. Size sanity (done inside downloadZip) ───────────────────────

        // ── 3. Unpack ──────────────────────────────────────────────────────
        await setStatus("Unpacking…")
        try await unpackZip(at: localZip, to: stagingDir)

        // ── 4. Locate .app ─────────────────────────────────────────────────
        let newApp = stagingDir.appendingPathComponent("Trove.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw InstallError.appNotFound
        }

        // ── 5. Codesign verify ─────────────────────────────────────────────
        await setStatus("Verifying signature…")
        try await verifyCodesign(appURL: newApp)

        // ── 6 & 7. Trash current, move new ────────────────────────────────
        await setStatus("Installing…")
        try swapAppBundle(currentURL: bundleURL, newURL: newApp)

        // Fix 2: verify swapped bundle reports the expected version (replay attack guard).
        let swappedBundle = Bundle(url: bundleURL)
        let installedVersion = swappedBundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard installedVersion == expectedVersion else {
            throw InstallError.versionMismatch(installedVersion)
        }

        // Fix 3: verify swapped bundle has Trove's bundle identifier (foreign-app guard).
        let installedID = swappedBundle?.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        let currentID   = Bundle.main.bundleIdentifier ?? ""
        guard !currentID.isEmpty, installedID == currentID else {
            throw InstallError.foreignBundle(installedID)
        }

        // ── 8 & 9. Relaunch ────────────────────────────────────────────────
        await setStatus("Relaunching…")
        let destination = bundleURL  // where we just moved the new app
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true

        do {
            try await NSWorkspace.shared.openApplication(at: destination, configuration: cfg)
        } catch {
            throw InstallError.relaunchFailed
        }

        // Brief pause so the new instance has time to start accepting events.
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    // -----------------------------------------------------------------------
    // MARK: Download
    // -----------------------------------------------------------------------

    private func downloadZip(from remoteURL: URL,
                              stagingDir: URL,
                              zipTmp: URL) async throws -> URL {
        // Fix 5: validate URL scheme and host before making any network call.
        guard remoteURL.scheme == "https",
              let host = remoteURL.host,
              host == "github.com" || host.hasSuffix(".github.com")
        else { throw InstallError.invalidDownloadURL }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = Self.downloadTimeout
        config.timeoutIntervalForResource = Self.downloadTimeout
        // The delegate callbacks need to reach us on main; we dispatch to
        // Task.detached internally where needed.
        let session = URLSession(configuration: config,
                                 delegate: self,
                                 delegateQueue: OperationQueue.main)
        defer { session.invalidateAndCancel() }

        let localURL: URL = try await withCheckedThrowingContinuation { cont in
            // P0 fix: serialize continuation assignment under the lock so
            // two concurrent delegate callbacks can't double-resume.
            os_unfair_lock_lock(&_contLock)
            self.downloadContinuation = cont
            os_unfair_lock_unlock(&_contLock)
            let task = session.downloadTask(with: remoteURL)
            task.resume()
        }

        // Move temp download to our known stable path so cleanup is deterministic.
        if localURL != zipTmp {
            try? FileManager.default.removeItem(at: zipTmp)
            try FileManager.default.moveItem(at: localURL, to: zipTmp)
        }

        // P0 fix: verify download size > 0 and within allowed cap before proceeding.
        let attrs = try FileManager.default.attributesOfItem(atPath: zipTmp.path)
        let downloadedSize = (attrs[.size] as? Int64) ?? 0
        guard downloadedSize > 0 else { throw InstallError.downloadEmpty }
        guard downloadedSize <= Self.maxDownloadBytes else {
            throw InstallError.downloadFailed(0)
        }

        return zipTmp
    }

    // -----------------------------------------------------------------------
    // MARK: URLSessionDownloadDelegate
    // -----------------------------------------------------------------------

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Hard cap: abort if the download grows past the limit.
        if totalBytesWritten > AutoInstaller.maxDownloadBytes {
            downloadTask.cancel()
            resumeAndClearContinuation(throwing: InstallError.downloadFailed(0))
            return
        }
        let frac: Double
        if totalBytesExpectedToWrite > 0 {
            frac = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
        } else {
            frac = 0
        }
        Task { @MainActor in
            // Map download to first 80 % of overall progress.
            self.progress = frac * 0.80
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Validate HTTP status before accepting.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            resumeAndClearContinuation(throwing: InstallError.downloadFailed(code))
            return
        }
        // Copy to a stable temp path before URLSession deletes the temp file.
        // We copy (not move) because URLSession owns the temp file's lifetime
        // and may delete it immediately after this callback returns.
        let stable = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trove-dl-stable-\(UUID().uuidString).zip")
        do {
            try FileManager.default.copyItem(at: location, to: stable)
            resumeAndClearContinuation(returning: stable)
        } catch {
            resumeAndClearContinuation(throwing: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let err = error else { return }
        // P0 fix: if the continuation was already resumed (success path), the
        // lock ensures this is a no-op — the nil check is atomic under the lock.
        resumeAndClearContinuation(throwing: err)
    }

    /// P0 fix: atomically consume the continuation under the lock, then resume
    /// it outside the lock. This ensures double-resume is structurally impossible
    /// regardless of which delegate callback arrives first.
    nonisolated private func resumeAndClearContinuation(throwing error: Error) {
        os_unfair_lock_lock(&_contLock)
        let cont = downloadContinuation
        downloadContinuation = nil
        os_unfair_lock_unlock(&_contLock)
        cont?.resume(throwing: error)
    }

    nonisolated private func resumeAndClearContinuation(returning value: URL) {
        os_unfair_lock_lock(&_contLock)
        let cont = downloadContinuation
        downloadContinuation = nil
        os_unfair_lock_unlock(&_contLock)
        cont?.resume(returning: value)
    }

    // -----------------------------------------------------------------------
    // MARK: Unpack
    // -----------------------------------------------------------------------

    private func unpackZip(at zipURL: URL, to dir: URL) async throws {
        // Remove stale staging dir.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let (_, code): (String, Int32) = try await Task.detached {
            runShell("/usr/bin/ditto",
                     ["-xk", zipURL.path, dir.path],
                     timeout: 120)
        }.value

        await MainActor.run { self.progress = 0.90 }
        guard code == 0 else {
            throw InstallError.zipUnpackFailed("ditto exit \(code)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Codesign verification
    // -----------------------------------------------------------------------

    private func verifyCodesign(appURL: URL) async throws {
        let (out, code): (String, Int32) = try await Task.detached {
            runShell("/usr/bin/codesign",
                     ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
                     timeout: 30)
        }.value

        await MainActor.run { self.progress = 0.95 }
        guard code == 0 else {
            let detail = out.isEmpty ? "codesign exited \(code)" : out
            throw InstallError.codesignFailed(detail)
        }

        // Fix 1: verify that the signing authority is a Developer ID Application
        // cert (not a free-tier Apple Development / Mac Developer cert).
        // P1 fix: the previous `"\(escaped)"` quote pattern only escaped `"`
        // — `$` and backticks were still live in the shell string. With Trove
        // installed at `/Applications` the path is trusted, but adversarial
        // paths (e.g. an attacker-controlled `~/Downloads/Trove.app`) could
        // execute arbitrary subshells. Single-quote the path with the POSIX
        // `'\''` close-reopen pattern; that suppresses ALL shell interpolation
        // for arbitrary path content.
        let singleQuoted = Self.posixSingleQuote(appURL.path)
        let (displayOut, _): (String, Int32) = try await Task.detached {
            runShell("/bin/sh",
                     ["-c", "/usr/bin/codesign --display --verbose=4 \(singleQuoted) 2>&1"],
                     timeout: 15)
        }.value

        let hasDevID = displayOut
            .components(separatedBy: .newlines)
            .contains { $0.contains("Authority=Developer ID Application") }
        guard hasDevID else {
            throw InstallError.codesignFailed(
                "Signature must be Developer ID Application (not a free-tier or MAS certificate)"
            )
        }
    }

    /// POSIX-safe single-quote wrap for arbitrary strings embedded in a
    /// `/bin/sh -c "…"` command. Inside single quotes, every character is
    /// literal except `'` itself — so to embed a literal `'` we close the
    /// single-quoted run with `'`, escape the `'` with `\'`, then re-open the
    /// single-quoted run with `'`. The whole compound is `'\''`. Result: a
    /// path containing `$(rm -rf /)` is rendered as the literal seven-char
    /// substring with no shell interpretation. Cheaper and safer than
    /// rewriting to use Process+executableURL+second-Pipe just for stderr.
    nonisolated static func posixSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // -----------------------------------------------------------------------
    // MARK: MAS detection
    // -----------------------------------------------------------------------

    private func assertNotMASBuild(_ appURL: URL) async throws {
        // Fix 4: codesign --display --verbose=4 writes Authority lines to stderr;
        // redirect 2>&1 through /bin/sh so we capture them.
        // P1 fix: see codesign-verify above — single-quote with POSIX escape
        // to suppress shell interpolation of `$`/backtick on adversarial paths.
        let singleQuoted = Self.posixSingleQuote(appURL.path)
        let (out, _): (String, Int32) = try await Task.detached {
            runShell("/bin/sh",
                     ["-c", "/usr/bin/codesign --display --verbose=4 \(singleQuoted) 2>&1"],
                     timeout: 15)
        }.value

        if out.contains("Authority=Apple Mac OS Application Signing") {
            throw InstallError.onMacAppStoreBuild
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Location guard
    // -----------------------------------------------------------------------

    private func assertInstallableLocation(_ bundleURL: URL) throws {
        let path = bundleURL.path
        let allowed = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard allowed else {
            throw InstallError.bundleSwapFailed(
                "Trove must be in /Applications or ~/Applications to self-update"
            )
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Bundle swap
    // -----------------------------------------------------------------------

    private func swapAppBundle(currentURL: URL, newURL: URL) throws {
        let fm = FileManager.default
        // Trash the running bundle. The OS holds the inode; renaming the
        // directory entry is safe while the process is live.
        var trashResult: NSURL?
        do {
            try fm.trashItem(at: currentURL, resultingItemURL: &trashResult)
        } catch {
            throw InstallError.bundleSwapFailed("Could not trash current app: \(error.localizedDescription)")
        }
        // Move the new build into the original path.
        do {
            try fm.moveItem(at: newURL, to: currentURL)
        } catch {
            // Attempt to recover: restore from Trash (best-effort).
            if let trashed = trashResult as URL? {
                try? fm.moveItem(at: trashed, to: currentURL)
            }
            throw InstallError.bundleSwapFailed("Could not move new app into place: \(error.localizedDescription)")
        }
        progress = 1.0
    }

    // -----------------------------------------------------------------------
    // MARK: Private helpers
    // -----------------------------------------------------------------------

    private func setStatus(_ s: String) async {
        await MainActor.run { self.status = s }
    }
}

// TODO: wire this from UpdateChecker — when an update is detected, call
// `try await AutoInstaller.shared.installUpdate(zipURL: ..., expectedVersion: ...)`
// from the "Install Now" button in UpdateCheckerCard.
