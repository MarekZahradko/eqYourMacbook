# Module contract — eqYourMacbook

This file is the SSOT for the API surface between `Sources/Engine` and
`Sources/App`. Both sides are written by different agents in parallel; neither
may deviate from these signatures without updating this file first.

Shared model types live in `Sources/Model/EQModels.swift` (cherry-picked from
iqualize, MIT): `FilterType`, `EQBand`, `EQPresetData`. Coefficient math lives
in `Sources/Model/BiquadResponse.swift` (cherry-picked, MIT).

Language: Swift 6 language mode, default isolation `nonisolated` (see
`scripts/build-config.sh`). Frameworks allowed: CoreAudio, AudioToolbox,
Accelerate, Foundation, AppKit, SwiftUI, ServiceManagement. No third-party
dependencies.

## Engine module (`Sources/Engine/`)

Coefficient math lives in a standalone, non-actor-isolated `EQCoefficients` enum
(`Sources/Engine/EQCoefficients.swift`) so both `EQDeviceEngine` and the RT IOProc
factory can reach it without depending on the full engine class:

```swift
enum EQCoefficients {
    static let maxSections: Int   // 16
    static let channels: Int      // 2
    static func flatIndex(section: Int, channel: Int, channels: Int) -> Int
    static func sectionCoefficients(for bands: [EQBand], sampleRate: Double,
                                     channels: Int = EQCoefficients.channels,
                                     masterGainDB: Double = 0) -> [Double]
    static func masterGainDB(for bands: [EQBand], enabled: Bool) -> Double
}
```

Per-device RT (real-time thread) state lives in a `final class EQDeviceRTContext`
(`Sources/Engine/EQDeviceRTContext.swift`) — a REFERENCE type, not a struct, because
it is captured by a concurrently-running IOProc block and must never relocate. Each
`EQDeviceEngine` owns exactly one. `makeIOBlock(context:) -> AudioDeviceIOBlock`
builds the IOProc closure bound to one context — this replaces the old single-instance
file-private `rt*` globals + one shared `rtIOBlock`, now that N devices can run
concurrently (§5).

```swift
import CoreAudio

enum EngineState: Equatable {
    case stopped              // no tap, zero footprint
    case running              // tap + aggregate + IOProc active, EQ applied
    case failed(String)       // last start() attempt failed
}

@MainActor protocol EQDeviceEngineDelegate: AnyObject {
    func engine(_ engine: EQDeviceEngine, didChangeState state: EngineState)
    // Watchdog rebuilt once and input is still all-zero → TCC denial likely.
    func engineSuspectsPermissionDenied(_ engine: EQDeviceEngine)
    // Lets the coordinator answer this once (short-TTL cached) for all engines'
    // watchdogs instead of each engine re-querying the CoreAudio process list.
    func anyOtherProcessOutputtingAudio(excluding processObjectID: AudioObjectID) -> Bool
}

@MainActor final class EQDeviceEngine {
    // Target device is injected, not discovered internally — the caller
    // (OutputDeviceEQCoordinator) decides which device this instance EQs.
    let deviceID: AudioObjectID
    let deviceUID: String
    let deviceName: String

    weak var delegate: EQDeviceEngineDelegate?
    private(set) var state: EngineState   // = .stopped initially

    init(deviceID: AudioObjectID, deviceUID: String, deviceName: String,
         tapService: CoreAudioTapServicing = LiveCoreAudioTapService())

    // Idempotent. Builds: own-PID-excluded global tap (mute-on-tap) → private
    // aggregate (THIS instance's deviceUID = main sub-device + tap in CREATION
    // dict) → IOProc (input → vDSP_biquadm → output).
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
    var gainStagingEnabled: Bool { get set }
}
```

`CoreAudioTapServicing` (`Sources/Engine/CoreAudioTapServicing.swift`) is a narrow testability
seam wrapping the CoreAudio calls `start()`/`stop()` make (create/destroy tap,
create/destroy aggregate, create/destroy IOProc, start/stop device), plus the two read-only
CoreAudio queries `performStart()` depends on for its format-verification/sample-rate steps
(`getStreamFormat`, `getDeviceNominalSampleRate` — mirroring the free functions of the same
name in `CoreAudioHelpers.swift`, which `LiveCoreAudioTapService` forwards to unchanged).
Without these two also going through the seam, a test double could never reach `.running`
(a synthetic aggregate device ID isn't a real HAL object, so the un-mediated
`AudioObjectGetPropertyData` read always fails) nor simulate a format-mismatch failure.
`LiveCoreAudioTapService` is the default, real implementation; production call sites never
pass anything else.

IMPORTANT (open risk, §5): a `stereoGlobalTapButExcludeProcesses` tap captures ALL
system audio (minus this app's own process). N enabled devices → N taps, all seeing
the SAME source signal, each independently EQ'd and routed to its own device — this is
intentional ("apply this app's EQ to this output"), not per-device source routing.

Engine semantics (internal, not negotiable):
- Engine NEVER decides policy (when to run) — `OutputDeviceEQCoordinator` does.
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
- Watchdog ↔ delegate idempotency (the coordinator treats repeated `.running`
  notifications as idempotent — it MUST keep doing so):
  - After a successful silent rebuild the engine fires
    `didChangeState(.running)` UNCONDITIONALLY (bypassing the internal state-equality
    guard, since state stayed `.running` throughout the rebuild) so the coordinator
    knows the chain is healthy again.
  - When the watchdog later observes max-abs > 0 while a permission-suspected
    condition had been raised, the engine clears that internal suspicion and fires
    `didChangeState(.running)` again so the coordinator can clear its
    `permissionNeeded` status for that device.
- Sleep/wake: engine observes `NSWorkspace.didWakeNotification` while running
  and schedules a rebuild ~1 s after wake (iqualize-proven timing).

```swift
struct OutputDeviceInfo: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

@MainActor final class OutputDeviceCatalog {
    private(set) var devices: [OutputDeviceInfo]
    var onDevicesChanged: (([OutputDeviceInfo]) -> Void)?   // fired on main actor
    func start()   // listener on kAudioHardwarePropertyDevices; also does initial enumerate()
    func stop()
}
```

Enumeration: every device with output streams (`deviceHasOutputStreams`), excluding
transport type `kAudioDeviceTransportTypeAggregate` (this app's own private aggregates
report as aggregate transport — VERIFY ON FIRST MAC BUILD that they don't otherwise
surface here). Built-in (`kAudioDeviceTransportTypeBuiltIn`) sorted first; remainder in
HAL-returned order, not alphabetized.

## App module (`Sources/App/`)

```swift
struct DeviceRowViewModel: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let isBuiltIn: Bool
    var isChecked: Bool     // user intent (persisted via enabledDeviceUIDs)
    var isRunning: Bool     // engine.state == .running right now
}

struct AggregateEngineStatus: Equatable {
    var anyRunning: Bool
    var permissionNeeded: Bool
    var errorMessage: String?
}

/// Testability seam: EQController depends on this protocol, not the concrete
/// class, so tests can substitute a fake instead of a live coordinator (which
/// would otherwise register a real CoreAudio device listener and start taps).
@MainActor protocol OutputDeviceEQCoordinating: AnyObject {
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)? { get set }
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)? { get set }
    func start()
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID)
    func setGloballyEnabled(_ enabled: Bool)
    func updateBands(_ bands: [EQBand])
    func updateBypass(_ bypassed: Bool)
    func setGainStagingEnabled(_ enabled: Bool)
}

@MainActor final class OutputDeviceEQCoordinator: EQDeviceEngineDelegate, OutputDeviceEQCoordinating {
    private(set) var deviceRows: [DeviceRowViewModel]
    private(set) var enabledDeviceUIDs: Set<String>   // persisted, keyed by device UID
    var onDeviceRowsChanged: (([DeviceRowViewModel]) -> Void)?
    var onAggregateStatusChanged: ((AggregateEngineStatus) -> Void)?

    func start()
    func stop()
    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID)
    func setGloballyEnabled(_ enabled: Bool)     // master on/off, gates all reconciliation
    func updateBands(_ bands: [EQBand])          // fans out to every running engine
    func updateBypass(_ bypassed: Bool)
    func setGainStagingEnabled(_ enabled: Bool)
}
```

Delegate-forwarding design: `OutputDeviceEQCoordinator` is the single
`EQDeviceEngineDelegate` for every `EQDeviceEngine` it creates (one coordinator
instance standing in for N engines). Each callback identifies its device via
`engine.deviceID`; the coordinator tracks per-device `EngineState`/permission-suspected
flags and collapses them into one `AggregateEngineStatus`, published via
`onAggregateStatusChanged`. `EQController` consumes only that aggregate, plus
`deviceRows` for the per-device checkbox list — it does not implement the delegate
protocol itself.

Reconciliation (`reconcile()`, private): for each catalog device whose UID is in
`enabledDeviceUIDs` and the master switch is on, with no running engine → create
`EQDeviceEngine(deviceID:deviceUID:deviceName:)`, start it. For each running engine
whose device disappeared from the catalog → stop it, remove from the running set,
but KEEP its UID in `enabledDeviceUIDs` (replugging auto-resumes). For a device the
user explicitly unchecked → stop it and remove its UID from `enabledDeviceUIDs`. A
soft cap (`maxSimultaneousDevices = 4`) bounds how many engines run at once — N
concurrent aggregate+tap+IOProc sets is architecturally supported but UNVERIFIED on
real hardware (needs manual multi-device testing on first Mac build).

Persistence: `enabledDeviceUIDs` — `UserDefaults.standard`, key
`eqym.enabledDeviceUIDs`, JSON-encoded `[String]` (UIDs, not `AudioObjectID`s, since
object IDs are session-scoped/unstable across reboot+replug). First launch: seeded
with just the built-in speakers' UID once the catalog discovers it.

```swift
@MainActor final class EQController: ObservableObject {
    @Published var isEnabled: Bool          // master switch, persisted
    @Published var bands: [EQBand]          // persisted; pushes coordinator.updateBands
    @Published var isABBypassed: Bool       // forwards to coordinator.updateBypass
    @Published var gainStagingEnabled: Bool // forwards to coordinator.setGainStagingEnabled
    @Published private(set) var deviceRows: [DeviceRowViewModel]
    var launchAtLogin: Bool                 // computed; SMAppService is the SSOT,
                                            // sends objectWillChange manually
    @Published private(set) var status: DisplayStatus

    func setDeviceEnabled(_ enabled: Bool, deviceID: AudioObjectID)

    init(coordinator: OutputDeviceEQCoordinating = OutputDeviceEQCoordinator(),
         defaults: UserDefaults = .standard)
    nonisolated static func statusDetail(for status: DisplayStatus, runningDeviceCount: Int) -> String
    var statusDetail: String { get }   // = Self.statusDetail(for: status, runningDeviceCount:)
}

enum DisplayStatus: Equatable {
    case active            // master enabled; per-device rows show running detail
    case disabled          // user switched off
    case permissionNeeded  // any engine's watchdog suspects TCC denial
    case error(String)
}
```

Engage policy: there is no single "route" anymore (any number of devices can run
simultaneously) — engagement is per-device, driven by each `DeviceRowView` checkbox
and reconciled by `OutputDeviceEQCoordinator`. `isEnabled` is the master kill switch:
`false` stops every running engine regardless of checkbox state; `true` reconciles
per checkbox state. `DisplayStatus.active` means only "master switch is on" — it does
NOT imply every checked device is currently running (see `deviceRows[].isRunning` for
that, and `EQController.statusDetail` for the human-readable running count).

Persistence: `UserDefaults.standard`, keys prefixed `eqym.` (`eqym.bands`,
`eqym.isEnabled`, `eqym.customPresets`), JSON-encoded via Codable. Band count
limit in UI: 0–16 (zero bands = identity passthrough; the Flat preset is empty;
the 16 ceiling is `EQPresetData.maxBandCount`, which `EQCoefficients.maxSections`
mirrors — see Engine module section above).
Gain UI range ±24 dB, canonically `EQBand.gainRange` (Sources/Model/EQModels.swift);
`EQCurveView.UIConstants.maxGainDB` derives from its `upperBound` rather than
re-declaring 24 independently.

UI per PLAN.md: `MenuBarExtra` `.window` style, curve Canvas (|H(f)| evaluated
from biquad coefficients over log grid 20 Hz–20 kHz), band rows, master toggle,
A/B button, presets menu, launch-at-login toggle, status footer. No timers, no
polling anywhere in the app layer.

Built-in presets (replace iqualize's set): `Flat`, and default
`MBA tame-the-highs` = high-shelf −4 dB @ 8 kHz (Q 0.9) + peaking −2 dB @
2.5 kHz (Q 1.0).
