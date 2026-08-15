// Test-only helpers for driving a real AudioDeviceIOBlock (the RT callback built by
// EQIOProcFactory.swift's makeIOBlock, or captured from FakeCoreAudioTapService) with
// synthetic interleaved-stereo sample data, and reading back the result.
//
// Deliberately narrow: only the single INTERLEAVED-buffer layout is supported (one
// AudioBuffer with mNumberChannels == channels), since that's what the aggregate device's
// format this app assumes (Float32 interleaved, see EQDeviceEngine+Lifecycle.swift's
// step-3.5 format check) — the IOProc's OTHER supported layout (deinterleaved,
// per-channel buffers) isn't exercised by these tests.

import AudioToolbox
import CoreAudio
import Foundation
@testable import eqYourMacbook

/// Owns the backing sample storage for one interleaved AudioBufferList (single buffer,
/// `channels` channels) so it can be handed to an AudioDeviceIOBlock and read back
/// afterward. Class (not struct): the IOProc block may retain pointers into this memory
/// for the duration of one synchronous call; identity/no-copy matters more than value
/// semantics here.
final class TestAudioBuffer {
    let frameCount: Int
    let channels: Int
    private let storage: UnsafeMutablePointer<Float>
    private var bufferList: AudioBufferList

    /// `samples`, if provided, must contain exactly `frameCount * channels` interleaved
    /// values (frame-major, channel-minor: L0,R0,L1,R1,…). Omit for a zero-filled buffer.
    init(frameCount: Int, channels: Int, samples: [Float]? = nil) {
        self.frameCount = frameCount
        self.channels = channels
        let count = frameCount * channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        if let samples {
            precondition(samples.count == count, "sample count must equal frameCount * channels")
            _ = UnsafeMutableBufferPointer(start: storage, count: count).initialize(from: samples)
        } else {
            storage.initialize(repeating: 0, count: count)
        }
        let audioBuffer = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(storage))
        bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
    }

    deinit {
        storage.deinitialize(count: frameCount * channels)
        storage.deallocate()
    }

    /// Current contents (post-IOProc-call for an output buffer) as a flat interleaved array.
    var samples: [Float] {
        Array(UnsafeBufferPointer(start: storage, count: frameCount * channels))
    }

    func withUnsafeBufferListPointer<R>(_ body: (UnsafeMutablePointer<AudioBufferList>) -> R) -> R {
        withUnsafeMutablePointer(to: &bufferList) { body($0) }
    }
}

/// Invoke a real AudioDeviceIOBlock (production `makeIOBlock` output, or a
/// FakeCoreAudioTapService's `capturedIOBlock`) once, synchronously, with the given
/// input/output buffers. Timestamps are zero-initialized dummies — nothing under test
/// reads them (see EQIOProcFactory.swift's `{ _, inInputData, _, outOutputData, _ in`).
func invokeIOBlock(_ block: AudioDeviceIOBlock, input: TestAudioBuffer, output: TestAudioBuffer) {
    var now = AudioTimeStamp()
    var inputTime = AudioTimeStamp()
    var outputTime = AudioTimeStamp()
    input.withUnsafeBufferListPointer { inPtr in
        output.withUnsafeBufferListPointer { outPtr in
            block(&now, inPtr, &inputTime, outPtr, &outputTime)
        }
    }
}

/// A full-scale-relative sine wave, interleaved across `channels` identical channels
/// (both channels carry the same signal — matches how a real stereo source with a
/// centered mono signal would look).
func makeSineWave(frequency: Double, sampleRate: Double, frameCount: Int,
                   amplitude: Float = 0.5, channels: Int = 2) -> [Float] {
    var samples = [Float](repeating: 0, count: frameCount * channels)
    for n in 0..<frameCount {
        let t = Double(n) / sampleRate
        let s = amplitude * Float(sin(2.0 * Double.pi * frequency * t))
        for c in 0..<channels { samples[n * channels + c] = s }
    }
    return samples
}

/// Root-mean-square of a sample array — used to compare steady-state sine amplitude
/// before/after a filter without needing to align phase (RMS of a sinusoid is
/// phase-independent, only amplitude-dependent).
func rms(_ xs: some Collection<Float>) -> Double {
    guard !xs.isEmpty else { return 0 }
    let sumSq = xs.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sumSq / Double(xs.count)).squareRoot()
}
