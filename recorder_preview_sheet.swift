// Trove — Recorder preview sheet (power-user item #17).
//
// Auto-pops a modal sheet immediately after a recording finishes,
// hosting an AVPlayer-backed preview of the clip plus the same set of
// actions the last-recording row exposes (Save / Save to Downloads /
// Send to Stage / Re-record / Reveal / Copy Path / Drag). Mimics what
// Loom and CleanShot do at stop-time so the user can sanity-check the
// take without alt-tabbing to Finder.
//
// Why a sheet and not a new window: a sheet attaches to the Trove
// window's lifecycle, dismisses with the keyboard (Esc + ⌘W), and
// can't get orphaned behind another app. We get focus and modal-ish
// behavior for free without managing a separate NSWindow.

import SwiftUI
import AVKit
import AppKit

/// Hosts AVKit's `AVPlayerView` inside SwiftUI. We use the AppKit
/// `AVPlayerView` (not the SwiftUI `VideoPlayer`) for two reasons:
///   • Native controls — same chrome the user sees in Quick Look /
///     QuickTime, including scrubber, audio toggle, fullscreen.
///   • Cheaper layer hosting on big H.264 / HEVC frames.
struct RecPreviewPlayer: NSViewRepresentable {
    let url: URL
    let onPlayerReady: ((AVPlayer) -> Void)?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        // (macOS 14+ has `videoFrameAnalysisTypes` to opt out of Live Text /
        // subject lift — left at default on 13 where the API doesn't exist.)
        // Start playing immediately — the user just stopped recording,
        // they obviously want to see the result.
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        v.player = player
        onPlayerReady?(player)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        // Reuse the existing player when only the surrounding sheet redraws.
        if let cur = (v.player?.currentItem?.asset as? AVURLAsset)?.url, cur == url {
            return
        }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        v.player = player
        onPlayerReady?(player)
    }
}

/// The sheet content. Owns the player observation that lights up the
/// duration / play-position chip in the header. Action handlers route
/// through RecSaver and SharedStore.stage so behavior matches the
/// last-recording-row affordances and we don't fork the persistence
/// path.
struct RecPreviewSheet: View {
    let url: URL
    let durationHint: TimeInterval       // engine.elapsed at stop
    let sentToStage: Bool                // already auto-routed?
    var onClose: () -> Void
    var onReRecord: () -> Void

    @State private var player: AVPlayer?
    @State private var positionText: String = "0:00"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RecPreviewPlayer(url: url) { p in
                self.player = p
                p.play()
            }
            .frame(minWidth: 640, minHeight: 360)
            .background(Color.black)
            Divider()
            actions
        }
        .frame(width: 720, height: 520)
        .onAppear {
            startObservingPosition()
        }
        .onDisappear {
            player?.pause()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(RecMeta.duration(durationHint))
                    Text("·")
                    Text(positionText)
                        .monospacedDigit()
                    if sentToStage {
                        Text("·")
                        Label("In Stage", systemImage: "tray.full.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close preview (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                RecSaver.save(url)
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button {
                RecSaver.quickSaveToDownloads(url)
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            .keyboardShortcut("d", modifiers: [.command])
            .controlSize(.large)

            Button {
                SharedStore.stage.addFile(url)
                SharedStore.stage.flash("Sent to Stage")
            } label: {
                Label("Stage", systemImage: "tray.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(sentToStage)
            .help(sentToStage
                  ? "Already added to Stage when the recording stopped."
                  : "Add the recording to Stage so you can drag it into another app.")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .controlSize(.large)

            Spacer()

            Button(role: .destructive) {
                onReRecord()
            } label: {
                Label("Re-record", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .help("Move this take to the Trash and start a fresh recording with the same settings.")

            Button {
                onClose()
            } label: {
                Text("Done")
                    .frame(minWidth: 60)
            }
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func startObservingPosition() {
        guard let player else { return }
        let interval = CMTime(value: 1, timescale: 4)   // 4 Hz
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let s = CMTimeGetSeconds(time)
            guard s.isFinite, s >= 0 else { return }
            positionText = RecMeta.duration(TimeInterval(s))
        }
    }
}
