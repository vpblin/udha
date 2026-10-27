import Foundation
import CoreMedia

/// The single instant both capture files call t=0, opened by the first real
/// screen frame.
///
/// This exists because of a bug that produced silent, total data loss: the
/// engine used to wait until *both* the screen and the camera were producing
/// before opening the writer sessions, so that neither file began with a black
/// lead-in. A Continuity Camera takes the better part of a second to warm up,
/// and ScreenCaptureKit delivers its first frame immediately — so that first
/// frame was dropped for arriving before the session existed.
///
/// That would be harmless if more frames followed, but SCK only emits a
/// complete frame when the screen actually *changes*. Record a mostly-still
/// screen and the initial frame is the only one there is. Dropping it meant
/// `screen.mov` came out with an audio track and no video track whatsoever —
/// and nothing failed until the compositor refused to render, long after the
/// moment was gone.
///
/// So the rule is inverted: the screen's first frame **opens** the session,
/// timed at that frame's own presentation stamp. The camera then aligns to the
/// same absolute instant; its own earlier frames are dropped, which costs at
/// most a few hundred milliseconds of bubble at the very start and cannot cost
/// the recording.
///
/// Synchronous and lock-guarded on purpose: it is consulted from the capture
/// queues on every sample, and hopping to the main actor to decide would
/// reintroduce exactly the race it exists to remove.
final class SharedSessionStart: @unchecked Sendable {
    private let lock = NSLock()
    private var time: CMTime?

    /// Claims `candidate` as t=0 if nothing has yet. Returns the session start,
    /// which is `candidate` for the winner and the already-set value otherwise.
    @discardableResult
    func open(at candidate: CMTime) -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        if let time { return time }
        time = candidate
        return candidate
    }

    /// The session start, or nil while the primary source has yet to produce.
    var value: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    var isOpen: Bool { value != nil }
}
