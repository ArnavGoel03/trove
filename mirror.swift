// mirror.swift — webcam preview pane (Hand Mirror replacement).
//
// Cuts Hand Mirror ($5): show the front camera feed in a Trove pane and
// optionally in a floating always-on-top panel. Pure AVFoundation — no
// recording, no upload, no analytics. Camera shuts off on pane disappear.

import SwiftUI
import AppKit
import AVFoundation

@MainActor
final class MirrorViewModel: ObservableObject {
    @Published var isActive = false
    @Published var permissionDenied = false
    @Published var deviceID: String?            // user-selected camera UID
    @Published var availableDevices: [AVCaptureDevice] = []

    private(set) var session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?

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
        if session.isRunning {
            let s = session
            Task.detached(priority: .utility) { s.stopRunning() }
        }
        isActive = false
    }

    private func configureAndStart() {
        permissionDenied = false
        refreshDeviceList()
        guard let device = pickDevice() else { return }
        session.beginConfiguration()
        // Remove any prior input — switching cameras
        if let prev = currentInput { session.removeInput(prev) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            session.commitConfiguration()
            return
        }
        session.sessionPreset = .high
        session.commitConfiguration()
        let s = session
        Task.detached(priority: .userInitiated) { s.startRunning() }
        isActive = true
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
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { return nil }
}

/// Main pane view. Camera starts on `.task`, stops on `.onDisappear`.
struct MirrorView: View {
    @StateObject private var vm = MirrorViewModel()

    var body: some View {
        VStack(spacing: 12) {
            if vm.permissionDenied {
                permissionDeniedCard
            } else {
                MirrorPreviewView(vm: vm)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.troveLine))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                deviceRow
            }
        }
        .task {
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
        .navigationTitle("Mirror")
    }

    private var permissionDeniedCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill").font(.system(size: 32)).foregroundStyle(.tint)
            Text("Camera access denied").font(.headline)
            Text("Open System Settings → Privacy & Security → Camera and enable Trove.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open System Settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(u)
                }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceRow: some View {
        HStack {
            if !vm.availableDevices.isEmpty {
                Picker("Camera", selection: Binding(
                    get: { vm.deviceID ?? vm.availableDevices.first?.uniqueID ?? "" },
                    set: { vm.deviceID = $0; vm.stop(); vm.start() }
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
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}
