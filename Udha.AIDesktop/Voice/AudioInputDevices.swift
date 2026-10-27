import CoreAudio
import Foundation

/// The Mac's audio input devices and which one the system is listening to.
///
/// This is the *system* default input — the same setting as Sound preferences —
/// because that is what dictation, the voice agent and the meeting recorder all
/// pick up. A Mac with a good USB mic plugged in still defaults to the built-in
/// one often enough that the mic you are actually talking into is worth putting
/// one click away from the session you are talking about.
@MainActor
@Observable
final class AudioInputDevices {

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        /// "MacBook Pro Microphone" is too long for a header button; the make
        /// of the mic is the part you actually read.
        var short: String {
            name.replacingOccurrences(of: "MacBook Pro ", with: "")
                .replacingOccurrences(of: " Microphone", with: "")
        }
    }

    private(set) var devices: [Device] = []
    private(set) var currentID: AudioDeviceID = 0

    var current: Device? { devices.first { $0.id == currentID } }
    var currentName: String { current?.short ?? "No input" }

    /// The listener blocks, kept so they can be torn down. Registered against
    /// the system object: one for the device list (a mic plugged in or pulled
    /// out) and one for the default input changing under us — from Sound
    /// preferences, or because macOS auto-switched to a headset.
    /// `nonisolated(unsafe)` so `deinit` — which is not main-actor isolated —
    /// can unregister. Only ever touched from the main actor in practice.
    nonisolated(unsafe) private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        listen(to: kAudioHardwarePropertyDevices)
        listen(to: kAudioHardwarePropertyDefaultInputDevice)
    }

    deinit {
        // nonisolated C API, safe to unwind from deinit.
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
        }
    }

    // MARK: - Reading

    func refresh() {
        devices = Self.inputDevices()
        currentID = Self.defaultInput() ?? 0
    }

    /// Point the whole system at `device`. Returns false if Core Audio refused,
    /// which happens when the device disappears between listing and choosing.
    @discardableResult
    func select(_ device: Device) -> Bool {
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        guard status == noErr else {
            Log.app.error("audio input: could not select \(device.name) (OSStatus \(status))")
            return false
        }
        currentID = device.id
        return true
    }

    // MARK: - Core Audio

    private func listen(to selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr { listeners.append((address, block)) }
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name)
        }
    }

    /// An output-only device answers with a stream configuration of no
    /// channels; that is the only reliable way to tell the two apart, since
    /// plenty of devices (the Shure, any interface) are both.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        let string = name as String
        return string.isEmpty ? nil : string
    }
}
