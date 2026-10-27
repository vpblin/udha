import Foundation
import CoreMedia
import AudioToolbox

/// Measures the mic samples a capture source is handed, before the writer
/// sees them — the measurement that separates "the mic is delivering rubbish"
/// from "we wrote it down wrong", which are indistinguishable in the finished
/// file.
///
/// Two readings per take:
/// - the format and the level over the first second, always logged. A dead
///   take shows rms 0 here.
/// - after that, half-second windows watched for the static signature: a
///   level around 0.3 with lag-1 autocorrelation near 0.4, where speech and
///   room tone sit above 0.8. The 2026-10-26 take was clean for its first two
///   seconds and then turned to exactly that, so the first second alone can't
///   see it. Logged once, as an error.
///
/// Reads the first channel only, from Int16 or Float32, interleaved or not —
/// AVCaptureSession is pinned to 16-bit interleaved, ScreenCaptureKit hands
/// over float.
///
/// A class with its own lock so a source can hold one per take and swap it on
/// restart; sample callbacks arrive on the source's queue.
final class MicHealthProbe: @unchecked Sendable {
    private let source: String
    private let lock = NSLock()
    private var firstSecondSamples = 0
    private var firstSecondSumSquares = 0.0
    private var loggedFirstSecond = false
    private var warnedNoise = false
    private var window = Window()

    init(source: String) {
        self.source = source
    }

    func observe(_ sample: CMSampleBuffer) {
        guard !lock.withLock({ warnedNoise }),
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let values = Self.firstChannel(of: sample, asbd: asbd), !values.isEmpty else { return }

        var firstSecondLine: String?
        var noiseLine: String?
        lock.withLock {
            if !loggedFirstSecond {
                for v in values { firstSecondSumSquares += v * v }
                firstSecondSamples += values.count
                if firstSecondSamples >= Int(asbd.mSampleRate) {
                    loggedFirstSecond = true
                    let rms = (firstSecondSumSquares / Double(firstSecondSamples)).squareRoot()
                    firstSecondLine = "\(source): mic format \(Self.describe(asbd)) — first second rms=\(String(format: "%.4f", rms))"
                }
                return
            }
            guard let reading = window.add(values, sampleRate: asbd.mSampleRate) else { return }
            if reading.rms > 0.15 && reading.lag1 < 0.6 {
                warnedNoise = true
                noiseLine = "\(source): mic samples look like static from \(String(format: "%.0f", reading.endSeconds))s — rms=\(String(format: "%.3f", reading.rms)) lag1=\(String(format: "%.2f", reading.lag1)) (noise arriving from capture, not the encoder)"
            }
        }
        if let firstSecondLine { Log.recording.info("\(firstSecondLine)") }
        if let noiseLine { Log.recording.error("\(noiseLine)") }
    }

    private static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaving = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
        return "\(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)bit \(isFloat ? "float" : "int") \(interleaving)"
    }

    /// The first channel as doubles in -1…1, or nil for a layout this doesn't
    /// read (anything but 16-bit int or 32-bit float).
    private static func firstChannel(of sample: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Double]? {
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytes = Int(asbd.mBitsPerChannel / 8)
        guard (isFloat && bytes == 4) || (!isFloat && bytes == 2) else { return nil }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let stride = nonInterleaved ? 1 : max(1, Int(asbd.mChannelsPerFrame))

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let frames = Int(first.mDataByteSize) / (bytes * stride)
        var out = [Double]()
        out.reserveCapacity(frames)
        if isFloat {
            let p = data.bindMemory(to: Float.self, capacity: frames * stride)
            for i in 0..<frames { out.append(Double(p[i * stride])) }
        } else {
            let p = data.bindMemory(to: Int16.self, capacity: frames * stride)
            for i in 0..<frames { out.append(Double(p[i * stride]) / 32768.0) }
        }
        return out
    }

    /// Half-second windows reduced to level and lag-1 autocorrelation.
    private struct Window {
        struct Reading {
            var rms: Double
            var lag1: Double
            var endSeconds: Double
        }

        private var count = 0
        private var total = 0
        private var sum = 0.0
        private var sumSquares = 0.0
        private var sumProducts = 0.0
        private var previous: Double?

        mutating func add(_ values: [Double], sampleRate: Double) -> Reading? {
            let length = max(1, Int(sampleRate / 2))
            var reading: Reading?
            for v in values {
                if let previous { sumProducts += previous * v }
                previous = v
                sum += v
                sumSquares += v * v
                count += 1
                total += 1
                if count == length {
                    let n = Double(count)
                    let mean = sum / n
                    let variance = sumSquares / n - mean * mean
                    let lag1 = variance > 0 ? (sumProducts / n - mean * mean) / variance : 1
                    reading = Reading(rms: (sumSquares / n).squareRoot(), lag1: lag1,
                                      endSeconds: 1 + Double(total) / sampleRate)
                    count = 0; sum = 0; sumSquares = 0; sumProducts = 0
                }
            }
            return reading
        }
    }
}
