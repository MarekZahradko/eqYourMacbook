// Watches everything that can change the tap's process-exclusion set and reports
// (debounced) when it may have moved. Purely a notification source — the decision to
// rebuild lives in EQDeviceEngine.rebuildIfTapExclusionsStale(), which re-reads both
// sources and compares.
//
// Two independent sources, both of which must keep a process OUT of the global tap:
//
//   1. Hog mode (exclusive access). A process taking hog mode makes macOS re-route the
//      default output elsewhere, which is what lets an engine start on (say) the built-in
//      speakers while the hogging process is still playing to the device it locked. The
//      global tap would then capture and mute that process, hijacking its audio onto our
//      device. The default-output-route listener is NOT sufficient here: hog mode can be
//      taken or released without the default route moving at all.
//
//   2. Voice sessions (a process running input and output at once — a call). macOS runs
//      those through VoiceProcessingIO, which ducks all "other audio"; tapping such a
//      process moves its call audio into OUR process, where the OS then ducks it as
//      "other audio" and the call ducks itself. See CoreAudioHelpers.swift's
//      voiceSessionProcessObjectIDs() for the full rationale.
//
// Debounced because a single user-visible event flips several properties in a burst:
// answering a call turns a process's input and output streams on a few hundred ms apart,
// and each notification would otherwise drive its own full tap+aggregate rebuild — an
// audible gap each time. One coalesced report per burst instead.

import CoreAudio
import Foundation
import os.log

@MainActor final class TapExclusionMonitor {

    /// Trailing-edge coalescing window. Long enough to swallow the property burst a call
    /// start/end produces, short enough that the caller is still ducked for well under a
    /// second. Same latest-wins shape as EQDeviceEngine's update coalescing.
    static let coalesceInterval: TimeInterval = 0.5

    private var onChange: (() -> Void)?
    private var coalesceScheduled = false

    /// One hog-mode listener per output device, keyed by device so re-syncing after a
    /// device-list change can add/remove exactly the difference.
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// Both IO-flag listeners per process object, keyed the same way. A call typically
    /// starts on a process that ALREADY exists (it played notification sounds), so the
    /// process-list listener alone would not see it — the per-process flags are what
    /// makes the reaction prompt rather than waiting for the watchdog's 5 s backstop.
    private struct ProcessListeners {
        let input: AudioObjectPropertyListenerBlock
        let output: AudioObjectPropertyListenerBlock
    }
    private var processListeners: [AudioObjectID: ProcessListeners] = [:]
    private var processListListener: AudioObjectPropertyListenerBlock?

    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var hogModeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyHogMode,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var isRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var isRunningOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {}

    /// Idempotent: a second call while already running just replaces the callback.
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        syncDeviceListeners()
        syncProcessListeners()

        if deviceListListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Registered on DispatchQueue.main below, so this already runs on main.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A hot-plugged device may already be hogged, and an unplugged one may
                    // have been the only hog holder — both change the exclusion set, so
                    // re-register AND report.
                    os_log(.info, log: engineLog, "exclusion monitor: device list changed")
                    self.syncDeviceListeners()
                    self.reportChange()
                }
            }
            deviceListListener = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, DispatchQueue.main, block)
        }

        if processListListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A process that just appeared may already be duplex (an app launched
                    // straight into a call), and one that vanished may have been the only
                    // voice session — same reasoning as the device list above.
                    os_log(.info, log: engineLog, "exclusion monitor: process list changed")
                    self.syncProcessListeners()
                    self.reportChange()
                }
            }
            processListListener = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &processListAddress, DispatchQueue.main, block)
        }
    }

    /// Idempotent. Removes every listener installed by start(). A coalesced report still
    /// in flight is neutralized by clearing `onChange` (the closure no-ops), so there is
    /// no timer to cancel.
    func stop() {
        for (device, block) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        for (process, blocks) in processListeners {
            AudioObjectRemovePropertyListenerBlock(process, &isRunningInputAddress, DispatchQueue.main, blocks.input)
            AudioObjectRemovePropertyListenerBlock(process, &isRunningOutputAddress, DispatchQueue.main, blocks.output)
        }
        processListeners.removeAll()
        if let block = deviceListListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, DispatchQueue.main, block)
            deviceListListener = nil
        }
        if let block = processListListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &processListAddress, DispatchQueue.main, block)
            processListListener = nil
        }
        onChange = nil
    }

    // MARK: - Coalescing

    /// One report per burst: the first notification schedules it, the rest fold into that
    /// same pending report. Bounded by construction (the deadline is never pushed back),
    /// so a process flapping its IO flags cannot starve the report indefinitely.
    private func reportChange() {
        guard !coalesceScheduled else { return }
        coalesceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coalesceScheduled = false
                self.onChange?()
            }
        }
    }

    // MARK: - Listener re-sync

    /// Bring the per-device hog listeners in line with the current output-device set.
    private func syncDeviceListeners() {
        let current = Set((try? getAllDeviceIDs())?.filter(deviceHasOutputStreams) ?? [])

        for device in deviceListeners.keys where !current.contains(device) {
            if let block = deviceListeners.removeValue(forKey: device) {
                AudioObjectRemovePropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
            }
        }
        for device in current where deviceListeners[device] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    os_log(.info, log: engineLog, "exclusion monitor: hog mode changed on device %u", device)
                    self?.reportChange()
                }
            }
            deviceListeners[device] = block
            AudioObjectAddPropertyListenerBlock(device, &hogModeAddress, DispatchQueue.main, block)
        }
    }

    /// Bring the per-process IO-flag listeners in line with the current process set.
    private func syncProcessListeners() {
        let current = Set(allProcessObjectIDs())

        for process in processListeners.keys where !current.contains(process) {
            if let blocks = processListeners.removeValue(forKey: process) {
                AudioObjectRemovePropertyListenerBlock(process, &isRunningInputAddress, DispatchQueue.main, blocks.input)
                AudioObjectRemovePropertyListenerBlock(process, &isRunningOutputAddress, DispatchQueue.main, blocks.output)
            }
        }
        // MEASURED 2026-09-06 (10 h, 2 FaceTime calls): these per-process IsRunningInput
        // listeners fired ZERO times, including for the daemon that entered the call
        // (com.apple.avconferenced, already running, so the process-list listener cannot
        // fire for it either). The HAL simply does not deliver a notification when an
        // EXISTING process object flips to duplex — so the exclusion set's effective
        // primary path for a starting call is EQDeviceEngine's polling backstop, not these
        // listeners (CLAUDE.md § Invariants). Kept anyway: they cost nothing while quiet,
        // one build only reported them 0×, and a future macOS may deliver them. Logged at
        // info level so the next investigation can see at a glance whether that changed.
        for process in current where processListeners[process] == nil {
            let input: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    os_log(.info, log: engineLog, "exclusion monitor: input flag changed on process %u", process)
                    self?.reportChange()
                }
            }
            let output: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    os_log(.info, log: engineLog, "exclusion monitor: output flag changed on process %u", process)
                    self?.reportChange()
                }
            }
            processListeners[process] = ProcessListeners(input: input, output: output)
            AudioObjectAddPropertyListenerBlock(process, &isRunningInputAddress, DispatchQueue.main, input)
            AudioObjectAddPropertyListenerBlock(process, &isRunningOutputAddress, DispatchQueue.main, output)
        }
    }
}
