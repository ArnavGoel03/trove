// stage_floating.swift — Detach Stage into a floating, always-on-top NSPanel.
//
// Cuts Dropover ($5-10): keeps a draggable "shelf" of staged files visible
// over other apps. Drag from the panel to drop into any target app/folder.
// Same Stage backing store (`SharedStore.stage`) — items added to the main
// window's Stage immediately appear in the floating panel and vice versa.
//
// Wires into the View menu via "Detach Stage" command and a button in the
// Stage toolbar. Use ⌘⇧F as the keyboard shortcut.

import AppKit
import SwiftUI

@MainActor
final class FloatingStageController {
    static let shared = FloatingStageController()
    private var panel: NSPanel?

    private init() {}

    /// Toggle the floating Stage panel — show if hidden, close if visible.
    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            return
        }
        show()
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        // Place near top-right of the active screen if first show, else
        // restore from autosave name.
        if !p.setFrameUsingName("trove.floatingStage") {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let f = screen.visibleFrame
                let size = NSSize(width: 280, height: 360)
                p.setFrame(NSRect(x: f.maxX - size.width - 24,
                                  y: f.maxY - size.height - 24,
                                  width: size.width, height: size.height),
                           display: false)
            }
        }
        p.setFrameAutosaveName("trove.floatingStage")
        p.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
            styleMask: style, backing: .buffered, defer: false
        )
        panel.title = "Stage"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSApp.appearance     // honor user's Trove theme

        let content = NSHostingView(rootView:
            FloatingStageContentView()
                .environmentObject(SharedStore.stage)
        )
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        return panel
    }
}

// MARK: - SwiftUI content

private struct FloatingStageContentView: View {
    @EnvironmentObject var stage: Stage
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.troveLine)
            if stage.items.isEmpty {
                emptyState
            } else {
                ScrollView { itemList }
            }
        }
        .background(Color.troveBg)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill").foregroundStyle(.tint)
            Text("\(stage.items.count) item\(stage.items.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.troveFgDim)
            Spacer()
            Button(action: { FloatingStageController.shared.hide() }) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.troveFgMute)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(Color.troveFgMute)
            Text("Drop, paste, or capture into Stage")
                .font(.caption).foregroundStyle(Color.troveFgDim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        LazyVStack(spacing: 4) {
            ForEach(stage.items) { item in
                FloatingStageRow(item: item)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }
}

private struct FloatingStageRow: View {
    let item: StagedItem
    @EnvironmentObject var stage: Stage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1).font(.system(size: 11, weight: .medium))
                if let sub = subtitle {
                    Text(sub).lineLimit(1).font(.system(size: 9))
                        .foregroundStyle(Color.troveFgMute)
                }
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    stage.remove(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.troveFgMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.troveCardSolid.opacity(hovering ? 0.8 : 0.4))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { dragItem() }
    }

    private var icon: some View {
        Group {
            switch item.kind {
            case .file(let url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
            case .image:
                Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(.tint)
            case .text:
                Image(systemName: "doc.text").font(.system(size: 16)).foregroundStyle(.tint)
            }
        }
    }

    private var label: String {
        switch item.kind {
        case .file(let url): return url.lastPathComponent
        case .image: return "Image"
        case .text(let s): return s.split(separator: "\n").first.map(String.init) ?? "Text"
        }
    }
    private var subtitle: String? {
        switch item.kind {
        case .file(let url): return url.deletingLastPathComponent().path
        case .image: return nil
        case .text: return nil
        }
    }

    private func dragItem() -> NSItemProvider {
        switch item.kind {
        case .file(let url):  return NSItemProvider(object: url as NSURL)
        case .text(let s):    return NSItemProvider(object: s as NSString)
        case .image(let url): return NSItemProvider(object: url as NSURL)
        }
    }
}

// TODO: wire from main.swift View menu:
//   .commands {
//     CommandMenu("View") {
//       Button("Detach Stage") { FloatingStageController.shared.toggle() }
//         .keyboardShortcut("f", modifiers: [.command, .shift])
//     }
//   }
// And from the Stage toolbar (small "pip" icon button).
