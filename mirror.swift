// mirror.swift — webcam preview pane (Hand Mirror replacement).
//
// Cuts Hand Mirror ($5): show the front camera feed in a Trove pane and
// optionally in a floating always-on-top panel. Pure AVFoundation — no
// recording, no upload, no analytics. Camera shuts off on pane disappear.

import SwiftUI
import AppKit
import AVFoundation

// ===========================================================================
// MARK: - Mirror floating NSPanel (always-on-top)
// ===========================================================================

/// Lightweight floating panel that hosts the mirror preview at a fixed 16:9
/// aspect ratio. `level = .floating` keeps it above all regular windows.
private final class MirrorFloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .resizable, .utilityWindow,
                        .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level               = .floating
        title               = "Mirror"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize             = NSSize(width: 160, height: 90)
        maxSize             = NSSize(width: 960, height: 540)
        backgroundColor     = .black
    }
}

/// Wrapper that owns the panel instance so SwiftUI can open / close it.
@MainActor
private final class MirrorFloatingPanelController: ObservableObject {
    @Published private(set) var isOpen = false
    private var panel: MirrorFloatingPanel?
    // P1 fix: store the willClose observer token. The block-based addObserver
    // overload returns an opaque token that's the ONLY way to remove the
    // observer later. Without storing it, every open/close cycle permanently
    // accumulates a dead observer + its captured closure — an unbounded leak
    // for users who toggle the panel often.
    private var willCloseObserver: NSObjectProtocol?

    func open(vm: MirrorViewModel) {
        guard panel == nil || !isOpen else { panel?.makeKeyAndOrderFront(nil); return }
        let p = MirrorFloatingPanel()
        let preview = MirrorPreviewView(vm: vm)
            .ignoresSafeArea()
        let hosting = NSHostingView(rootView: preview)
        p.contentView = hosting
        if let screen = NSScreen.main {
            let sr = screen.visibleFrame
            let px = sr.maxX - p.frame.width - 24
            let py = sr.maxY - p.frame.height - 24
            p.setFrameOrigin(NSPoint(x: px, y: py))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p
        isOpen = true
        // Observe close so isOpen reflects reality. Hold the token so a
        // subsequent close() can take it down deterministically.
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isOpen = false }
        }
    }

    func close() {
        if let obs = willCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            willCloseObserver = nil
        }
        panel?.close()
        isOpen = false
    }

    deinit {
        if let obs = willCloseObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func toggle(vm: MirrorViewModel) {
        if isOpen { close() } else { open(vm: vm) }
    }
}

@MainActor
final class MirrorViewModel: ObservableObject {
    @Published var isActive = false
    @Published var permissionDenied = false
    @Published var deviceID: String?            // user-selected camera UID
    @Published var availableDevices: [AVCaptureDevice] = []

    private(set) var session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?

    // Fix #6: serial queue prevents stop/start races when the camera Picker
    // changes rapidly (stop on .utility can otherwise be overtaken by start on
    // .userInitiated before the session is fully torn down).
    private let sessionQueue = DispatchSerialQueue(label: "trove.mirror.session",
                                                   qos: .userInitiated)

    // P1: guard flag — set true during stop/start transition so rapid Picker
    // changes don't queue overlapping configureAndStart() calls.
    private var isConfiguring = false

    // Fix #7: runtime-error observer (USB camera unplugged, etc.)
    private var runtimeErrorObserver: NSObjectProtocol?
    // Fix #5: re-activation observer — re-checks permission after user visits System Settings.
    private var activationObserver: NSObjectProtocol?

    init() {
        // Fix #7: observe AVCaptureSession runtime errors (e.g. USB unplug).
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureAndStart()
            }
        }

        // Fix #5: re-check camera permission when Trove comes back to foreground.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.permissionDenied else { return }
                if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                    self.permissionDenied = false
                    self.configureAndStart()
                }
            }
        }
    }

    deinit {
        if let o = runtimeErrorObserver { NotificationCenter.default.removeObserver(o) }
        if let o = activationObserver   { NotificationCenter.default.removeObserver(o) }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                Task { @MainActor in
                    if ok { self?.configureAndStart() }
                    else  { self?.permissionDenied = true }
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    func stop() {
        isActive = false
        // Fix #6: stop synchronously on the serial session queue so a
        // subsequent start() (also dispatched to the same queue) cannot begin
        // until the prior stopRunning() completes.
        let s = session
        sessionQueue.async { s.stopRunning() }
    }

    /// Debounced camera-switch: drop rapid calls while a configuration is in
    /// flight to avoid overlapping AVCaptureSession mutations.
    func switchDevice(to uid: String) {
        guard !isConfiguring else { return }
        deviceID = uid
        stop()
        start()
    }

    /// Capture a still from the current preview frame → copy to clipboard /
    /// save / send to Stage. Must be called on MainActor (layer tree is
    /// main-thread-only). Calls completion on main.
    func snapshot(completion: @escaping (NSImage?) -> Void) {
        // Render the preview layer on the main thread (already guaranteed
        // by @MainActor on this function).
        let img = MirrorSnapshotHelper.grabFromPreviewLayer(session: session)
        completion(img)
    }

    private func configureAndStart() {
        // P1 debounce: if already mid-configuration, skip to avoid overlapping
        // beginConfiguration/commitConfiguration calls on the same session.
        guard !isConfiguring else { return }
        isConfiguring = true
        permissionDenied = false
        refreshDeviceList()
        guard let device = pickDevice() else {
            isConfiguring = false
            return
        }
        // Fix #6: all session mutations run on the serial sessionQueue.
        let s = session
        let prevInput = currentInput
        sessionQueue.async {
            s.beginConfiguration()
            if let prev = prevInput { s.removeInput(prev) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if s.canAddInput(input) {
                    s.addInput(input)
                    Task { @MainActor [weak self] in self?.currentInput = input }
                }
            } catch {
                s.commitConfiguration()
                Task { @MainActor [weak self] in self?.isConfiguring = false }
                return
            }
            s.sessionPreset = .high
            s.commitConfiguration()
            s.startRunning()
            Task { @MainActor [weak self] in
                self?.isActive = true
                self?.isConfiguring = false
            }
        }
    }

    private func refreshDeviceList() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external, .builtInWideAngleCamera] }
        else                          { types = [.externalUnknown, .builtInWideAngleCamera] }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        availableDevices = session.devices
    }

    private func pickDevice() -> AVCaptureDevice? {
        if let uid = deviceID,
           let dev = availableDevices.first(where: { $0.uniqueID == uid }) {
            return dev
        }
        // Default to built-in front camera if available, else first.
        return availableDevices.first(where: { $0.position == .front })
            ?? availableDevices.first
            ?? AVCaptureDevice.default(for: .video)
    }
}

// ===========================================================================
// MARK: - Snapshot helper
// ===========================================================================

private enum MirrorSnapshotHelper {
    /// Grab the current video frame by rendering the AVCaptureVideoPreviewLayer
    /// into a bitmap. Must be called on the main thread (layer tree is
    /// main-thread-only).
    static func grabFromPreviewLayer(session: AVCaptureSession) -> NSImage? {
        // Find the NSView hosting the preview layer — iterate all windows.
        for win in NSApp.windows {
            if let img = snapshotPreviewLayer(in: win.contentView, session: session) {
                return img
            }
        }
        return nil
    }

    private static func snapshotPreviewLayer(in view: NSView?,
                                             session: AVCaptureSession) -> NSImage? {
        guard let view = view else { return nil }
        // Check this view's layer.
        if let pl = view.layer as? AVCaptureVideoPreviewLayer,
           pl.session === session {
            return renderLayer(pl)
        }
        // Recurse into subviews.
        for sub in view.subviews {
            if let found = snapshotPreviewLayer(in: sub, session: session) {
                return found
            }
        }
        return nil
    }

    private static func renderLayer(_ layer: AVCaptureVideoPreviewLayer) -> NSImage? {
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = layer.contentsScale > 0 ? layer.contentsScale : 2.0
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return nil }

        // Render into an offscreen bitmap.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: bounds.size)
    }
}

// ===========================================================================
// MARK: - Preview NSView / NSViewRepresentable
// ===========================================================================

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer.
struct MirrorPreviewView: NSViewRepresentable {
    @ObservedObject var vm: MirrorViewModel

    func makeNSView(context: Context) -> MirrorPreviewNSView {
        let v = MirrorPreviewNSView()
        v.wantsLayer = true
        v.previewLayer.session = vm.session
        v.previewLayer.videoGravity = .resizeAspect
        // Mirror horizontally — Hand Mirror's killer UX detail (selfie-style).
        v.previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        return v
    }
    func updateNSView(_ v: MirrorPreviewNSView, context: Context) {
        v.previewLayer.session = vm.session
    }
}

final class MirrorPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        // P2: use troveBg palette token instead of raw black so dark/light
        // mode and Reduce Transparency both look right. Resolved at construction
        // time; if appearance later changes the layer will still look natural.
        layer?.backgroundColor = NSColor(Color.troveBg).cgColor
    }
    required init?(coder: NSCoder) { return nil }
}

/// Main pane view. Camera starts on `.task`, stops on `.onDisappear`.
struct MirrorView: View {
    @StateObject private var vm = MirrorViewModel()
    @StateObject private var floatingCtrl = MirrorFloatingPanelController()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    var body: some View {
        VStack(spacing: 12) {
            if vm.permissionDenied {
                permissionDeniedCard
            } else {
                // P0: constrain preview to 16:9 so it never overflows/clips on
                // short windows. aspectRatio + maxHeight provide a stable layout
                // regardless of window height.
                MirrorPreviewView(vm: vm)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.troveLine))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                deviceRow
                snapshotRow
            }
        }
        .task {
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
        // P0 fix: wire Tools > Mirror Webcam Panel menu item — was a dead
        // route. Opens the always-on-top floating panel directly so the
        // user can use the mirror while focused on another app.
        .onReceive(NotificationCenter.default.publisher(for: .troveMirrorOpenFloating)) { _ in
            floatingCtrl.open(vm: vm)
        }
        .navigationTitle("Mirror")
        // P2: navigationSubtitle shows camera name when active.
        .navigationSubtitle(navSubtitle)
        .toolbar { toolbarContent }
    }

    private var navSubtitle: String {
        if vm.permissionDenied { return "Camera access required" }
        if !vm.isActive { return "Starting…" }
        if let uid = vm.deviceID,
           let dev = vm.availableDevices.first(where: { $0.uniqueID == uid }) {
            return dev.localizedName
        }
        return vm.availableDevices.first(where: { $0.position == .front })?.localizedName
            ?? vm.availableDevices.first?.localizedName
            ?? "Active"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // P1: always-on-top floating panel toggle.
            Button {
                floatingCtrl.toggle(vm: vm)
            } label: {
                Label(floatingCtrl.isOpen ? "Close Float" : "Float",
                      systemImage: floatingCtrl.isOpen
                          ? "pip.exit"
                          : "pip.enter")
            }
            .help(floatingCtrl.isOpen
                  ? "Close the always-on-top floating mirror"
                  : "Open always-on-top floating mirror")

            // P1: snapshot button.
            Button { takeSnapshot() } label: {
                Label("Snapshot", systemImage: "camera.circle")
            }
            .disabled(!vm.isActive)
            .help("Capture a still from the camera feed")
        }
    }

    private var permissionDeniedCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill").font(.system(size: 32)).foregroundStyle(.tint)
            Text("Camera access denied").headerText()
            Text("Open System Settings → Privacy & Security → Camera and enable Trove.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            // P1: use TCCDeepLink.camera so users land on the right pane.
            Button("Open System Settings") {
                _ = TCCDeepLink.camera.open()
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceRow: some View {
        HStack {
            if !vm.availableDevices.isEmpty {
                // P1: debounce rapid Picker changes via switchDevice() which
                // guards on isConfiguring before calling stop/start.
                Picker("Camera", selection: Binding(
                    get: { vm.deviceID ?? vm.availableDevices.first?.uniqueID ?? "" },
                    set: { vm.switchDevice(to: $0) }
                )) {
                    ForEach(vm.availableDevices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                .pickerStyle(.menu)
            }
            Spacer()
            Text("Local-only — no recording, no upload")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    // P1: snapshot row — capture still → copy / save / stage.
    private var snapshotRow: some View {
        HStack(spacing: 10) {
            Button {
                takeSnapshot()
            } label: {
                Label("Snapshot", systemImage: "camera.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.isActive)
            .help("Capture a still from the current camera frame")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // P1: snapshot implementation — grabs frame, offers clipboard + stage + save.
    private func takeSnapshot() {
        vm.snapshot { img in
            guard let img = img else {
                SharedStore.stage.flash("Snapshot failed — camera not active", kind: .warning)
                return
            }
            // Copy to clipboard.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.png, .tiff], owner: nil)
            if let tiff = img.tiffRepresentation,
               let rep  = NSBitmapImageRep(data: tiff),
               let png  = rep.representation(using: .png, properties: [:]) {
                pb.setData(png, forType: .png)
                pb.setData(tiff, forType: .tiff)
            }
            // Send to Stage.
            SharedStore.stage.addImage(img)
            // Persist to tmp for Reveal + OutputsLibrary.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mirror-snapshot-\(Int(Date().timeIntervalSince1970)).png")
            if let tiff = img.tiffRepresentation,
               let rep  = NSBitmapImageRep(data: tiff),
               let png  = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: tmp, options: .atomic)
                OutputsLibrary.shared.record(url: tmp, producer: "mirror.snapshot",
                                             sourceLabel: "Mirror snapshot", kind: "image")
            }
            SharedStore.stage.flash("Snapshot copied to clipboard & sent to Stage")
        }
    }
}
