import Foundation
import AppKit
@preconcurrency import AVFoundation
import Observation

/// The camera gate for the picture-in-picture bubble.
///
/// Much simpler than `ScreenRecordingAccess` because AVFoundation exposes both
/// halves publicly and the grant takes effect immediately — no relaunch, no
/// tccutil dance on the happy path. It carries the same `Status` shape purely
/// so the Settings rows for screen, camera and system audio read identically.
///
/// Camera denial is **not** fatal to a recording: the bubble is dropped and the
/// screen still records. That mirrors the meeting recorder, where system audio
/// degrades and only the mic is load-bearing.
@MainActor
@Observable
final class CameraAccess {
    enum Status: Equatable { case unknown, ok, denied, repairing }

    private(set) var status: Status = .unknown
    private(set) var lastCheckedAt: Date?

    private let bundleID: String

    init() {
        self.bundleID = Bundle.main.bundleIdentifier ?? "udha"
    }

    /// Passive status read (never prompts).
    func check() {
        apply(AVCaptureDevice.authorizationStatus(for: .video))
    }

    @discardableResult
    func requestAccess() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        switch current {
        case .authorized:
            apply(current)
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
            }
            lastCheckedAt = Date()
            status = granted ? .ok : .denied
            Log.recording.info("CameraAccess: prompt result granted=\(granted)")
            return granted
        default:
            apply(current)
            return false
        }
    }

    /// User-triggered from Settings. Unlike the screen grant there is no
    /// stale-grant failure mode to repair, so this only exists to un-stick a
    /// recorded denial.
    func repairNow() {
        Task {
            status = .repairing
            await Self.resetGrant(bundleID: bundleID)
            _ = await requestAccess()
        }
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private func apply(_ status: AVAuthorizationStatus) {
        lastCheckedAt = Date()
        switch status {
        case .authorized: self.status = .ok
        case .notDetermined: self.status = .unknown
        default: self.status = .denied
        }
    }

    nonisolated private static func resetGrant(bundleID: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "Camera", bundleID]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
    }
}
