// EQDeviceEngine lifecycle tests, driven entirely through FakeCoreAudioTapService (no
// real CoreAudio hardware/objects touched). Covers: start() success/failure (state
// sequence + call order + CONTRACT.md teardown order), live coefficient-update
// coalescing, the bypass-publish-before-startDevice ordering fix, and gain-staging's
// effect on the REAL RT signal path (via the fake's captured production IOProc block).
//
// Phase A of start() is synchronous; phase B (IOProc creation + startDevice + the
// transition to .running) is deferred ~0.3 s via DispatchQueue.main.asyncAfter (see
// EQDeviceEngine+Lifecycle.swift). Since EQDeviceEngine is @MainActor and on Darwin the
// MainActor's executor IS the main dispatch queue, a `@MainActor @Test func ... async`
// that `await`s past that delay lets the deferred closure run before the test resumes.
// Coalesced update() applies (~50 ms, EQDeviceEngine+LiveUpdate.swift) are awaited the same way.
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import eqYourMacbook

@MainActor
final class RecordingEngineDelegate: EQDeviceEngineDelegate {
    private(set) var states: [EngineState] = []
    private(set) var permissionSuspectedCount = 0
    var othersOutputtingAnswer = false

    func engine(_ engine: EQDeviceEngine, didChangeState state: EngineState) {
        states.append(state)
    }
    func engineSuspectsPermissionDenied(_ engine: EQDeviceEngine) {
        permissionSuspectedCount += 1
    }
    func anyOtherProcessOutputtingAudio(excluding processObjectID: AudioObjectID) -> Bool {
        othersOutputtingAnswer
    }
}

@MainActor
@Suite(.serialized) struct EQDeviceEngineLifecycleTests {

    private let testBand = EQBand(frequency: 1000, gain: 3, bandwidth: 1.0, filterType: .parametric)

    // MARK: - start() success: EngineState sequence + CoreAudio call order

    @Test func startSucceedsAndTransitionsToRunning() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 42, deviceUID: "dev-1", deviceName: "Device 1", tapService: fake, hogModeMonitor: nil)
        let delegate = RecordingEngineDelegate()
        engine.delegate = delegate

        engine.start(bands: [testBand])
        // Phase A is synchronous and does not itself transition state; only finishStart()
        // (deferred) or failStart() (synchronous, on throw) do.
        #expect(engine.state == .stopped)

        try await Task.sleep(for: .milliseconds(400))

        #expect(engine.state == .running)
        // Exactly one delegate notification: .stopped's initial assignment doesn't fire
        // `didSet`, so the only transition observed is .stopped -> .running.
        #expect(delegate.states == [.running])
        #expect(fake.callLog == [
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .getDeviceNominalSampleRate, .createIOProcIDWithBlock, .startDevice,
        ])

        engine.stop()   // tidy up the watchdog timer rather than leaving it orphaned
    }

    // MARK: - start() failure: each CoreAudio call site in performStart()

    @Test func startFailsWhenProcessTapCreationFails() {
        let fake = FakeCoreAudioTapService()
        fake.failCreateProcessTap = true
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)

        engine.start(bands: [testBand])

        guard case .failed(let message) = engine.state else {
            Issue.record("expected .failed, got \(engine.state)"); return
        }
        #expect(message.hasPrefix("Failed to create process tap"))
        // Nothing beyond the failing call was attempted — no cleanup needed since
        // nothing was created yet.
        #expect(fake.callLog == [.hoggingProcessObjectIDs, .createProcessTap])
    }

    @Test func startFailsWhenAggregateCreationFails() {
        let fake = FakeCoreAudioTapService()
        fake.failCreateAggregateDevice = true
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)

        engine.start(bands: [testBand])

        guard case .failed(let message) = engine.state else {
            Issue.record("expected .failed, got \(engine.state)"); return
        }
        #expect(message.hasPrefix("Failed to create aggregate device"))
        // The tap WAS created before the aggregate creation failed, so failStart's
        // teardownCoreAudio() must clean it up — proving partial-failure cleanup still
        // respects the destroy-what-exists rule.
        #expect(fake.callLog == [
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .destroyProcessTap,
        ])
    }

    @Test func startFailsWhenStreamFormatUnreadable() {
        let fake = FakeCoreAudioTapService()
        fake.streamFormatToReturn = nil
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)

        engine.start(bands: [testBand])

        guard case .failed(let message) = engine.state else {
            Issue.record("expected .failed, got \(engine.state)"); return
        }
        #expect(message.hasPrefix("Could not read aggregate device stream format"))
        // Tap AND aggregate were both created before the format read failed; both must
        // be torn down, aggregate-before-tap (CONTRACT.md order).
        #expect(fake.callLog == [
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .destroyAggregateDevice, .destroyProcessTap,
        ])
    }

    @Test func startFailsWhenStreamFormatChannelCountMismatches() {
        let fake = FakeCoreAudioTapService()
        var badFormat = FakeCoreAudioTapService.validFloat32StereoFormat
        badFormat.mChannelsPerFrame = 1   // engine assumes EQCoefficients.channels == 2
        fake.streamFormatToReturn = badFormat
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)

        engine.start(bands: [testBand])

        guard case .failed(let message) = engine.state else {
            Issue.record("expected .failed, got \(engine.state)"); return
        }
        #expect(message.hasPrefix("Unsupported audio format"))
        #expect(fake.callLog == [
            .hoggingProcessObjectIDs, .createProcessTap, .createAggregateDevice, .getStreamFormat,
            .destroyAggregateDevice, .destroyProcessTap,
        ])
    }

    // MARK: - stop(): CONTRACT.md-documented strict teardown order

    @Test func stopTearsDownInContractOrder() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)

        engine.stop()

        #expect(engine.state == .stopped)
        #expect(fake.callLog.suffix(4) == [
            .stopDevice, .destroyIOProcID, .destroyAggregateDevice, .destroyProcessTap,
        ])
    }

    // MARK: - update(bands:): coalesced apply lands the expected coefficients in the RT
    // handoff buffer, and the fake's captured IOProc block actually consumes them.

    @Test func updateAfterCoalesceIntervalWritesExpectedPendingCoefficients() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)
        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .running)

        let newBands = [EQBand(frequency: 500, gain: -6, bandwidth: 1.0, filterType: .lowShelf)]
        engine.update(bands: newBands)
        // Immediately after update(): latest-wins bands stashed, apply not yet flushed.
        #expect(engine.pendingUpdateBands == newBands)

        // Coalesce interval is 50 ms; wait past it.
        try await Task.sleep(for: .milliseconds(150))

        #expect(engine.pendingUpdateBands == nil)
        let context = try #require(engine.rtContext)
        #expect(context.pendingFlag == 1, "flushPendingUpdate() must have published (RT hasn't consumed it — no real IOProc is running)")

        let expected = EQCoefficients.sectionCoefficients(
            for: newBands, sampleRate: engine.currentSampleRate,
            masterGainDB: EQCoefficients.masterGainDB(for: newBands, enabled: engine.gainStagingEnabled))
        let pending = try #require(context.pendingCoeffs)
        for i in 0..<expected.count {
            #expect(abs(pending[i] - expected[i]) <= 1e-9, "pendingCoeffs[\(i)] mismatch")
        }

        // Drive the REAL captured IOProc block once so it consumes the pending update,
        // proving the full producer -> RT-consumer round-trip (not just the producer side).
        let block = try #require(fake.capturedIOBlock)
        let input = TestAudioBuffer(frameCount: 64, channels: 2, samples: nil)
        let output = TestAudioBuffer(frameCount: 64, channels: 2, samples: nil)
        invokeIOBlock(block, input: input, output: output)
        #expect(context.pendingFlag == 0, "the IOProc block must consume (zero) the pending flag on its next callback")

        engine.stop()   // tidy up the watchdog timer rather than leaving it orphaned
    }

    // MARK: - Bypass ordering: context.bypass must already reflect isBypassed by the
    // time startDevice() is called (i.e. before the IOProc can possibly fire on real
    // hardware) — regression test for the bypass-publish-ordering fix documented in
    // EQDeviceEngine+Lifecycle.swift's finishStart().

    @Test func bypassSetBeforeStartIsPublishedToContextBeforeStartDevice() async throws {
        let fake = FakeCoreAudioTapService()
        let engine = EQDeviceEngine(deviceID: 1, deviceUID: "dev", deviceName: "Device", tapService: fake, hogModeMonitor: nil)

        engine.isBypassed = true
        #expect(engine.bypassIntent)   // main-actor SSOT updated immediately, even while stopped

        var bypassAtStartDeviceCall: Int32?
        fake.onCall = { [weak engine] call in
            guard call == .startDevice else { return }
            bypassAtStartDeviceCall = engine?.rtContext?.bypass
        }

        engine.start(bands: [testBand])
        try await Task.sleep(for: .milliseconds(400))

        #expect(engine.state == .running)
        // The regression this guards against: if context.bypass were (re-)published
        // AFTER tapService.startDevice() instead of before, this would observe 0 here —
        // a window where the RT thread could run un-bypassed despite isBypassed == true.
        #expect(bypassAtStartDeviceCall == 1)
        #expect(engine.rtContext?.bypass == 1)

        engine.stop()   // tidy up the watchdog timer rather than leaving it orphaned
    }

    // MARK: - Gain-staging: enable/disable changes the effective master gain folded into
    // coefficients, verified on the REAL RT signal path (the fake's captured production
    // IOProc block), not a parallel coefficient comparison.

    @Test func gainStagingFoldsExactMasterGainIntoRTSignal() async throws {
        // +18 dB peaking band: gain-staging (enabled) computes masterGainDB(enabled: true)
        // == -18 (attenuate by the largest positive band gain), vs 0 when disabled. Since
        // scaling only section 0's b-terms by a constant linear factor scales H(z) by that
        // same constant at EVERY frequency, the difference between the two configurations'
        // measured gain at ANY probe frequency must be exactly +18 dB — an exact,
        // hand-derivable fact, not an approximation.
        let band = EQBand(frequency: 1000, gain: 18, bandwidth: 1.0, filterType: .parametric)

        let fakeEnabled = FakeCoreAudioTapService()
        let engineEnabled = EQDeviceEngine(deviceID: 1, deviceUID: "gs-enabled", deviceName: "GS Enabled", tapService: fakeEnabled, hogModeMonitor: nil)
        engineEnabled.gainStagingEnabled = true
        engineEnabled.start(bands: [band])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engineEnabled.state == .running)
        let gainEnabledDB = measureEngineGainDB(fake: fakeEnabled, probeFrequency: 1000)
        engineEnabled.stop()

        let fakeDisabled = FakeCoreAudioTapService()
        let engineDisabled = EQDeviceEngine(deviceID: 2, deviceUID: "gs-disabled", deviceName: "GS Disabled", tapService: fakeDisabled, hogModeMonitor: nil)
        engineDisabled.gainStagingEnabled = false
        engineDisabled.start(bands: [band])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engineDisabled.state == .running)
        let gainDisabledDB = measureEngineGainDB(fake: fakeDisabled, probeFrequency: 1000)
        engineDisabled.stop()

        #expect(abs((gainDisabledDB - gainEnabledDB) - 18.0) <= 0.5,
                Comment(rawValue: "expected exactly +18 dB delta (the band's own gain, since it's fully " +
                "compensated when gain-staging is enabled): disabled=\(gainDisabledDB) " +
                "enabled=\(gainEnabledDB)"))
    }

    // MARK: - Helpers

    private func measureEngineGainDB(fake: FakeCoreAudioTapService, probeFrequency: Double,
                                      sampleRate: Double = 48_000, frameCount: Int = 4096,
                                      discard: Int = 1024) -> Double {
        guard let block = fake.capturedIOBlock else {
            Issue.record("expected capturedIOBlock to be set after a successful start()")
            return .nan
        }
        let inputSamples = makeSineWave(frequency: probeFrequency, sampleRate: sampleRate, frameCount: frameCount)
        let input = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: inputSamples)
        let output = TestAudioBuffer(frameCount: frameCount, channels: 2, samples: nil)
        invokeIOBlock(block, input: input, output: output)
        let inFlat = input.samples; let outFlat = output.samples
        var inSteady: [Float] = []; var outSteady: [Float] = []
        for n in discard..<frameCount { inSteady.append(inFlat[n * 2]); outSteady.append(outFlat[n * 2]) }
        return 20 * log10(rms(outSteady) / rms(inSteady))
    }
}
