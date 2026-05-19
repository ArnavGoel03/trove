// ai_bridge.swift — bridge selected Stage / Notes / Snippet text to a locally-
// installed AI app for rephrase, translate, summarize, etc.
//
// Cuts CommandX ($15/mo) by leveraging apps the user already has installed —
// no API keys, no monthly subscription, no separate auth flow. The user's
// existing Claude / ChatGPT / Cursor desktop app handles the AI; Trove just
// shuttles the selected text + context.
//
// Auto-detects which AI app is installed (Claude.app, ChatGPT.app, then
// browsers as a fallback). User can override via Settings → AI Bridge target.
//
// Wires into:
//   - Stage row context menu ("Send to AI…")
//   - Notes editor context menu
//   - Snippets row context menu
//
// Each entry point passes a SendKind so we can frame the prompt sensibly:
//   .rephrase  → "Rewrite this to be clearer and more concise:\n\n{text}"
//   .translate → "Translate this to English:\n\n{text}"
//   .summarize → "Summarize this in 1-2 sentences:\n\n{text}"
//   .paste     → just the text, user prompts themselves

import AppKit
import Foundation

@MainActor
final class AIBridge {
    static let shared = AIBridge()

    /// What the user is asking the AI to do. Drives the leading instruction.
    enum SendKind {
        case rephrase, translate, summarize, paste
        var instruction: String? {
            switch self {
            case .rephrase:  return "Rewrite this to be clearer and more concise. Return only the rewritten text, no commentary:"
            case .translate: return "Translate this to English. Return only the translation:"
            case .summarize: return "Summarize this in 1–2 sentences:"
            case .paste:     return nil   // raw text, user prompts
            }
        }
    }

    /// Apps we know how to launch, in preference order. We pick the first
    /// installed one; user can override via UserDefaults("trove.ai.bridge.target").
    private static let targets: [(bundleID: String, name: String)] = [
        ("com.anthropic.claudefordesktop",  "Claude"),
        ("com.anthropic.claude",            "Claude"),    // alternate bundle ID
        ("com.openai.chat",                 "ChatGPT"),
        ("com.openai.ChatGPT",              "ChatGPT"),
    ]

    // Fix #13: in-flight guard — prevents double-paste if the user taps "Send" twice.
    private var isSending = false

    private init() {}

    // MARK: - Public API

    /// Send `text` to the configured AI app. Copies a framed prompt to the
    /// pasteboard and brings the AI app to front. User pastes; AI responds.
    func send(_ text: String, kind: SendKind) {
        // Fix #13: bail if a send is already in flight.
        guard !isSending else { return }

        // Fix #11: reject text that would produce an unreasonably large pasteboard write.
        guard text.utf8.count <= 500_000 else {
            SharedStore.stage.flash(
                "Text too large to send (\(text.utf8.count / 1024) KB > 500 KB)",
                kind: .warning
            )
            return
        }

        isSending = true
        let prompt = framed(text: text, kind: kind)
        // Copy to pasteboard (replace prior contents).
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)
        // Fix #12: post the sentinel so ClipHistory doesn't ingest this write.
        NotificationCenter.default.post(name: .troveDidWritePasteboard, object: nil)

        // Find + activate the chosen AI app.
        guard let target = findTarget() else {
            isSending = false
            SharedStore.stage.flash(
                "No AI app installed (Claude or ChatGPT). Install one to use this feature.",
                kind: .warning
            )
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: target.url, configuration: config) { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.isSending = false
                if let error {
                    SharedStore.stage.flash(
                        "Couldn't open \(target.name): \(error.localizedDescription)",
                        kind: .warning
                    )
                } else {
                    SharedStore.stage.flash(
                        "Prompt copied. Paste into \(target.name) (⌘V).",
                        kind: .success
                    )
                }
            }
        }
    }

    /// Returns true when at least one supported AI app is installed. UI uses
    /// this to hide the "Send to AI…" menu when there's nothing to send to.
    func hasInstalledTarget() -> Bool {
        findTarget() != nil
    }

    // MARK: - Internal

    private func framed(text: String, kind: SendKind) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = kind.instruction else { return trimmed }
        return "\(prefix)\n\n\(trimmed)"
    }

    private func findTarget() -> (name: String, url: URL)? {
        // Honor user override if set + still installed.
        if let override = UserDefaults.standard.string(forKey: "trove.ai.bridge.target"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: override) {
            let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? override
            return (name: name, url: url)
        }
        // Otherwise: first installed from the preference list.
        for (bid, name) in Self.targets {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return (name: name, url: url)
            }
        }
        return nil
    }
}

// TODO: wire into context menus across Stage / Notes / Snippets:
//
//   .contextMenu {
//       if AIBridge.shared.hasInstalledTarget() {
//           Section("Send to AI") {
//               Button("Rewrite clearer")   { AIBridge.shared.send(item.text, kind: .rephrase) }
//               Button("Translate to English"){ AIBridge.shared.send(item.text, kind: .translate) }
//               Button("Summarize")          { AIBridge.shared.send(item.text, kind: .summarize) }
//               Divider()
//               Button("Send raw")           { AIBridge.shared.send(item.text, kind: .paste) }
//           }
//       }
//   }
//
// And a "Target" picker in Settings:
//   Picker("AI app target", selection: ...) {
//       ForEach(AIBridge.installedTargets()) { ... }
//   }
