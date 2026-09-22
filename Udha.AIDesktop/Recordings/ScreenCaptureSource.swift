import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia

/// What a recording points at.
enum ScreenCaptureTarget: Hashable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

/// One display or window that can be recorded, resolved for the picker UI.
struct ScreenCaptureCandidate: Identifiable, Hashable, Sendable {
    var id: ScreenCaptureTarget { target }
    var target: ScreenCaptureTarget
    var name: String
    /// Owning app, for windows. `nil` for displays.
    var applicationName: String?
    var width: Int
    var height: Int
}

/// Screen video **and** system audio from one `SCStream`, written straight into
/// an `AssetWriterPair`.
///
/// Note the deliberate divergence from `Meetings/SystemAudioTap`: that class
/// rejected ScreenCaptureKit on purpose, to get the milder "System Audio
/// Recording Only" TCC instead of full Screen Recording. That trade-off
/// inverts here — a video recorder is taking `kTCCServiceScreenCapture`
/// regardless, and once it has it, SCK hands over video and system audio
/// together with no second Core Audio aggregate device to babysit. The meeting
/// path keeps using `SystemAudioTap` untouched.
///
/// `@unchecked Sendable` with an internal lock: SCK delivers samples on its own
/// queue while the engine drives start/stop from the main actor.
final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AssetWriterPair?
    private let sampleQueue = DispatchQueue(label: "udha.recording.screen", qos: .userInitiated)

    /// Fired when SCK tears the stream down on its own (display reconfigured,
    /// permission revoked mid-recording). The engine's watchdog rebuilds.
    var onStreamStopped: (@Sendable (Error?) -> Void)?
    /// Fired on the first frame that actually lands, so the engine can open the
    /// shared session only once both sources are genuinely producing.
    var onFirstFrame: (@Sendable () -> Void)?

    private var sawFirstFrame = false
    private var lastFrameAtRaw: Date = .distantPast

    /// Polled by the engine's watchdog. Deliberately a polled value rather than
    /// a per-frame callback: frames land 30×/second and hopping to the main
    /// actor that often to update a timestamp would cost more than the capture.
    var lastFrameAt: Date { lock.withLock { lastFrameAtRaw } }

    // MARK: - Discovery

    /// Displays and on-screen windows worth offering. Windows are filtered to
    /// ones with a real title and a sane size — the shareable list is full of
    /// 1×1 helper windows that would just be noise in a picker.
    static func availableTargets() async throws -> [ScreenCaptureCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var out: [ScreenCaptureCandidate] = []

        for (index, display) in content.displays.enumerated() {
            out.append(ScreenCaptureCandidate(
                target: .display(display.displayID),
                name: content.displays.count == 1 ? "Screen" : "Screen \(index + 1)",
                applicationName: nil,
                width: display.width,
                height: display.height
            ))
        }
        for window in content.windows {
            guard let title = window.title, !title.isEmpty else { continue }
            let frame = window.frame
            guard frame.width >= 200, frame.height >= 200 else { continue }
            out.append(ScreenCaptureCandidate(
                target: .window(window.windowID),
                name: title,
                applicationName: window.owningApplication?.applicationName,
                width: Int(frame.width),
                height: Int(frame.height)
            ))
        }
        return out
    }

    /// Capture dimensions for a target: native, unless that is more than the
    /// encoder should be asked to swallow in real time.
    ///
    /// This used to cap the **long edge** at 2560, which is exactly the wrong
    /// axis. On a 32:9 display it scaled 5120×1440 down to 2560×720 — halving
    /// the vertical resolution — and the compositor then had to stretch a
    /// full-height crop back up to a 1080-row master. Real detail thrown away
    /// at capture and interpolated back afterwards, which is why screen text
    /// came out unreadable however high the master's bitrate went.
    ///
    /// What actually matters is that the *kept* region has at least as many
    /// rows as the master it feeds (1080 wide, 1920 vertical), so the budget is
    /// expressed as total pixels and a height ceiling instead. A 32:9 display
    /// now records natively; a 5K or 6K panel still gets scaled, because those
    /// carry far more pixels than any 1080p master can use.
    static func captureSize(
        width: Int, height: Int,
        maxPixels: Int = 9_000_000, maxHeight: Int = 1800
    ) -> (width: Int, height: Int) {
        let w = max(2, width), h = max(2, height)
        let pixelScale = (Double(maxPixels) / Double(w * h)).squareRoot()
        let heightScale = Double(maxHeight) / Double(h)
        let scale = min(1, pixelScale, heightScale)
        guard scale < 1 else { return (even(w), even(h)) }
        return (even(Int((Double(w) * scale).rounded())), even(Int((Double(h) * scale).rounded())))
    }

    /// H.264 wants even dimensions; an odd one makes the encoder silently
    /// reject every frame.
    private static func even(_ v: Int) -> Int { v % 2 == 0 ? v : v - 1 }

    // MARK: - Lifecycle

    /// Resolves the target, builds the stream and starts it. Throws if the
    /// target has vanished (display unplugged, window closed between the picker
    /// and the record button).
    ///
    /// `excludingWindowIDs` keeps Udha's own recording-border panel out of the
    /// picture. It only bites on the display path — a window filter captures
    /// exactly one window and can't pick up an overlay by accident.
    func start(
        target: ScreenCaptureTarget, writer: AssetWriterPair, frameRate: Int,
        capturesAudio: Bool, showsCursor: Bool, excludingWindowIDs: [CGWindowID] = []
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let sourceWidth: Int
        let sourceHeight: Int
        var described = "unknown target"

        switch target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingSourceError.targetUnavailable("That screen is no longer connected.")
            }
            described = "display \(displayID)"
            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            filter = excluded.isEmpty
                ? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                : SCContentFilter(display: display, excludingWindows: excluded)
            sourceWidth = display.width
            sourceHeight = display.height
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingSourceError.targetUnavailable("That window has been closed.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceWidth = Int(window.frame.width)
            sourceHeight = Int(window.frame.height)
            described = "window \"\(window.title ?? "untitled")\" (\(window.owningApplication?.applicationName ?? "unknown app"))"
        }

        let size = Self.captureSize(width: sourceWidth, height: sourceHeight)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        // A demo without the pointer is useless — this is the one place where
        // the default (true) is also the right answer, set explicitly so a
        // future refactor doesn't quietly drop it.
        config.showsCursor = showsCursor
        config.capturesAudio = capturesAudio
        // Same reasoning as SystemAudioTap's process exclusion: Udha's own TTS
        // must never land in a recording of Udha.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        lock.withLock {
            self.stream = stream
            self.writer = writer
            self.sawFirstFrame = false
        }
        try await stream.startCapture()
        // The target is named, not just its dimensions: a take that comes back
        // black is a completely different investigation depending on whether it
        // was a display or one app's window.
        Log.recording.info("ScreenCaptureSource: capturing \(described) at \(size.width)x\(size.height) @\(frameRate)fps audio=\(capturesAudio) excluding=\(excludingWindowIDs.count) window(s)")
    }

    func stop() async {
        let current: SCStream? = lock.withLock {
            let s = stream
            stream = nil
            writer = nil
            return s
        }
        guard let current else { return }
        do {
            try await current.stopCapture()
        } catch {
            // Already-stopped streams throw here; nothing to recover.
            Log.recording.debug("ScreenCaptureSource: stopCapture: \(error.localizedDescription)")
        }
    }

    /// Detaches without awaiting, for the quit path.
    func abort() {
        let current: SCStream? = lock.withLock {
            let s = stream
            stream = nil
            writer = nil
            return s
        }
        guard let current else { return }
        current.stopCapture { _ in }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let isComplete = type != .screen || Self.isCompleteFrame(sampleBuffer)

        var shouldSignalFirstFrame = false
        if type == .screen {
            // Health is stamped for EVERY screen sample, including the .idle
            // ones dropped below. SCK only emits a complete frame when the
            // screen actually changes, so a user reading a static page produces
            // no complete frames at all — keying liveness off those would have
            // the watchdog tear down and rebuild a perfectly healthy stream
            // every 10 seconds of stillness.
            lock.withLock {
                lastFrameAtRaw = Date()
                if isComplete, !sawFirstFrame {
                    sawFirstFrame = true
                    shouldSignalFirstFrame = true
                }
            }
        }
        if shouldSignalFirstFrame { onFirstFrame?() }

        // .idle carries no new image data and .blank is a black frame; neither
        // belongs in the file. Dropping them is also why a static stretch costs
        // almost no bitrate — the last written frame simply persists on
        // playback until the next real one lands.
        guard isComplete else { return }

        let writer: AssetWriterPair? = lock.withLock { self.writer }
        guard let writer else { return }
        writer.append(sampleBuffer, isVideo: type == .screen)
    }

    /// Reads SCK's per-frame status out of the attachment dictionary.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            // No attachment: take the frame rather than dropping real content.
            return true
        }
        return status == .complete
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.recording.error("ScreenCaptureSource: stream stopped: \(error.localizedDescription)")
        lock.withLock {
            self.stream = nil
            self.writer = nil
        }
        onStreamStopped?(error)
    }
}

enum RecordingSourceError: LocalizedError {
    case targetUnavailable(String)
    case noCamera
    case cannotAddInput(String)
    case writerUnavailable

    var errorDescription: String? {
        switch self {
        case .targetUnavailable(let why): return why
        case .noCamera: return "No camera is available."
        case .cannotAddInput(let what): return "The capture session refused the \(what) input."
        case .writerUnavailable: return "Could not open the recording file for writing."
        }
    }
}
