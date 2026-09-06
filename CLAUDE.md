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
with CLT). The SwiftPM test target EXCLUDES `App/eqYourMacbookApp.swift` (the `@main`
entry) and compiles with different flags than the shipping `swiftc` build, so a green
`swift test` does NOT prove the app compiles — an ambiguous-type error once shipped green
and broke only `install.sh` (2026-09-06). `test.sh` therefore runs `build.sh --typecheck`
FIRST (every source, real app flags, no binary); `build.sh` keeps a single `COMMON_ARGS`
array so the gate can never drift from the real build.

```
./build.sh            # -> .build/eqYourMacbook.app (Debug)
./test.sh             # build + run eqYourMacbookTestRunner
./install.sh          # test + build + install to /Applications + launch
./run.sh              # open the built app
scripts/release.sh    # --release + zip in build/dist/ (CI)
```

Root = daily entry points. `scripts/` = the rest: `build-config.sh` (build-settings
SSOT: Swift 6 language mode, default isolation `nonisolated`), `release.sh`, and
`eqym-ctl.sh`, the bench tool (sources in `scripts/eqym-ctl/`) that drives the installed
app over its **control channel** — `EQControlChannel.swift`, DistributedNotificationCenter,
protocol in `EQControlProtocol.swift` which the tool compiles in verbatim. Commands do
only what the menu does (enable/disable, A/B bypass, read state); every state change is
broadcast as a snapshot (running device, sample rate, granted IO buffer, exclusion set).

```
scripts/eqym-ctl.sh status            # what the app is doing right now
scripts/eqym-ctl.sh latency           # added latency of the EQ path (mic + click train, automated, ~35 s)
scripts/eqym-ctl.sh watch             # then start a call: prints the exclusion window in ms
scripts/eqym-ctl.sh processes         # HAL processes with input/output running (watchdog's and exclusion's view)
```

Measurements are automated end to end (preconditions checked; no number without a
labeled buffer size, a plausible click count and a grid jitter ≤ 1 ms) so runs at
different `ioBufferTargetDuration` values are comparable; results accumulate in
`.build/measure/latency-results.tsv`, and `latency`/`watch` also mirror their full output
to `.build/measure/{latency,watch}-<stamp>.log`. **`watch` polls HAL every 100 ms and by
itself drives coreaudiod to ~4.5 % (with the app quit too — it is the tool), so it must
never run during an idle-cost measurement.** `latency` reads each toggle's shift as the median
grid-phase change over ~4 clicks after the switch (the toggle itself causes audible
transients and the ON switch lands ~0.3 s after the command, so single-interval rules
were fooled). **Every silence or idle-cost measurement is gated
on `eqym-ctl quiet` before AND after** (`latency` does this itself): a browser holding
an output stream is indistinguishable from a latch on CPU alone, and `pmset` assertions
are too weak a signal. Read the app log with `/usr/bin/log` (zsh's `log` builtin shadows
it).

Unverified so far: sustained RT quality (no crackle under CPU load, no IOProc
allocations under Instruments), soak behavior (repeated replug mid-playback,
overnight sleep/wake), and the two measurements above (added latency at
512/1024/2048 frames; call-exclusion window) that decide `ioBufferTargetDuration`.

**Idle cost, measured 2026-09-04 on-Mac (eqym-ctl, gated on `quiet`):** coreaudiod costs
~12.6 % while the built-in speakers play, with or without us, and a true 0 % in silence.
With our engine running, a FRESH stack is also 0 % in silence; after the first tapped
playback coreaudiod kept ~13 % and a `PreventUserIdleSystemSleep` assertion through
78 min of silence. Not the DSP (bypass changes nothing), not drift compensation, not
another process, not how the player ended (natural end, SIGTERM and SIGKILL all latch
alike): the discriminator is the HAL reporting OUR process as duplex — mechanism and fix
in § Invariants "Idle latch". **Fix verified 5/5 + 3/3 cycles:** +3 s after the player
stops 12–14 % and duplex, +20 s 0.0 % and not duplex, exactly one release rebuild logged
per cycle, no TCC or exclusion noise.

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
  re-captured (feedback loop). Two dynamic sources are excluded on top of that, both
  watched by `TapExclusionMonitor.swift` (exclusion lists are fixed at
  `CATapDescription` creation, so a change means a full rebuild — debounced 0.5 s):
  hog-mode holders, and **processes in a voice session** (running input AND output at
  once). The latter: macOS drives calls through VoiceProcessingIO, which ducks all
  "other audio"; tapping such a process moves its call audio into OUR process, which the
  OS then ducks as "other audio" — the call ducks itself. Observed with WhatsApp
  (Catalyst + WebRTC `RTCAudioSession`, `playAndRecord`/voiceChat) on 2026-08-26: calls
  near-inaudible until the EQ was toggled off. Teams is unaffected — native macOS app,
  own AEC over the plain HAL, no VoiceProcessingIO. **Bypass does not help** (the tap
  stays alive and we are still the process rendering the audio); only exclusion does.
  Accepted consequence: **calls are not equalized**, including the ones that worked
  before. Our own process is itself reported as duplex once the tap has carried audio (our
  aggregate's tap side is an input stream); for the exclusion LIST that is irrelevant
  (`tapExcludedProcessObjects` unions us in anyway), but the classification itself is
  costly — see "Idle latch".
  The engine's **polling backstop** (`startExclusionBackstop`, 2 s) is the PRIMARY path
  for a call, not a fallback: measured 2026-09-06 over 10 h / 2 FaceTime calls, the
  per-process `IsRunningInput` listeners fired **0 times**. The HAL does not deliver a
  flag-flip notification for an EXISTING process object (a call daemon like
  `com.apple.avconferenced`, already running, so the process-list listener cannot fire
  for it either) — the same shape as a Teams call once tapped for **291 s** before the
  backstop existed. With it, the two FaceTime calls were excluded in 651 ms and 2117 ms
  (both < the ~3 s target; the poll's 5 s scan had measured 0.0 % coreaudiod, so cost is
  no argument against it — it idles at ~0.2 % of a core). The monitor's listeners remain
  as the fast path WHEN they fire (a process appearing already duplex → `process list
  changed`; a hog change → `device list changed`), logged at info level
  (`exclusion monitor: …`) so the next investigation sees which fired; and `rebuild()`
  re-checks once when its reentrancy guard clears, for a change swallowed mid-rebuild.
  The watchdog tick itself stays out of exclusions. Two known gaps,
  both accepted: (1) a call is tapped until exclusion lands — ≤ ~0.8 s via a listener,
  ≤ ~2.5 s + rebuild via the backstop — during which its far-end audio takes our
  (delayed) path and its AEC must re-converge (neither the 291 s Teams call nor the two
  excluded FaceTime calls produced echo at the remote end — weak evidence, since both
  vendors run their own AEC that would mask a tap-induced echo); (2) the criterion is per
  PROCESS OBJECT, so an app that runs its microphone in one helper process and its
  playback in another is never seen as a voice session and stays tapped (Teams,
  FaceTime, WhatsApp, Chrome/Electron/Zoom all keep both in one process today).
- **Teardown order** (fixes a nil-while-callback-running race): `AudioDeviceStop`
  → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
  `AudioHardwareDestroyProcessTap` → only THEN release RT-shared buffers/refs.
  Always tear down the FULL stack; partial rebuilds are unreliable.
- **Aggregate construction.** `kAudioAggregateDeviceTapListKey` MUST be in the
  creation dictionary — adding the tap later delivers zero-filled buffers. Build
  at the OUTPUT device's nominal sample rate; the aggregate resamples the tap side.
  `kAudioAggregateDeviceTapAutoStartKey` MUST stay `true` (measured 2026-09-04): with
  `false` a fresh stack that has never carried audio is already reported duplex at
  8–10 % coreaudiod, the idle-latch release cannot clear it (still duplex + assertion at
  +60 s) and the watchdog re-fires every ~35 s because the tap then yields non-zero
  samples in silence. `kAudioSubTapDriftCompensationKey: true` is kept: exonerated as a
  cause of the idle cost, and it is what protects per-app routing to a device on a
  different clock.
- **vDSP.** `vDSP_biquadm_CreateSetup(coeffs, M, N)` takes **M = sections,
  N = channels**. The archived vDSP Programming Guide says the opposite and is
  WRONG — ours is verified empirically on-Mac (swapping them crashed the IOProc);
  do not "fix" it to match the docs. Pinned by
  `vDSPBiquadmCreateSetupTakesSectionsThenChannels`. Layout is SECTION-MAJOR
  (`EQCoefficients.flatIndex`). Max 16 sections (`EQPresetData.maxBandCount`, which
  `EQCoefficients.maxSections` mirrors) × 2 channels; unused sections are identity;
  0 bands = flat passthrough is legal.
- **Watchdog.** Only while running, 5 s period. A tick is silent only when
  callbacks are ADVANCING and max-abs == 0 and some NON-EXCLUDED process is outputting
  audio — zeros are legitimate when nothing plays and must never trip it. The
  discriminator takes the FULL tap-exclusion set, not just our own process: an excluded
  process is not tapped, so its audio never reaches us and counting it would raise a
  false permission suspicion for the whole duration of every call. The discriminator
  is evaluated LAZILY — only on a tick that is already a silence candidate (advancing
  AND max-abs == 0) — so while audio flows the tick makes no CoreAudio calls at all. 2
  consecutive silent ticks → ONE rebuild; still silent → `engineSuspectsPermissionDenied`
  (TCC denial is silent: the tap just delivers zeros, no error, no query API).
  After a successful rebuild, and again when audio returns while a suspicion
  stands, the engine fires `didChangeState(.running)` UNCONDITIONALLY; the
  coordinator must keep treating repeated `.running` as idempotent. The "already
  rebuilt once" flags (`didRebuildForSilence`, `didRebuildForIdleLatch`) are set by the
  tick AFTER `rebuild()` returns: `performStart()` resets them for the fresh stack, and
  setting them first lost them, so under a real TCC denial the engine rebuilt every 10 s
  forever and never reported the suspicion (fixed 2026-09-04, pinned by
  `silencePersistingAfterARealRebuildEscalatesToPermissionSuspicion`).
- **Sleep/wake.** `NSWorkspace.didWakeNotification` → preventive full rebuild ~1 s
  after wake.
- **IO buffer size.** Pinned explicitly on the aggregate at start
  (`EQDeviceEngine.ioBufferTargetDuration`, a wall-clock length converted to the nearest
  power-of-two frame count for the device's rate, clamped to the HAL range, read back
  and logged as `io buffer: …`). Never rely on coreaudiod's per-device default: it is
  per-client, differs by device, and 512 frames is 10.7 ms at 48 kHz but 5.3 ms at
  96 kHz. **Measured 2026-09-04** (MacBook Air Speakers, 48 kHz, `eqym-ctl latency`,
  method jitter 0.15 ms): added latency = 2 × buffer + 3.75 ms → 512: 25.1 ms,
  1024: 46.4 ms, 2048: 89.1 ms. **512 stays**: 1024 already crosses the ~45 ms
  detectability threshold for late audio (ITU-R BT.1359; players cannot compensate for
  latency they don't know about). Calls are not a constraint (call audio never passes
  through our path — voice-session exclusion above — and AEC references the app's own
  render buffer, not the speaker). The buffer is therefore NOT the energy lever it looked
  like: during playback coreaudiod's cost is the device's own (~12.6 % with or without
  us) and idle cost is governed by the idle latch below. A refused pin is non-fatal but
  logged as an error.
- **Idle latch.** Once the tap has carried audio, the HAL reports our process as running
  input AND output (duplex) and keeps doing so after every tapped process has stopped.
  coreaudiod treats a duplex client as an always-active call: no silence detection, the
  device stays at full playback cost (~13 %) and a `PreventUserIdleSystemSleep` assertion
  is held — the Mac never idle-sleeps while the EQ is on. Measured 2026-09-04 (§ Build);
  bypass, drift compensation and the DSP are exonerated. A fresh stack is not duplex and
  costs 0 % in silence, so the watchdog releases the latch: a tick that is silent
  (advancing, max-abs 0) with NO non-excluded process outputting, while
  `isProcessRunningDuplex(own)` is still true, counts as latched; 2 consecutive → ONE
  `rebuild()`; `didRebuildForIdleLatch` blocks further ones until audio has played again
  (max-abs > 0), so a latch that a rebuild cannot clear costs one rebuild per silence
  period, not a loop. Verified on-Mac 2026-09-04 (§ Build). Accepted cost: a ~0.65 s
  window ≥10 s into silence in which a playback start would begin un-EQ'd. Disjoint from
  the TCC path by construction (that one requires a non-excluded process to be
  outputting). The re-arm keys on max-abs > 0 meaning "audio played": in a configuration
  where the tap delivers non-zero samples in silence the release would re-fire (seen with
  `TapAutoStart: false`, below) — another reason that key stays true.
- **Rejected: silence bypass in the IOProc** (skip `vDSP_biquadm` and memset when the
  input is all-zero). The saving is microseconds per callback and the wake-up stays.
  It would add two nonexistent discontinuities: the IIR tail is truncated at the first
  zero buffer (a click at every pause), and the frozen delay state is replayed onto the
  first buffer when audio resumes; `SetTargetsDouble` ramps would also stall during
  silence. A threshold variant is a noise gate. Do not re-propose without a measurement
  showing the biquad dominates.
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
