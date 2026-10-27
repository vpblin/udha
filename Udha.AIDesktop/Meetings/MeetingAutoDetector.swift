import Foundation
import CoreAudio
import Observation

/// Granola-style hands-free capture: when any OTHER process holds the
/// microphone (Zoom, Meet, Teams — exactly while a call is live), start a
/// recording; when the mic has been released for a while, stop it. Manual
/// recordings are never auto-stopped — only recordings this class started.
///
/// The probe reads per-process input state from the HAL
/// (kAudioProcessPropertyIsRunningInput), so Udha's own captures are excluded
/// by pid, not by heuristics. Probes run off the main actor: CoreAudio
/// property reads can stall during Bluetooth profile transitions, and a
/// detector must never freeze the app it exists to serve.
@MainActor
@Observable
final class MeetingAutoDetector {
    private(set) var externalCallActive = false

    private let config: ConfigStore
    private weak var center: MeetingCenter?

    /// Set by `AppCore`. While this returns true, auto-**start** is skipped.
    ///
    /// Exists because Udha's own video recorder trips this detector. The pid
    /// exclusion below is not enough: the recorder's mic rides on an
    /// `AVCaptureSession`, and with a Continuity Camera the input is attributed
    /// to a system process rather than to Udha, so the HAL genuinely reports
    /// "another app is using the microphone". The observable symptom was a
    /// phantom meeting starting within half a second of every screen recording
    /// — and, because tearing that meeting down runs on the quit path, an app
    /// that took the better part of a minute to quit afterwards.
    ///
    /// Deliberately a closure rather than a reference to `RecordingCenter`:
    /// meetings should not have to know that a video recorder exists.
    var suppressAutoStart: (@MainActor () -> Bool)?
    private var timer: Timer?
    private var probeInFlight = false
    private var lastExternalInput = Date.distantPast
    private var autoStarted = false
    /// Whether some other app has held the microphone at any point during the
    /// meeting that is running now. This is what separates "the Zoom call this
    /// was recording just ended" from "nobody is talking in the room" — only
    /// the first is a reason to stop something the user started by hand.
    private var sawExternalDuringMeeting = false
    private var wasLive = false
    private var suppressedUntilRelease = false
    /// Whoever the HAL says is capturing input, logged when it changes. The
    /// phantom-meeting class of bug is only diagnosable if the log says which
    /// process the detector was reacting to.
    private var lastHolder: String?

    init(config: ConfigStore) {
        self.config = config
    }

    func start(center: MeetingCenter) {
        self.center = center
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let meetings = config.config.meetings
        guard meetings.autoRecordMeetings || meetings.autoStopMeetings else { return }
        guard !probeInFlight else { return }
        probeInFlight = true
        Task { @MainActor [weak self] in
            let holder = await Task.detached(priority: .utility) {
                Self.externalMicrophoneHolder()
            }.value
            guard let self else { return }
            self.probeInFlight = false
            if let holder, holder != self.lastHolder {
                Log.meeting.info("MeetingAutoDetector: microphone held by \(holder)")
            }
            self.lastHolder = holder
            self.apply(active: holder != nil)
        }
    }

    private func apply(active: Bool) {
        let meetings = config.config.meetings
        externalCallActive = active
        if active { lastExternalInput = Date() }
        guard let center else { return }

        let isLive = center.live != nil
        // A recording that ended while another app still holds the mic must
        // NOT be restarted on the next tick. Auto-start is an idle→busy edge
        // ("a call just started"), not a level ("a call is happening") — as a
        // level it made Stop meaningless: the user stopped a recording and it
        // came back two seconds later, for as long as the call lasted.
        if wasLive && !isLive && active {
            suppressedUntilRelease = true
            Log.meeting.info("MeetingAutoDetector: recording ended while the mic is still in use — auto-start paused until it is released")
        }
        if !active {
            suppressedUntilRelease = false
        }
        wasLive = isLive

        // Only auto-START is suppressed. A meeting that was already running
        // when a screen recording began is a real meeting and must still
        // auto-stop normally.
        let suppressedByOwnRecorder = suppressAutoStart?() ?? false

        if !isLive {
            autoStarted = false
            sawExternalDuringMeeting = false
        } else if active && !suppressedByOwnRecorder {
            // Udha's own video recorder holds the microphone too. Counting that
            // as "this meeting is a call" would let a screen recording arm the
            // auto-stop on a meeting being held at a table, and end it 45
            // seconds after the take finished.
            sawExternalDuringMeeting = true
        }

        // Latch, rather than merely skipping this tick. The recorder's own hold
        // on the microphone does not end when the recorder does — a Continuity
        // Camera keeps the paired iPhone's input device alive well past it —
        // and a level that is still high when the suppression window lapses
        // reads exactly like a call that just started. Requiring the mic to be
        // seen genuinely released first turns it back into an edge.
        if suppressedByOwnRecorder && active && !suppressedUntilRelease {
            suppressedUntilRelease = true
            Log.meeting.info("MeetingAutoDetector: microphone busy while Udha records video — auto-start paused until it is released")
        }

        if meetings.autoRecordMeetings && active && !isLive && !suppressedUntilRelease && !suppressedByOwnRecorder {
            autoStarted = true
            Log.meeting.info("MeetingAutoDetector: another app is using the microphone — auto-starting recording")
            Task { await center.start(mode: .standard) }
        } else if meetings.autoStopMeetings && !active && isLive,
                  autoStarted || sawExternalDuringMeeting {
            // A meeting Udha started, or one you started while a call was
            // running. Either way the call is over now.
            let quiet = Date().timeIntervalSince(lastExternalInput)
            if quiet > TimeInterval(meetings.autoStopAfterQuietSec) {
                autoStarted = false
                sawExternalDuringMeeting = false
                Log.meeting.info("MeetingAutoDetector: microphone released \(Int(quiet))s ago — auto-stopping recording")
                Task { await center.stop() }
            }
        }
    }

    /// Who, other than Udha, is actively capturing input — bundle ID where the
    /// HAL knows one, otherwise the pid. Nil when nothing is.
    nonisolated private static func externalMicrophoneHolder() -> String? {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize) == noErr,
              listSize > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &processes) == noErr else {
            return nil
        }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        for process in processes {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID else { continue }
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                return bundleID(of: process) ?? "pid \(pid)"
            }
        }
        return nil
    }

    nonisolated private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = value as String?, !value.isEmpty else { return nil }
        return value
    }
}
