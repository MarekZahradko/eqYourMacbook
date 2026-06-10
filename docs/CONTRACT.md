# Module contract — eqYourMacbook

This file is the SSOT for the API surface between `Sources/Engine` and
`Sources/App`. Both sides are written by different agents in parallel; neither
may deviate from these signatures without updating this file first.

Shared model types live in `Sources/Model/EQModels.swift` (cherry-picked from
iqualize, MIT): `FilterType`, `EQBand`, `EQPresetData`. Coefficient math lives
in `Sources/Model/BiquadResponse.swift` (cherry-picked, MIT).

Language: Swift 5 language mode (NOT Swift 6 strict concurrency — we code
without a compiler; v5 mode minimizes blind-coding hazards). Frameworks allowed:
CoreAudio, AudioToolbox, Accelerate, Foundation, AppKit, SwiftUI,
ServiceManagement. No third-party dependencies.

## Engine module (`Sources/Engine/`)

```swift
import CoreAudio

enum EngineState: Equatable {
    case stopped              // no tap, zero footprint
    case running              // tap + aggregate + IOProc active, EQ applied
    case failed(String)       // last start() attempt failed
}

enum OutputRoute: Equatable {
    case builtInSpeakers(AudioObjectID)
    case other(String)        // human-readable device name
}

@MainActor protocol EQEngineDelegate: AnyObject {
    func engine(_ engine: EQEngine, didChangeState state: EngineState)
    // Watchdog rebuilt once and input is still all-zero → TCC denial likely.
    func engineSuspectsPermissionDenied(_ engine: EQEngine)
}

@MainActor final class EQEngine {
    weak var delegate: EQEngineDelegate?
    private(set) var state: EngineState   // = .stopped initially

    // Idempotent. Builds: own-PID-excluded global tap (mute-on-tap) → private
    // aggregate (built-in speakers = main sub-device + tap in CREATION dict)
    // → IOProc (input → vDSP_biquadm → output). Finds built-in speakers itself.
    func start(bands: [EQBand])

    // Idempotent. Full teardown, strict order: AudioDeviceStop →
    // AudioDeviceDestroyIOProcID → AudioHardwareDestroyAggregateDevice →
    // AudioHardwareDestroyProcessTap → THEN release RT-shared buffers/refs.
    // (Fixes iqualize's nil-while-callback-running race.)
    func stop()

    // Live coefficient swap, no restart, no glitch. Callable at slider-drag
    // rate (~60 Hz); engine may coalesce. RT thread never blocks on this.
    func update(bands: [EQBand])

    // Instant A/B compare: identity passthrough without teardown.
    // RT-safe atomic flag read in the IO callback.
    var isBypassed: Bool { get set }
}
```

Engine semantics (internal, not negotiable):
- Engine NEVER decides policy (when to run) — the controller does.
- RT callback rules: no allocation, no locks, no logging, no Objective-C/Swift
  runtime calls; pre-allocated buffers sized at start(); max 16 biquad sections
  pre-allocated, unused sections set to identity.
- Watchdog: DispatchSourceTimer, 5 s period, only while `.running`. Tracks an
  atomically-written max-abs-sample (RUNNING max, reset each tick) + callback
  counter from the IO callback. A check counts as silent only when callbacks are
  advancing AND max == 0 AND some OTHER process is actually outputting audio
  (`anyOtherProcessOutputtingAudio`, excluding our own process object) — zeros are
  legitimate when nothing is playing and must not trip the watchdog. 2 consecutive
  silent checks → one silent rebuild (stop+start); if silence persists after the
  rebuild → `engineSuspectsPermissionDenied`. Watchdog timer must not run when stopped.
- Watchdog ↔ delegate idempotency (the controller treats repeated `.running`
  notifications as idempotent — it MUST keep doing so):
  - After a successful silent rebuild the engine fires
    `didChangeState(.running)` UNCONDITIONALLY (bypassing the internal state-equality
    guard, since state stayed `.running` throughout the rebuild) so the controller
    knows the chain is healthy again.
  - When the watchdog later observes max-abs > 0 while a permission-suspected
    condition had been raised, the engine clears that internal suspicion and fires
    `didChangeState(.running)` again so the controller can clear its
    `permissionNeeded` status.
- Sleep/wake: engine observes `NSWorkspace.didWakeNotification` while running
  and schedules a rebuild ~1 s after wake (iqualize-proven timing).

```swift
@MainActor final class DeviceWatcher {
    private(set) var currentRoute: OutputRoute
    var onRouteChange: ((OutputRoute) -> Void)?   // fired on main actor
    func start()   // listener on kAudioHardwarePropertyDefaultOutputDevice
    func stop()
}
```

Built-in detection: default output device's `kAudioDevicePropertyTransportType
== kAudioDeviceTransportTypeBuiltIn` (and has output streams).

## App module (`Sources/App/`)

```swift
@MainActor final class EQController: ObservableObject, EQEngineDelegate {
    @Published var isEnabled: Bool          // master switch, persisted
    @Published var bands: [EQBand]          // persisted; pushes engine.update
    @Published var isABBypassed: Bool       // forwards to engine.isBypassed
    var launchAtLogin: Bool                 // computed; SMAppService is the SSOT,
                                            // sends objectWillChange manually
    @Published private(set) var status: DisplayStatus
}

enum DisplayStatus: Equatable {
    case active                       // engaged on built-in speakers
    case standby(otherOutput: String) // auto-bypassed: not on built-ins
    case disabled                     // user switched off
    case permissionNeeded             // from engineSuspectsPermissionDenied
    case error(String)
}
```

Engage policy (single source of truth, in EQController):
`isEnabled && currentRoute is .builtInSpeakers` → `engine.start(bands:)`,
otherwise `engine.stop()`. Re-evaluated on: isEnabled change, route change,
app launch.

Persistence: `UserDefaults.standard`, keys prefixed `eqym.` (`eqym.bands`,
`eqym.isEnabled`, `eqym.customPresets`), JSON-encoded via Codable. Band count
limit in UI: 0–16 (zero bands = identity passthrough; the Flat preset is empty).
Gain UI range ±24 dB (constant `maxGainDB` in one place).

UI per PLAN.md: `MenuBarExtra` `.window` style, curve Canvas (|H(f)| evaluated
from biquad coefficients over log grid 20 Hz–20 kHz), band rows, master toggle,
A/B button, presets menu, launch-at-login toggle, status footer. No timers, no
polling anywhere in the app layer.

Built-in presets (replace iqualize's set): `Flat`, and default
`MBA tame-the-highs` = high-shelf −4 dB @ 8 kHz (Q 0.9) + peaking −2 dB @
2.5 kHz (Q 1.0).
