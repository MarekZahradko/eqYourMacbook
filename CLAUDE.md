# eqYourMacbook — project instructions

Menu-bar system-wide EQ on the driverless macOS Core Audio process-tap API (no
HAL driver, no pkg, no root). The user checks ONE output device to EQ (mutually
exclusive; built-in speakers seeded on first launch); its engine runs only while
that device is also the OS's default-output route. The app never changes routing.
Personal-use app, owner: Zdeněk (writes Czech; all code, comments, docs in English).

The code is the SSOT. Facts not derivable from it are in § Invariants below —
code comments citing "§ Invariants" point there. Keep it in sync with deliberate
behavior changes.

## Build

`swiftc` directly — Command Line Tools are enough, no Xcode.app. Never introduce
`xcodebuild`/`xcodegen`/`.xcodeproj` on the build path. Tests run via a
`TestRunner` executable, not `swift test` (XCTest needs Xcode.app; Testing ships
with CLT).

```
./build.sh            # -> .build/eqYourMacbook.app (Debug)
./test.sh             # build + run eqYourMacbookTestRunner
./install.sh          # test + build + install to /Applications + launch
./run.sh              # open the built app
scripts/release.sh    # --release + zip in build/dist/ (CI)
```

Root = daily entry points. `scripts/` = the rest: `build-config.sh` (build-settings
SSOT: Swift 6 language mode, default isolation `nonisolated`) and `release.sh`.

Unverified so far: sustained RT quality (no crackle under CPU load, no IOProc
allocations under Instruments) and soak behavior (repeated replug mid-playback,
overnight sleep/wake, idle CPU).

## Rules

- **Test integrity.** Tests encode adjudicated decisions. If
  `vDSPBiquadmStereoMatchesScalarReference` fails, the ONLY correct fix is
  flipping `EQCoefficients.flatIndex(section:channel:channels:)`. Never loosen a
  tolerance, never skip or delete a test to get green.
- **RT rules.** No allocation, locks, logging, or ObjC/Swift-runtime calls in the
  IOProc. Don't "simplify" the atomic-flag protocols or the teardown order.
- **`kill -9` fail-safe.** Kill the app while music plays → audio MUST keep
  playing. Re-test after any change to tap creation or teardown; if it fails,
  suspect the mute behavior.
- Keep the MIT attribution headers in files cherry-picked from iqualize.
- Some comments carry **VERIFY ON FIRST MAC BUILD**; still open are
  `isPrivate`/`privateTap` spelling (unneeded so far), whether our private
  aggregates can surface in the device catalog, the
  `vDSP_biquadm_SetTargetsDouble` no-allocation assumption (needs Instruments),
  and a macOS 15+ atomics cleanup. Resolve against the SDK, then update the comment.
- No git operations unless explicitly asked.

## Invariants

- **One engine, active route only.** A `stereoGlobalTapButExcludeProcesses` tap
  mutes captured processes SYSTEM-WIDE — CoreAudio has no device-scoped tap or
  mute. So at most ONE engine runs, only for the device that is BOTH checked AND
  the current default-output route; anything else silences audio everywhere while
  nothing plays through the device in use (observed bug, not theory). Enforced in
  `OutputDeviceEQCoordinator.planReconciliation`; `maxSimultaneousDevices = 1` is
  defense-in-depth, not a tunable. Checking a device the OS isn't routing to is
  valid (pre-selecting headphones) — the row shows not-running until it is.
- **Tap exclusions.** Excluding our own process is mandatory, else our output is
  re-captured (feedback loop). Hog-mode holders are excluded too — see
  `HogModeMonitor.swift`.
- **Teardown order** (fixes a nil-while-callback-running race): `AudioDeviceStop`
  → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
  `AudioHardwareDestroyProcessTap` → only THEN release RT-shared buffers/refs.
  Always tear down the FULL stack; partial rebuilds are unreliable.
- **Aggregate construction.** `kAudioAggregateDeviceTapListKey` MUST be in the
  creation dictionary — adding the tap later delivers zero-filled buffers. Build
  at the OUTPUT device's nominal sample rate; the aggregate resamples the tap side.
- **vDSP.** `vDSP_biquadm_CreateSetup(coeffs, M, N)` takes **M = sections,
  N = channels**. The archived vDSP Programming Guide says the opposite and is
  WRONG — ours is verified empirically on-Mac (swapping them crashed the IOProc);
  do not "fix" it to match the docs. Pinned by
  `vDSPBiquadmCreateSetupTakesSectionsThenChannels`. Layout is SECTION-MAJOR
  (`EQCoefficients.flatIndex`). Max 16 sections (`EQPresetData.maxBandCount`, which
  `EQCoefficients.maxSections` mirrors) × 2 channels; unused sections are identity;
  0 bands = flat passthrough is legal.
- **Watchdog.** Only while running, 5 s period. A tick is silent only when
  callbacks are ADVANCING and max-abs == 0 and some OTHER process is outputting
  audio — zeros are legitimate when nothing plays and must never trip it. 2
  consecutive silent ticks → ONE rebuild; still silent → `engineSuspectsPermissionDenied`
  (TCC denial is silent: the tap just delivers zeros, no error, no query API).
  After a successful rebuild, and again when audio returns while a suspicion
  stands, the engine fires `didChangeState(.running)` UNCONDITIONALLY; the
  coordinator must keep treating repeated `.running` as idempotent.
- **Sleep/wake.** `NSWorkspace.didWakeNotification` → preventive full rebuild ~1 s
  after wake.
- **`.mutedWhenTapped`, not `.muted`** — what keeps audio alive if the app dies.
- **TCC.** `NSAudioCaptureUsageDescription` must be set manually in Info.plist
  (Xcode's dropdown omits it); `com.apple.security.device.audio-input` entitlement
  required under Hardened Runtime. The purple capture dot is unavoidable.
- **Persistence.** `UserDefaults.standard`, keys prefixed `eqym.`, JSON via
  Codable. Enabled devices keyed by device UID, never `AudioObjectID` (session-scoped).

## Reference

iqualize (https://github.com/DariusCorvus/iqualize, MIT, audited at commit
`91f701b`) — its `AudioEngine.swift` holds proven tap/aggregate construction.
Its ring-buffer + AVAudioEngine architecture is NOT ours: we process directly in
the aggregate's IOProc. Also: `insidegui/AudioCap` (Apple-style tap sample), the
zero-buffer bug the watchdog exists for
(https://developer.apple.com/forums/thread/825780), and — if the tap API is ever
withdrawn — a HAL AudioServerPlugIn based on `briankendall/proxy-audio-device`
(Unlicense); BlackHole (GPL-3, no passthrough) and BackgroundMusic (GPL-2, no
drift correction) are not viable bases.
