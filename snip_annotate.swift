// ===========================================================================
// MARK: - Snip Annotation — CleanShot-style overlay tools
// ===========================================================================
//
// Provides: SnipAnnotation enum, SnipAnnotationCanvas, AnnotationToolbar,
// SnipAnnotationEditor, and SnipAnnotationModel.
//
// Usage flow: capture → SnipAnnotationEditor → commit → annotated NSImage
// used for save / stage. Skipping the editor is always valid (no annotation
// path unchanged).
//
// Blur note: live preview uses a translucent gray placeholder for perf.
// Final composite applies CIFilter.gaussianBlur to the cropped region.

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// ===========================================================================
// MARK: - SnipAnnotation enum
// ===========================================================================

enum SnipAnnotation: Identifiable {
    case arrow(id: UUID = UUID(), start: CGPoint, end: CGPoint, color: NSColor)
    case rectangle(id: UUID = UUID(), rect: CGRect, color: NSColor, strokeWidth: CGFloat)
    case highlight(id: UUID = UUID(), rect: CGRect, color: NSColor)
    case blur(id: UUID = UUID(), rect: CGRect, radius: CGFloat)
    case text(id: UUID = UUID(), rect: CGRect, content: String, color: NSColor, fontSize: CGFloat)

    var id: UUID {
        switch self {
        case .arrow(let id, _, _, _):           return id
        case .rectangle(let id, _, _, _):       return id
        case .highlight(let id, _, _):          return id
        case .blur(let id, _, _):               return id
        case .text(let id, _, _, _, _):         return id
        }
    }
}

// ===========================================================================
// MARK: - AnnotationTool
// ===========================================================================

enum AnnotationTool: String, CaseIterable, Identifiable {
    case pointer, arrow, rectangle, highlight, blur, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pointer:   return "Select"
        case .arrow:     return "Arrow"
        case .rectangle: return "Rectangle"
        case .highlight: return "Highlight"
        case .blur:      return "Blur"
        case .text:      return "Text"
        }
    }
    var symbol: String {
        switch self {
        case .pointer:   return "cursorarrow"
        case .arrow:     return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .highlight: return "highlighter"
        case .blur:      return "aqi.medium"
        case .text:      return "textformat"
        }
    }
}

// ===========================================================================
// MARK: - SnipAnnotationModel
// ===========================================================================

@MainActor
final class SnipAnnotationModel: ObservableObject {
    @Published var image: NSImage
    @Published var annotations: [SnipAnnotation] = []
    @Published var currentTool: AnnotationTool = .arrow
    @Published var currentColor: NSColor = .systemRed
    @Published var currentStrokeWidth: CGFloat = 3
    @Published var currentFontSize: CGFloat = 18
    @Published var blurRadius: CGFloat = 10

    // P1: commit progress flag — shown in the editor while background render runs.
    @Published var isCommitting: Bool = false

    // Fix #2: shared CIContext to avoid creating one per blur render.
    private lazy var ciContext = CIContext(options: nil)

    // Undo stack: each entry is a snapshot of the annotations array.
    // Capped at 20 states.
    private var undoStack: [[SnipAnnotation]] = []
    // P1: redo stack — parallel to undoStack.
    private var redoStack: [[SnipAnnotation]] = []
    private let maxUndoDepth = 20

    init(image: NSImage) {
        self.image = image
    }

    func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        // P1: any new action clears the redo stack (standard undo model).
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        // P1: push current state onto redo before reverting.
        redoStack.append(annotations)
        annotations = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func addAnnotation(_ ann: SnipAnnotation) {
        pushUndo()
        annotations.append(ann)
    }

    /// P1: commit() runs the full-resolution lockFocus render on a background
    /// thread to avoid blocking the main actor for large images. Calls
    /// completion on MainActor when done.
    func commitAsync(completion: @escaping @MainActor (NSImage) -> Void) {
        isCommitting = true
        let img = image
        let anns = annotations
        Task.detached(priority: .userInitiated) {
            let result = Self.renderSync(image: img, annotations: anns)
            await MainActor.run { [weak self] in
                self?.isCommitting = false
                completion(result)
            }
        }
    }

    /// Synchronous render — must be called off-main for large images.
    /// `nonisolated` so it's reachable from Task.detached even though the
    /// enclosing type is @MainActor; it only touches NSImage/CG which are
    /// thread-safe for the read-only operations we perform here.
    nonisolated private static func renderSync(image: NSImage, annotations: [SnipAnnotation]) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        // Draw base image.
        image.draw(in: NSRect(origin: .zero, size: size))

        // P1: snapshot the base CGImage *once* before drawing any annotations.
        // drawBlurRegion previously called ctx.makeImage() per blur region,
        // which re-snapped the entire bitmap each time — O(n) for n blurs.
        // Snapping once and reusing cuts that to O(1).
        let ctx = NSGraphicsContext.current?.cgContext
        let baseSnapshot = ctx?.makeImage()
        let bounds = NSRect(origin: .zero, size: size)

        for ann in annotations {
            drawAnnotation(ann, in: bounds, ctx: ctx, baseSnapshot: baseSnapshot)
        }
        return result
    }

    // Keep the old synchronous commit() as a convenience wrapper for callers
    // that don't need async (e.g. the test path). It runs on main and is only
    // safe for small images.
    func commit() -> NSImage {
        Self.renderSync(image: image, annotations: annotations)
    }

    nonisolated private static func drawAnnotation(_ ann: SnipAnnotation, in bounds: NSRect,
                                        ctx: CGContext?,
                                        baseSnapshot: CGImage?) {
        switch ann {
        case .arrow(_, let start, let end, let color):
            drawArrow(from: start, to: end, color: color, lineWidth: 3)

        case .rectangle(_, let rect, let color, let strokeWidth):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = strokeWidth
            path.stroke()

        case .highlight(_, let rect, let color):
            // P1: use the stored color (was hardcoded to systemYellow in
            // some callers; here we respect whatever was passed in).
            color.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: rect).fill()

        case .blur(_, let rect, let radius):
            drawBlurRegion(rect: rect, radius: radius, in: bounds,
                           ctx: ctx, baseSnapshot: baseSnapshot)

        case .text(_, let rect, let content, let color, let fontSize):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color
            ]
            NSAttributedString(string: content, attributes: attrs).draw(in: rect)
        }
    }

    nonisolated private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                   color: NSColor, lineWidth: CGFloat) {
        guard start != end else { return }
        color.setStroke()
        color.setFill()

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()

        // Arrowhead.
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen: CGFloat = max(12, lineWidth * 4)
        let headAngle: CGFloat = .pi / 6
        let p1 = CGPoint(x: end.x - headLen * cos(angle - headAngle),
                         y: end.y - headLen * sin(angle - headAngle))
        let p2 = CGPoint(x: end.x - headLen * cos(angle + headAngle),
                         y: end.y - headLen * sin(angle + headAngle))
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: p1)
        head.line(to: p2)
        head.close()
        head.fill()
    }

    nonisolated private static func drawBlurRegion(rect: CGRect, radius: CGFloat, in bounds: NSRect,
                                        ctx: CGContext?, baseSnapshot: CGImage?) {
        guard rect.width > 0, rect.height > 0 else { return }
        // P1: use the pre-captured baseSnapshot instead of calling ctx.makeImage()
        // here — avoids a full-resolution snapshot per blur region (was O(n)).
        guard let ctx = ctx,
              let snapped = baseSnapshot else {
            // Fallback: translucent gray.
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: rect).fill()
            return
        }

        // P1 hardening: guard BOTH sides of the ratio. bounds.width can be 0 in
        // the first SwiftUI layout pass before GeometryReader fires; CGFloat/0
        // produces inf, which then poisons every downstream coordinate calculation.
        let scale: CGFloat = (snapped.width > 0 && bounds.width > 0)
            ? CGFloat(snapped.width) / bounds.width
            : 1
        let cropRect = CGRect(x: rect.minX * scale,
                              y: rect.minY * scale,
                              width: rect.width * scale,
                              height: rect.height * scale)
        guard let cropped = snapped.cropping(to: cropRect) else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: rect).fill()
            return
        }

        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = ciImage
        filter.radius = Float(radius)
        // Use a thread-local CIContext rather than the MainActor lazy one
        // because renderSync is called from a background Task.
        let bgContext = CIContext(options: nil)
        guard let output = filter.outputImage,
              let ciCtx = bgContext.createCGImage(output, from: ciImage.extent) else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: rect).fill()
            return
        }
        ctx.draw(ciCtx, in: rect)
    }
}

// ===========================================================================
// MARK: - SnipAnnotationCanvas
// ===========================================================================

struct SnipAnnotationCanvas: View {
    @ObservedObject var model: SnipAnnotationModel
    // In-progress drag state (canvas-display coordinates).
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var textInput: String = ""
    @State private var showTextPrompt = false
    @State private var pendingTextRect: CGRect? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Base image.
                Image(nsImage: model.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                // Committed annotations.
                Canvas { ctx, size in
                    let scale = canvasScale(geo: geo)
                    for ann in model.annotations {
                        drawAnnotationInCanvas(ctx: ctx, ann: ann, scale: scale)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)

                // In-progress annotation preview.
                // Fix #1: pass geoSize so makePreviewAnnotation can convert to
                // image-pixel space before handing off to drawAnnotationInCanvas,
                // which then re-scales back to canvas-display space. Without the
                // conversion, the preview appeared at 2× the cursor position on
                // a 2x-scale (Retina) canvas.
                if let start = dragStart, let current = dragCurrent,
                   model.currentTool != .pointer {
                    Canvas { ctx, size in
                        let scale = canvasScale(geo: geo)
                        if let preview = makePreviewAnnotation(start: start,
                                                               current: current,
                                                               geoSize: geo.size) {
                            drawAnnotationInCanvas(ctx: ctx, ann: preview, scale: scale)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { val in
                        if dragStart == nil { dragStart = val.startLocation }
                        dragCurrent = val.location
                    }
                    .onEnded { val in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard model.currentTool != .pointer else { return }
                        let start = val.startLocation
                        let end = val.location
                        commitDrag(start: start, end: end, geoSize: geo.size)
                    }
            )
        }
        .sheet(isPresented: $showTextPrompt) {
            textPromptSheet
        }
    }

    // MARK: - Commit drag

    private func commitDrag(start: CGPoint, end: CGPoint, geoSize: CGSize) {
        let imgSize = model.image.size
        guard imgSize.width > 0, imgSize.height > 0, geoSize.width > 0, geoSize.height > 0 else { return }
        let sx = imgSize.width / geoSize.width
        let sy = imgSize.height / geoSize.height

        func toImg(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        func toImgRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            let minX = min(a.x, b.x) * sx
            let minY = min(a.y, b.y) * sy
            let w = abs(b.x - a.x) * sx
            let h = abs(b.y - a.y) * sy
            return CGRect(x: minX, y: minY, width: w, height: h)
        }

        switch model.currentTool {
        case .pointer:
            break
        case .arrow:
            model.addAnnotation(.arrow(start: toImg(start), end: toImg(end),
                                       color: model.currentColor))
        case .rectangle:
            let rect = toImgRect(start, end)
            guard rect.width > 2, rect.height > 2 else { return }
            model.addAnnotation(.rectangle(rect: rect, color: model.currentColor,
                                           strokeWidth: model.currentStrokeWidth))
        case .highlight:
            let rect = toImgRect(start, end)
            guard rect.width > 2, rect.height > 2 else { return }
            // P1: use model.currentColor instead of hardcoded systemYellow.
            model.addAnnotation(.highlight(rect: rect,
                                           color: model.currentColor))
        case .blur:
            let rect = toImgRect(start, end)
            guard rect.width > 4, rect.height > 4 else { return }
            model.addAnnotation(.blur(rect: rect, radius: model.blurRadius))
        case .text:
            let rect = toImgRect(start, end)
            guard rect.width > 4 else { return }
            pendingTextRect = rect
            showTextPrompt = true
        }
    }

    // MARK: - Text prompt sheet

    private var textPromptSheet: some View {
        VStack(spacing: 16) {
            Text("Enter annotation text")
                .headerText()
            TextField("Text…", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit { commitText() }
            HStack {
                Button("Cancel") {
                    showTextPrompt = false
                    textInput = ""
                    pendingTextRect = nil
                }
                Spacer()
                Button("Add") { commitText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(textInput.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 340)
    }

    private func commitText() {
        guard let rect = pendingTextRect, !textInput.isEmpty else {
            showTextPrompt = false
            textInput = ""
            return
        }
        model.addAnnotation(.text(rect: rect, content: textInput,
                                  color: model.currentColor,
                                  fontSize: model.currentFontSize))
        showTextPrompt = false
        textInput = ""
        pendingTextRect = nil
    }

    // MARK: - Canvas drawing helpers

    private func canvasScale(geo: GeometryProxy) -> CGSize {
        let imgSize = model.image.size
        guard imgSize.width > 0, imgSize.height > 0,
              geo.size.width > 0, geo.size.height > 0 else { return .init(width: 1, height: 1) }
        return CGSize(width: geo.size.width / imgSize.width,
                      height: geo.size.height / imgSize.height)
    }

    // Fix #1: convert drag coordinates (canvas-display space) to image-pixel
    // space before building the preview annotation. drawAnnotationInCanvas then
    // re-applies the canvas scale, so the round-trip lands at exactly the
    // cursor position on screen — no double-scale.
    private func makePreviewAnnotation(start: CGPoint, current: CGPoint,
                                       geoSize: CGSize) -> SnipAnnotation? {
        let imgSize = model.image.size
        guard imgSize.width > 0, imgSize.height > 0,
              geoSize.width > 0, geoSize.height > 0 else { return nil }
        let sx = imgSize.width / geoSize.width
        let sy = imgSize.height / geoSize.height
        func toImg(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        func toImgRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x) * sx, y: min(a.y, b.y) * sy,
                   width: abs(b.x - a.x) * sx, height: abs(b.y - a.y) * sy)
        }

        switch model.currentTool {
        case .pointer: return nil
        case .arrow:
            return .arrow(start: toImg(start), end: toImg(current), color: model.currentColor)
        case .rectangle:
            let rect = toImgRect(start, current)
            return .rectangle(rect: rect, color: model.currentColor,
                              strokeWidth: model.currentStrokeWidth)
        case .highlight:
            // P1: preview uses model.currentColor (was hardcoded systemYellow).
            return .highlight(rect: toImgRect(start, current), color: model.currentColor)
        case .blur:
            // Preview blur as translucent gray (no live CI for perf).
            return .highlight(rect: toImgRect(start, current),
                              color: NSColor.gray.withAlphaComponent(0.6))
        case .text:
            return .rectangle(rect: toImgRect(start, current),
                              color: model.currentColor.withAlphaComponent(0.5),
                              strokeWidth: 1.5)
        }
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func drawAnnotationInCanvas(ctx: GraphicsContext, ann: SnipAnnotation, scale: CGSize) {
        switch ann {
        case .arrow(_, let start, let end, let color):
            let s = CGPoint(x: start.x * scale.width, y: start.y * scale.height)
            let e = CGPoint(x: end.x * scale.width, y: end.y * scale.height)
            drawCanvasArrow(ctx: ctx, from: s, to: e, color: Color(color), lineWidth: 3)

        case .rectangle(_, let rect, let color, let strokeWidth):
            let scaled = CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height,
                                width: rect.width * scale.width, height: rect.height * scale.height)
            ctx.stroke(Path(roundedRect: scaled, cornerRadius: 2),
                       with: .color(Color(color)), lineWidth: strokeWidth)

        case .highlight(_, let rect, let color):
            let scaled = CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height,
                                width: rect.width * scale.width, height: rect.height * scale.height)
            ctx.fill(Path(scaled), with: .color(Color(color).opacity(0.3)))

        case .blur(_, let rect, _):
            // Preview: translucent gray box (live blur deferred to commit()).
            let scaled = CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height,
                                width: rect.width * scale.width, height: rect.height * scale.height)
            ctx.fill(Path(scaled), with: .color(.gray.opacity(0.45)))
            ctx.stroke(Path(scaled), with: .color(.gray), lineWidth: 1)

        case .text(_, let rect, let content, let color, let fontSize):
            let scaled = CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height,
                                width: rect.width * scale.width, height: rect.height * scale.height)
            ctx.draw(Text(content)
                .font(.system(size: fontSize * min(scale.width, scale.height),
                              weight: .semibold))
                .foregroundColor(Color(color)),
                in: scaled)
        }
    }

    private func drawCanvasArrow(ctx: GraphicsContext, from start: CGPoint,
                                  to end: CGPoint, color: Color, lineWidth: CGFloat) {
        guard start != end else { return }
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen: CGFloat = max(12, lineWidth * 4)
        let headAngle: CGFloat = .pi / 6
        let p1 = CGPoint(x: end.x - headLen * cos(angle - headAngle),
                         y: end.y - headLen * sin(angle - headAngle))
        let p2 = CGPoint(x: end.x - headLen * cos(angle + headAngle),
                         y: end.y - headLen * sin(angle + headAngle))
        var head = Path()
        head.move(to: end)
        head.addLine(to: p1)
        head.addLine(to: p2)
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }
}

// ===========================================================================
// MARK: - AnnotationToolbar
// ===========================================================================

struct AnnotationToolbar: View {
    @ObservedObject var model: SnipAnnotationModel
    // P2: ReduceTransparency fallback for toolbar material.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let colorPresets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .white, .black
    ]

    var body: some View {
        HStack(spacing: 10) {
            // Tool buttons.
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    model.currentTool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.currentTool == tool
                              ? Color.accentColor.opacity(0.2)
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(model.currentTool == tool
                                      ? Color.accentColor : Color.clear,
                                      lineWidth: 1.2)
                )
                .help(tool.label)
                // P2: accessibility label for tool buttons.
                .accessibilityLabel(tool.label)
            }

            Divider().frame(height: 22)

            // Color presets.
            ForEach(colorPresets, id: \.self) { color in
                Button {
                    model.currentColor = color
                } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                model.currentColor == color
                                    ? Color.primary : Color.clear,
                                lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .help(color.colorNameForDisplay)
                // P2: accessibility label for color preset buttons.
                .accessibilityLabel("\(color.colorNameForDisplay) color")
            }

            Divider().frame(height: 22)

            // Undo.
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .help("Undo (⌘Z)")
            .keyboardShortcut("z", modifiers: [.command])
            .accessibilityLabel("Undo")

            // P1: redo button — mirrors undo, stack cleared on new action.
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .help("Redo (⌘⇧Z)")
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // P2: solid background when Reduce Transparency is on.
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color.troveCardSolid)
                : AnyShapeStyle(.ultraThinMaterial)
        )
    }
}

// A lightweight display-name helper — avoids importing Color name tables.
private extension NSColor {
    var colorNameForDisplay: String {
        if self == .systemRed { return "Red" }
        if self == .systemOrange { return "Orange" }
        if self == .systemYellow { return "Yellow" }
        if self == .systemGreen { return "Green" }
        if self == .systemBlue { return "Blue" }
        if self == .white { return "White" }
        if self == .black { return "Black" }
        return "Color"
    }
}

// ===========================================================================
// MARK: - SnipAnnotationEditor
// ===========================================================================

struct SnipAnnotationEditor: View {
    @StateObject private var model: SnipAnnotationModel
    let onCommit: (NSImage) -> Void
    let onCancel: () -> Void

    // Fix #4: gate dismiss behind a confirmation when annotations exist.
    @State private var confirmDiscard = false

    init(image: NSImage, onCommit: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SnipAnnotationModel(image: image))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar.
            AnnotationToolbar(model: model)
                .frame(maxWidth: .infinity)

            Divider()

            // Canvas.
            SnipAnnotationCanvas(model: model)
                .background(Color.black.opacity(0.08))
                .frame(minWidth: 400, minHeight: 300)

            Divider()

            // Bottom action row.
            HStack {
                Button("Cancel") { requestCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.isCommitting)
                Spacer()
                if model.isCommitting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.currentTool.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // P1: use async commit to avoid blocking the main thread on
                // large full-resolution images.
                Button("Done") {
                    model.commitAsync { annotated in
                        onCommit(annotated)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isCommitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(minWidth: 600, minHeight: 500)
        .confirmationDialog(
            "Discard \(model.annotations.count) annotation\(model.annotations.count == 1 ? "" : "s")?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { onCancel() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your annotations will be lost.")
        }
    }

    private func requestCancel() {
        if model.annotations.isEmpty {
            onCancel()
        } else {
            confirmDiscard = true
        }
    }
}
