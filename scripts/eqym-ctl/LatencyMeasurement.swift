// `eqym-ctl latency`: the latency the eqYourMacbook path ADDS to system audio, measured
// with the built-in microphone and driven entirely by the tool — no human in the loop, so
// runs at different `ioBufferTargetDuration` values are reproducible and comparable.
//
// Method ("grid shift"): `afplay` (a separate, tapped process) plays a click train with a
// fixed period P while this tool records the microphone and detects every click's onset.
// Left alone, onsets sit on a rigid grid t₀ + n·P. When the tool turns the EQ OFF over the
// control channel, afplay's clock is untouched but its audio stops taking the tap →
// aggregate → IOProc detour, so every later click lands EARLY by the detour's latency Δ;
// turning it back ON lands them LATE by Δ. For each toggle the grid phase is fitted from
// the ~4 clicks before it and the phase shift is read as the MEDIAN over the ~4 clicks
// well after it. No absolute time reference is needed (afplay's start-up jitter, the
// device's own latency and the acoustic path cancel out), and the median is immune to a
// stray onset — the toggle itself causes audible transients (mute/unmute discontinuity
// and the Δ-long gap at the switch), and a single-interval rule was fooled by them.
//
// The ON switch does not happen at the command: enabling rebuilds the tap and defers the
// aggregate start ~0.3 s (phase B). The post-toggle window therefore starts 0.6 s after
// the command; the click that falls into the Δ gap at the switch is simply absent.
//
// Why afplay and not this tool's own output: a process running input AND output is a
// voice session and gets excluded from the tap (CLAUDE.md § Invariants), so its clicks
// would take the direct path. afplay is output-only and tapped like any player; this
// tool only records (input-only → not tapped, not a voice session).
//
// Preconditions and run-quality gates fail fast (exit codes in main.swift): no microphone
// permission, not quiet, an implausible onset count or a jittery grid produce NO number.

import AVFoundation
import CoreAudio
import Foundation

enum LatencyMeasurement {

    static let sampleRate: Double = 48_000
    static let period: Double = 0.5                 // click period P
    static let duration: Double = 30                // click train length
    static let preRoll: Double = 1.0                // mic-only seconds before afplay, for the noise floor
    /// Seconds after afplay launch at which the EQ is toggled: OFF, ON, OFF, ON. The .25
    /// keeps the toggle away from the click grid whatever afplay's start-up delay is.
    static let toggleTimes: [Double] = [6.25, 12.25, 18.25, 24.25]
    static let preWindow: Double = 2.2              // clicks in [t − 2.2 s, t) fit the pre-toggle grid (≈4)
    static let postWindow: ClosedRange<Double> = 0.6...2.6   // clicks in (t + 0.6, t + 2.6] carry the shifted grid (≈4)
    static let clickBurst: Double = 0.003           // 3 ms tone burst survives any EQ curve; a 1-sample impulse may not
    static let clickToneHz: Double = 3_000
    static let clickAmplitude: Float = 0.8
    static let refractory: Double = 0.2             // ignore ringing/echo after an onset
    static let clickLevelFraction: Float = 0.35     // second-pass threshold relative to the median click peak
    static let onsetCountTolerance = (low: 6, high: 4)   // lost in Δ gaps / at the edges vs. extras that are not clicks
    static let maxJitterMs: Double = 1.0            // grid deviation of untouched intervals above this = unreliable detection
    static let microphonePromptTimeout: Double = 60 // a first run shows the system prompt; never block past this

    static func run(client: EQControlClient, outDir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let clickPath = (outDir as NSString).appendingPathComponent("click-train.wav")
        let recordingPath = (outDir as NSString).appendingPathComponent("mic-\(fileStamp()).caf")
        let resultsPath = (outDir as NSString).appendingPathComponent("latency-results.tsv")

        // --- Preconditions -------------------------------------------------------------
        ensureMicrophoneAccess()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay") else { fail(6, "/usr/bin/afplay not found") }
        guard var state = client.request(.status) else {
            fail(3, "eqYourMacbook is not reachable over the control channel — is the installed build running, and does it include EQControlChannel.swift?")
        }
        if state.bypassed {
            emit("bypass was ON — turning it off for the measurement")
            state = client.request(.bypassOff) ?? state
        }
        if !state.enabled {
            emit("EQ was disabled — enabling")
            _ = client.request(.enable)
            state = client.waitForState(timeout: 3) { $0.engineRunning }?.snapshot ?? (client.request(.status) ?? state)
        }
        guard state.engineRunning, let device = state.deviceName, let rate = state.sampleRate,
              let ownObject = state.ownProcessObject else {
            fail(4, "no engine is running (\(state.statusDetail)). Select the device that is the current default output in the menu, then rerun.")
        }
        guard let bufferFrames = state.ioBufferFrames else {
            fail(4, "the engine reports no IO buffer size — the pin failed (see the app log: /usr/bin/log show --last 10m --predicate 'subsystem == \"com.zdenekkops.eqyourmacbook\"' | grep 'io buffer'). The run could not be labeled, so it is not made.")
        }
        let own: Set<AudioObjectID> = [AudioObjectID(ownObject)]
        requireQuiet(excluding: own, phase: "before the run")

        emit("device:    \(device)")
        emit(String(format: "io buffer: %d frames = %.2f ms @ %.0f Hz", bufferFrames, Double(bufferFrames) / rate * 1000, rate))
        emit("")

        // --- Click train + recorder ----------------------------------------------------
        do { try writeClickTrain(to: clickPath) } catch { fail(6, "could not write click train: \(error)") }
        let recorder = Recorder()
        do { try recorder.start() } catch { fail(5, "could not start microphone capture: \(error)") }
        client.pump(preRoll)
        guard recorder.sampleCount > Int(recorder.inputRate * preRoll * 0.5) else {
            fail(5, "the microphone delivered no samples — capture is blocked (permission? another app holding the mic exclusively?)")
        }

        // --- Run ------------------------------------------------------------------------
        emit("playing \(Int(duration)) s of clicks (every \(Int(period * 1000)) ms); toggling the EQ at t = \(toggleTimes.map { String($0) }.joined(separator: ", ")) s. Keep the room quiet.")
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [clickPath]
        do { try afplay.run() } catch { fail(6, "could not launch afplay: \(error)") }
        let launchedAt = Date()

        struct Toggle { let at: Date; let command: EQControlCommand; let acknowledged: Bool }
        var toggles: [Toggle] = []
        var nextToggle = 0
        var lastTick = -1
        while afplay.isRunning {
            client.pump(0.05)
            let t = Date().timeIntervalSince(launchedAt)
            if nextToggle < toggleTimes.count, t >= toggleTimes[nextToggle] {
                let command: EQControlCommand = nextToggle % 2 == 0 ? .disable : .enable
                let at = Date()
                let reply = client.request(command, timeout: 1.0)
                toggles.append(Toggle(at: at, command: command, acknowledged: reply != nil))
                emit(String(format: "  t = %5.2f s  %@%@", t, command.rawValue.uppercased(), reply == nil ? "  (no reply!)" : ""))
                nextToggle += 1
            }
            let tick = Int(t)
            if tick != lastTick, tick % 5 == 0 { emit("  t = \(tick) s"); lastTick = tick }
        }
        client.pump(0.5)
        recorder.stop()
        // Leave the app the way a user expects it: enabled, not bypassed.
        _ = client.request(.enable)
        _ = client.request(.bypassOff)
        recorder.save(to: recordingPath)

        // afplay has exited; anything else with output running now was there during the run.
        requireQuiet(excluding: own, phase: "after the run (the recording is contaminated, no number is produced)")

        // --- Analysis -------------------------------------------------------------------
        let detection = detectOnsets(recorder.samples, rate: recorder.inputRate, noiseFloorSeconds: preRoll * 0.8)
        let onsets = detection.onsets
        let expected = Int(duration / period)
        emit("")
        emit(String(format: "detected %d onsets (expected ≈ %d; first pass %d, click level %.3f, threshold %.3f); recording: %@",
                    onsets.count, expected, detection.firstPassCount, detection.clickLevel, detection.threshold, recordingPath))
        guard onsets.count >= expected - onsetCountTolerance.low, onsets.count <= expected + onsetCountTolerance.high else {
            fail(7, "onset count implausible (\(onsets.count) vs ≈\(expected)). Too few: output muted/too quiet or the mic is not hearing the speakers. Too many: noise or echoes are being counted as clicks. No number produced.")
        }

        let periodMs = period * 1000
        let recordingOffset = recorder.startedAt.timeIntervalSince1970
        let toggleSeconds = toggles.map { $0.at.timeIntervalSince1970 - recordingOffset }

        // Method noise floor: grid deviation of intervals nowhere near a toggle.
        var quiet: [Double] = []
        for k in 1..<onsets.count
        where !toggleSeconds.contains(where: { onsets[k] > $0 - preWindow - period && onsets[k] < $0 + postWindow.upperBound + period }) {
            let interval = (onsets[k] - onsets[k - 1]) * 1000
            quiet.append(abs(interval - (interval / periodMs).rounded() * periodMs))
        }
        let jitterMs = median(quiet) ?? .nan
        emit(String(format: "method jitter (median grid deviation of untouched intervals): %.2f ms", jitterMs))
        guard jitterMs <= maxJitterMs else {
            fail(7, String(format: "grid jitter %.2f ms exceeds %.1f ms — onset detection is unreliable in this room/setup (noise, echo, fan). No number produced.", jitterMs, maxJitterMs))
        }
        let significance = max(3 * jitterMs, 0.5)

        emit("")
        emit("per toggle (grid phase of ≈4 clicks after the switch vs. ≈4 clicks before the command):")
        var measured: [Double] = []
        for (i, toggle) in toggles.enumerated() {
            let tSec = toggleSeconds[i]
            let pre = onsets.filter { $0 >= tSec - preWindow && $0 < tSec }
            let post = onsets.filter { $0 > tSec + postWindow.lowerBound && $0 <= tSec + postWindow.upperBound }
            guard pre.count >= 3, post.count >= 3, let anchor = gridAnchor(pre) else {
                emit(String(format: "  %-7@ at %6.2f s: not enough clicks around it (%d before, %d after) — ignored",
                            toggle.command.rawValue, tSec, pre.count, post.count))
                continue
            }
            let shifts = post.map { gridDeviation($0, anchor: anchor) * 1000 }
            guard let shiftMs = median(shifts), let spreadMs = median(shifts.map { abs($0 - shiftMs) }) else { continue }
            let expectedSign: Double = toggle.command == .disable ? -1 : 1     // OFF → early, ON → late
            var verdict = ""
            if !toggle.acknowledged { verdict = "   (app did not acknowledge the command — ignored)" }
            else if spreadMs > significance { verdict = "   (post-toggle clicks disagree with each other — ignored)" }
            else if abs(shiftMs) < significance { verdict = "   (no shift found — ignored)" }
            else if shiftMs * expectedSign < 0 { verdict = "   (unexpected direction — ignored)" }
            emit(String(format: "  %-7@ at %6.2f s: %@ by %6.2f ms  (spread %.2f ms over %d clicks)%@",
                        toggle.command.rawValue, tSec, shiftMs < 0 ? "EARLY" : "LATE ", abs(shiftMs), spreadMs, post.count, verdict))
            if verdict.isEmpty { measured.append(abs(shiftMs)) }
        }
        emit("")
        guard let medianMs = median(measured), let minMs = measured.min(), let maxMs = measured.max() else {
            fail(8, "no usable shift measured — did the EQ toggle at all? (check `eqym-ctl status` and the app log)")
        }
        emit(String(format: "added latency of the EQ path: median %.2f ms  (n = %d of %d toggles, min %.2f, max %.2f)",
                    medianMs, measured.count, toggles.count, minMs, maxMs))
        emit("")
        emit(String(format: "RESULT\tbuffer=%d\trate=%.0f\tdevice=%@\tadded_ms_median=%.2f\tn=%d\tmin=%.2f\tmax=%.2f\tjitter_ms=%.2f",
                    bufferFrames, rate, device, medianMs, measured.count, minMs, maxMs, jitterMs))
        appendResult(to: resultsPath, fields: [fileStamp(), "\(bufferFrames)", String(format: "%.0f", rate), device,
                                                String(format: "%.2f", medianMs), "\(measured.count)",
                                                String(format: "%.2f", minMs), String(format: "%.2f", maxMs),
                                                String(format: "%.2f", jitterMs), recordingPath])
        emit("appended to \(resultsPath)")
        return 0
    }

    // MARK: - Grid arithmetic

    /// Deviation of `onset` from the nearest grid point anchor + n·P, in seconds, in (−P/2, P/2].
    private static func gridDeviation(_ onset: Double, anchor: Double) -> Double {
        let d = onset - anchor
        return d - (d / period).rounded() * period
    }

    /// Grid anchor fitted to a run of onsets: the first one, corrected by the median of the
    /// others' grid deviations relative to it (a stray onset among them cannot move the median).
    private static func gridAnchor(_ onsets: [Double]) -> Double? {
        guard let first = onsets.first else { return nil }
        let corrections = onsets.map { gridDeviation($0, anchor: first) }
        return median(corrections).map { first + $0 }
    }

    // MARK: - Gates

    private static func requireQuiet(excluding own: Set<AudioObjectID>, phase: String) {
        let offenders = otherProcessesWithOutputRunning(excluding: own)
        guard !offenders.isEmpty else { return }
        emit("NOT quiet \(phase) — output running in:")
        for (object, io) in offenders { emit("  \(describe(object, io))") }
        fail(9, "another process has output running; a silence/latency measurement is meaningless. Stop it and rerun.")
    }

    private static func ensureMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // First run in this terminal: the system shows its prompt. Pump the run loop
            // while waiting (the completion may be delivered on the main queue) and never
            // block past the timeout.
            emit("microphone access not yet decided for this terminal — answer the system prompt (\(Int(microphonePromptTimeout)) s)…")
            var decided: Bool?
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { decided = granted }
            }
            let deadline = Date().addingTimeInterval(microphonePromptTimeout)
            while decided == nil, Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            switch decided {
            case true?: return
            case false?: fail(5, "microphone access was denied — allow it in System Settings › Privacy & Security › Microphone, then rerun")
            case nil: fail(5, "no answer to the microphone prompt within \(Int(microphonePromptTimeout)) s — rerun after deciding it")
            }
        default:
            fail(5, "microphone access is denied for this terminal app — allow it in System Settings › Privacy & Security › Microphone, then rerun")
        }
    }

    // MARK: - Click train

    private static func writeClickTrain(to path: String) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        let data = buffer.floatChannelData![0]
        let periodFrames = Int(period * sampleRate)
        let burstFrames = Int(clickBurst * sampleRate)
        var i = 0
        while i + burstFrames < Int(totalFrames) {
            for k in 0..<burstFrames {
                let envelope = sin(Double(k) / Double(burstFrames) * .pi)   // half-sine: band-limited enough not to splatter
                data[i + k] = clickAmplitude * Float(envelope * sin(2 * .pi * clickToneHz * Double(k) / sampleRate))
            }
            i += periodFrames
        }
        try file.write(from: buffer)
    }

    // MARK: - Recorder

    final class Recorder {
        private let engine = AVAudioEngine()
        private(set) var samples: [Float] = []
        private(set) var inputRate: Double = 0
        private(set) var startedAt = Date()
        var sampleCount: Int { samples.count }

        func start() throws {
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            inputRate = format.sampleRate
            guard inputRate > 0 else {
                throw NSError(domain: "eqym-ctl", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device"])
            }
            samples.reserveCapacity(Int((duration + preRoll + 5) * inputRate))
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                let n = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                for i in 0..<n {
                    var v: Float = 0
                    for c in 0..<channelCount { v += channels[c][i] }
                    self.samples.append(v / Float(channelCount))
                }
            }
            try engine.start()
            startedAt = Date()
        }

        func stop() { engine.stop() }

        func save(to path: String) {
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
                let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
                }
                try file.write(from: buffer)
            } catch {
                emit("(could not save the recording: \(error))")
            }
        }
    }

    // MARK: - Onset detection

    struct Detection {
        let onsets: [Double]        // seconds from the recording start
        let firstPassCount: Int
        let clickLevel: Float       // median peak of the first-pass onsets
        let threshold: Float        // second-pass threshold actually used
    }

    /// Two passes: the first with a noise-floor threshold finds the clicks and measures how
    /// loud they are; the second uses a threshold relative to that click level, so weaker
    /// transients (the toggle's mute/unmute discontinuity, keyboard, room) are not counted.
    private static func detectOnsets(_ x: [Float], rate: Double, noiseFloorSeconds: Double) -> Detection {
        let floorCount = Int(noiseFloorSeconds * rate)
        guard x.count > floorCount + Int(rate) else { return Detection(onsets: [], firstPassCount: 0, clickLevel: 0, threshold: 0) }
        // One-pole high-pass (~1 kHz) against rumble/hum, then rectify.
        let rc = 1.0 / (2 * .pi * 1_000)
        let alpha = Float(rc / (rc + 1 / rate))
        var envelope = [Float](repeating: 0, count: x.count)
        var previousIn: Float = 0, previousOut: Float = 0
        for i in 0..<x.count {
            let y = alpha * (previousOut + x[i] - previousIn)
            envelope[i] = abs(y); previousIn = x[i]; previousOut = y
        }
        let noise = envelope[0..<floorCount].reduce(0, +) / Float(floorCount)
        let baseThreshold = max(noise * 12, 0.01)
        let firstPass = pickOnsets(envelope, rate: rate, from: floorCount, threshold: baseThreshold)
        let peakSpan = Int(0.005 * rate)
        let peaks = firstPass.map { onset -> Float in
            let start = Int(onset * rate)
            return envelope[start..<min(envelope.count, start + peakSpan)].max() ?? 0
        }
        let clickLevel = median(peaks) ?? 0
        let threshold = max(baseThreshold, clickLevel * clickLevelFraction)
        let onsets = pickOnsets(envelope, rate: rate, from: floorCount, threshold: threshold)
        return Detection(onsets: onsets, firstPassCount: firstPass.count, clickLevel: clickLevel, threshold: threshold)
    }

    private static func pickOnsets(_ envelope: [Float], rate: Double, from start: Int, threshold: Float) -> [Double] {
        let refractoryCount = Int(refractory * rate)
        var onsets: [Double] = []
        var i = start
        while i < envelope.count {
            if envelope[i] > threshold {
                var j = i                                        // walk back to the true leading edge
                let back = max(start, i - Int(0.002 * rate))
                while j > back, envelope[j - 1] > threshold * 0.5 { j -= 1 }
                onsets.append(Double(j) / rate)
                i += refractoryCount
            } else {
                i += 1
            }
        }
        return onsets
    }

    private static func median<T: Comparable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Results file

    private static func appendResult(to path: String, fields: [String]) {
        let header = "when\tbuffer_frames\trate_hz\tdevice\tadded_ms_median\tn\tmin_ms\tmax_ms\tjitter_ms\trecording\n"
        let line = fields.joined(separator: "\t") + "\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: header.data(using: .utf8))
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
