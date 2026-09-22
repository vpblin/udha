import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Observation

/// A live view of an `AVCaptureSession`'s video.
///
/// Deliberately a thin wrapper over `AVCaptureVideoPreviewLayer` rather than a
/// second sample-buffer consumer: the preview layer taps the session inside
/// AVFoundation, so watching yourself costs no frames and cannot interfere
/// with what the writer receives.
///
/// Mirrored by default. A camera bubble is a mirror to the person being
/// recorded — an un-mirrored self-view makes people frame themselves wrong.
/// The recorded file is untouched; this flips the preview only.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession?
    var mirrored: Bool = true
    /// `false` letterboxes the whole frame into the view. Framing guides are
    /// drawn in the view's own coordinates, so they only mean anything over a
    /// picture that hasn't been cropped to fit.
    var fills: Bool = true

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.mirrored = mirrored
        view.fills = fills
        view.attach(session)
        return view
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.mirrored = mirrored
        view.fills = fills
        view.attach(session)
    }

    static func dismantleNSView(_ view: CameraPreviewNSView, coordinator: ()) {
        view.attach(nil)
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var mirrored: Bool = true { didSet { applyMirroring() } }
    var fills: Bool = true {
        didSet { previewLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        layer = host
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        host.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func attach(_ session: AVCaptureSession?) {
        guard previewLayer.session !== session else { return }
        previewLayer.session = session
        applyMirroring()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Implicit animation on a layer that resizes with the window reads as
        // the picture sloshing around inside its frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    private func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

/// A camera session that exists only to be looked at — used before a recording
/// starts, so you can frame yourself before you hit record.
///
/// Video only, no audio: this must never look like "Udha is listening", and a
/// mic input here would light the microphone indicator (and trip the meeting
/// auto-detector) just for opening a picker.
///
/// It is stopped before capture begins. Two sessions on one camera is legal on
/// macOS but pointless, and with a Continuity Camera it is a good way to have
/// the iPhone hand the device to neither of them.
@MainActor
@Observable
final class CameraPreviewController {
    private(set) var session: AVCaptureSession?
    private(set) var failure: String?
    private(set) var isStarting = false

    private var runningUID: String?
    /// Bumped by every start and every stop. A session that comes up after its
    /// starter was superseded — the sheet closed, the device was changed again —
    /// is torn straight back down instead of being left running with nothing
    /// pointing at it, which would hold the camera open (and its indicator lit)
    /// for the life of the app.
    private var generation = 0
    private let controlQueue = DispatchQueue(label: "udha.recording.preview.control")

    var isRunning: Bool { session != nil }

    /// Idempotent: calling it again with the same device is free, with a
    /// different one swaps the session.
    func start(uid: String?, access: CameraAccess) async {
        let wanted = uid ?? ""
        if session != nil, runningUID == wanted { return }
        if session != nil { stop() }

        generation += 1
        let mine = generation
        isStarting = true
        defer { isStarting = false }

        guard await access.requestAccess() else {
            failure = "Camera access is off. Enable Udha under Privacy & Security → Camera."
            return
        }
        guard mine == generation else { return }
        guard let device = Self.resolve(uid: uid) else {
            failure = "No camera found."
            return
        }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        newSession.sessionPreset = .hd1280x720
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else {
                newSession.commitConfiguration()
                failure = "\(device.localizedName) is not available right now."
                return
            }
            newSession.addInput(input)
        } catch {
            newSession.commitConfiguration()
            failure = error.localizedDescription
            return
        }
        newSession.commitConfiguration()

        // Same reason as the capture source: `startRunning` blocks while the
        // device warms up, and a slow USB camera must not stall the UI.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                newSession.startRunning()
                cont.resume()
            }
        }
        guard mine == generation, !Task.isCancelled else {
            controlQueue.async { newSession.stopRunning() }
            return
        }
        failure = nil
        runningUID = wanted
        session = newSession
    }

    func stop() {
        generation += 1
        guard let session else { return }
        self.session = nil
        runningUID = nil
        controlQueue.async {
            session.stopRunning()
        }
    }

    /// Stop, and wait for the device to actually be released.
    ///
    /// Used on the path into a recording. `stop()` dispatches the teardown and
    /// returns, which is fine when the sheet is merely closing but not when the
    /// next thing to happen is another session opening the same camera — a
    /// Continuity Camera handed over while it is still being let go is a good
    /// way to get a take that captured neither.
    func stopAndWait() async {
        generation += 1
        guard let session else { return }
        self.session = nil
        runningUID = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                session.stopRunning()
                cont.resume()
            }
        }
    }

    private static func resolve(uid: String?) -> AVCaptureDevice? {
        if let uid, !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) { return device }
        return CameraCaptureSource.availableCameras().first.flatMap { AVCaptureDevice(uniqueID: $0.uid) }
            ?? AVCaptureDevice.default(for: .video)
    }
}
