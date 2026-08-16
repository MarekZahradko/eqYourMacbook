// Per-callback IOProc block factory bound to one device's EQDeviceRTContext.

import Accelerate
import AudioToolbox

/// Builds an IOProc block bound to one device's `EQDeviceRTContext`.
///
/// RT rules: NO allocation, NO locks, NO logging, NO Objective-C / Swift runtime calls
/// anywhere in this block's body (or anything it calls).
func makeIOBlock(context: EQDeviceRTContext) -> AudioDeviceIOBlock {
    return { _, inInputData, _, outOutputData, _ in
        let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

        // Consume pending coefficients here (RT thread, same thread as vDSP_biquadm) so
        // there's no race with the main-thread writer. rtAcquireFence() pairs with the
        // producer's rtReleaseFence() (EQDeviceEngine+LiveUpdate.swift's
        // flushPendingUpdate) — without it, ARM64 could observe this flag flip before
        // observing the pendingCoeffs writes that preceded it in program order, handing
        // vDSP a torn/stale mix of coefficients. See EQDeviceRTContext.swift's
        // rtReleaseFence/rtAcquireFence doc comment for the full rationale.
        if context.pendingFlag != 0 {
            rtAcquireFence()
            if let setup = context.biquadSetup, let pending = context.pendingCoeffs {
                vDSP_biquadm_SetTargetsDouble(setup,
                                              pending,
                                              0.005,                              // interp rate (per-sample step toward target)
                                              0.0001,                             // interp threshold (|Δ| considered "reached")
                                              0,                                  // start_sec
                                              0,                                  // start_chn
                                              vDSP_Length(context.maxSections),   // nsec
                                              vDSP_Length(context.channelCount))  // nchn
                rtReleaseFence()          // publish consumption in order, before...
                context.pendingFlag = 0   // ...the flag flip main is watching for
            }
        }

        // No output buffers → nothing to render into. Never alias input as output
        // (that would write into the tap's memory).
        guard outList.count > 0 else { return }

        // Read input defensively. Two observed layouts:
        //   (a) one interleaved stereo buffer: mNumberChannels == 2, samples L R L R …
        //   (b) per-channel (deinterleaved) buffers: N buffers, mNumberChannels == 1.
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

        // If there is no input at all, zero the output and bail (silence, not garbage).
        guard inList.count > 0, let firstIn = inList[0].mData else {
            for buf in outList {
                if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
            }
            return
        }

        let channels = context.channelCount
        let inChannelsFirstBuffer = Int(inList[0].mNumberChannels)
        let interleaved = inList.count == 1 && inChannelsFirstBuffer >= channels

        // Frame count from the *output* buffer (what the device wants us to fill).
        let outBuffer0 = outList[0]
        let outInterleaved = outList.count == 1 && Int(outBuffer0.mNumberChannels) >= channels
        let outBytesPerFrame = outInterleaved
            ? channels * MemoryLayout<Float>.size
            : MemoryLayout<Float>.size
        let outFrames = Int(outBuffer0.mDataByteSize) / outBytesPerFrame

        // Frames available in the input's channel-0 buffer (same units as outFrames).
        let inBytesPerFrame = interleaved
            ? inChannelsFirstBuffer * MemoryLayout<Float>.size
            : MemoryLayout<Float>.size
        let inFrames = Int(inList[0].mDataByteSize) / max(inBytesPerFrame, MemoryLayout<Float>.size)

        // A clock-synchronized aggregate delivers equal counts; clamp anyway so vDSP
        // never over-reads input or over-writes output if they ever disagree.
        let frames = min(outFrames, inFrames)

        guard frames > 0 else {
            for buf in outList {
                if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
            }
            return
        }

        // Watchdog telemetry: max-abs of the input (channel 0 is enough as a liveness
        // probe; vDSP_maxmgv is allocation-free). Keep a running max so a transient
        // between watchdog ticks isn't masked by a quiet final callback; the watchdog
        // reads then resets to 0.
        var maxAbs: Float = 0
        let probeCount = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
        if probeCount > 0 {
            vDSP_maxmgv(firstIn.assumingMemoryBound(to: Float.self), 1, &maxAbs, vDSP_Length(probeCount))
        }
        // CAS-based (OSAtomicCompareAndSwap32Barrier, self-fencing) — maxAbsInput has
        // two genuine concurrent writers (this RT thread + the watchdog's reset), see
        // EQDeviceRTContext.swift's doc comment on maxAbsInputBits.
        context.rtUpdateMaxAbsInput(maxAbs)
        context.callbackCounter = context.callbackCounter &+ 1
        // Publish the counter write above so the main-actor watchdog (which brackets
        // its read with rtAcquireFence(), EQDeviceEngine+Watchdog.swift) observes it
        // in order rather than relying on plain-field visibility.
        rtReleaseFence()

        // Build channel pointer arrays for input and output (pre-allocated scratch).
        guard let inPtrs = context.inputPtrs, let outPtrs = context.outputPtrs else {
            // No scratch (shouldn't happen while running) → passthrough copy.
            copyInputToOutput(inList: inList, outList: outList)
            return
        }

        // Input pointers + per-channel stride. Slots are non-Optional; they hold a
        // sentinel until written here every callback before any read by vDSP.
        let inStride: vDSP_Stride
        if interleaved {
            let base = firstIn.assumingMemoryBound(to: Float.self)
            for c in 0..<channels { inPtrs[c] = UnsafePointer(base + c) }
            inStride = vDSP_Stride(inChannelsFirstBuffer)
        } else {
            // Per-channel buffers: clamp to available, replicate last for any shortfall.
            for c in 0..<channels {
                let srcIdx = min(c, inList.count - 1)
                if let d = inList[srcIdx].mData {
                    inPtrs[c] = UnsafePointer(d.assumingMemoryBound(to: Float.self))
                } else {
                    inPtrs[c] = UnsafePointer(firstIn.assumingMemoryBound(to: Float.self))
                }
            }
            inStride = 1
        }

        // Output pointers + per-channel stride. Every channel slot MUST end up valid for
        // vDSP to write into; if we can't satisfy that, fall back to a plain copy below.
        let outStride: vDSP_Stride
        var outPtrsValid = true
        if outInterleaved, let d = outBuffer0.mData {
            let base = d.assumingMemoryBound(to: Float.self)
            for c in 0..<channels { outPtrs[c] = base + c }
            outStride = vDSP_Stride(Int(outBuffer0.mNumberChannels))
        } else {
            for c in 0..<channels {
                if c < outList.count, let d = outList[c].mData {
                    outPtrs[c] = d.assumingMemoryBound(to: Float.self)
                } else {
                    outPtrsValid = false
                }
            }
            outStride = 1
        }

        // Bypass: identity copy via memcpy (RT-safe), honor the atomic flag.
        if context.bypass != 0 {
            copyInputToOutput(inList: inList, outList: outList)
            return
        }

        // Apply the biquad cascade. vDSP_biquadm processes all N channels with one shared
        // section set and separate delay state per channel, with strides handling
        // interleaving; the scratch arrays already hold the exact non-Optional pointer
        // types vDSP wants, so pass them straight through with no rebind.
        guard let setup = context.biquadSetup, outPtrsValid else {
            copyInputToOutput(inList: inList, outList: outList)
            return
        }

        vDSP_biquadm(setup,
                     inPtrs, inStride,
                     outPtrs, outStride,
                     vDSP_Length(frames))
    }
}

/// RT-safe identity copy of input → output. Handles size mismatch by copying the
/// min of the two byte counts and zeroing any remainder. No allocation.
func copyInputToOutput(inList: UnsafeMutableAudioBufferListPointer,
                        outList: UnsafeMutableAudioBufferListPointer) {
    let n = min(inList.count, outList.count)
    for i in 0..<n {
        guard let dst = outList[i].mData else { continue }
        let outBytes = Int(outList[i].mDataByteSize)
        if let src = inList[i].mData {
            let copyBytes = min(outBytes, Int(inList[i].mDataByteSize))
            memcpy(dst, src, copyBytes)
            if copyBytes < outBytes { memset(dst + copyBytes, 0, outBytes - copyBytes) }
        } else {
            memset(dst, 0, outBytes)
        }
    }
    // Zero any output buffers with no matching input.
    if outList.count > n {
        for i in n..<outList.count {
            if let dst = outList[i].mData { memset(dst, 0, Int(outList[i].mDataByteSize)) }
        }
    }
}
