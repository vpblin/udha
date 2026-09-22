import Foundation
import CoreAudio

struct AudioDevice: Hashable, Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum AudioDeviceLister {
    static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            let name = propString(id: id, selector: kAudioObjectPropertyName) ?? "Unknown"
            let uid = propString(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "dev-\(id)"
            let hasInput = streamCount(id: id, scope: kAudioObjectPropertyScopeInput) > 0
            let hasOutput = streamCount(id: id, scope: kAudioObjectPropertyScopeOutput) > 0
            guard hasInput || hasOutput else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
        }
    }

    static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { $0.uid == uid }?.id
    }

    private static func propString(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let cfString = unmanaged?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    private static func streamCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
