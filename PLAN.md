# eqYourMacbook — Implementation Plan

A tiny menu-bar EQ, now supporting any number of output devices simultaneously
(per-device checkboxes; built-in speakers enabled by default — see the
multi-device blockquote in §1 and `docs/CONTRACT.md`). No windows, no per-app
routing. Parametric EQ with freely chosen frequencies and uncapped gain.
Near-zero idle cost, no audio glitches under load, works on battery.

Status: **build and M1 listening tests passed 2026-06-10** (see "First build
session checklist" below); M2/M3/M5 milestones still open. Build system since
migrated off xcodegen/xcodebuild to a direct `swiftc` build + Swift 6 language
mode (see `CLAUDE.md` § Build).
Owner: Zdeněk. Distribution: personal use (for now); keep a public release possible.
Working title: `eqYourMacbook` (final name TBD; rename is a one-line change in `scripts/build-config.sh`).

> All paths in this document are relative to the project root. The iqualize
> reference codebase is not bundled — clone it from GitHub when needed (see
> "Audited reference codebase" below for URL + audited commit).

---

## 1. Architecture decision: driverless Core Audio process tap

**Primary (chosen): macOS process-tap API (macOS 14.2+, stable since 14.4).**
No HAL driver, no `.pkg`, no root, no `coreaudiod` restart. One signed app binary.

This is a proven, shipped pattern:
- **iQualize** (commercial menu-bar EQ, https://iqualize.app/) ships exactly this
  architecture (CATap → EQ → same output device, ~10 ms latency).
- **DariusCorvus/iqualize** (https://github.com/DariusCorvus/iqualize) is an
  open-source Swift implementation of the same — our closest reference.
- **insidegui/AudioCap** (https://github.com/insidegui/AudioCap) is the canonical
  capture-side sample (Guilherme Rambo).
- Rogue Amoeba's driverless backend (Audio Hijack/SoundSource on 14.4+) validates
  the API at production scale.

**Fallback (only if the tap path hits a wall): HAL AudioServerPlugIn driver.**
Base it on **briankendall/proxy-audio-device** (The Unlicense / public domain) —
the only open driver with virtual→real forwarding *and* clock-drift compensation
built in. Do NOT base on BlackHole (GPL-3.0, no passthrough) or BackgroundMusic
(GPL-2.0, passthrough lives in the app, no drift correction). Nothing in the
primary plan depends on the fallback; it exists so a dead end doesn't kill the project.

### Audited reference codebase: iqualize (2026-06-10)

https://github.com/DariusCorvus/iqualize, audited at commit `91f701b`, MIT —
clone locally when a code reference is needed.
Security audit verdict: **SAFE** (no network code, no telemetry, no obfuscation,
2 deps, both Apple: swift-markdown + swift-cmark). Full audit in session notes.

**Strategy: fresh project, cherry-pick — do NOT fork.** Their processing backbone
is AVAudioEngine (tap → IOProc → ring buffer → AVAudioSourceNode → AVAudioUnitEQ →
limiter → output), UI is AppKit; >60 % would be gutted. Cherry-pick verbatim:

- `BiquadResponse.swift` — complete, correct RBJ cookbook for all 7 filter types
- `EQModels.swift` — FilterType/EQBand/EQPresetData structs (gain uncapped — good)
- `CoreAudioHelpers.swift` — caCheck, device-ID/UID/name helpers
- `BiquadFilter.swift` — only the `NormalizedBiquadCoeffs` struct (drop the scalar
  `process()` loop; we use `vDSP_biquadm`)
- aggregate-dict construction + PID-exclusion pattern (`AudioEngine.swift:186–271`)
- sleep/wake notification pattern (`iQualizeApp.swift:46–60`)
- `SpectrumData.swift` double-buffer pattern, IF we ever add an analyzer (gate it
  on popover visibility — iqualize runs 2 FFTs continuously even with UI closed)

**Hard-won API facts learned from their code (do not rediscover):**
1. `kAudioAggregateDeviceTapListKey` MUST be in the creation dictionary — adding
   the tap later via the property delivers zero-filled buffers (their spike proved it).
2. The aggregate's IOProc really does deliver tap input AND speaker output buffers
   in the same callback — iqualize zeroes `outOutputData` and routes through
   AVAudioEngine instead; the direct-IOProc plumbing is proven viable.
3. Configure formats at the OUTPUT device's nominal rate; the aggregate resamples
   the tap side (their "volume insertion loss" bugfix). Moot for built-in (fixed 48 kHz).
4. They use `muteBehavior = .muted` — verify in M1 whether `.mutedWhenTapped`
   gives the crash-fail-safe we want (audio continues if app dies) or whether
   `.muted` + explicit unmute-on-teardown is the working combination.
5. Their TCC request is `CGRequestScreenCaptureAccess()` (screen recording — the
   broad permission). Prefer prompt-on-first-tap + zero-input detection; decide in M1.
6. Their `.entitlements` lacks `com.apple.security.device.audio-input` — one
   reason their hardened-runtime/notarized path is broken. Ours must include it.

**What iqualize does NOT have (our additions):** auto-bypass by transport type
(they EQ headphones/HDMI too), zero-buffer watchdog, TCC-denial detection,
vDSP biquads (their split-channel path is a scalar per-sample loop), RT-clean
teardown (they nil shared refs while callbacks may still run — race).

### How the tap pattern works

1. Create a **global process tap** of all processes, **excluding our own**, with
   `muteBehavior = CATapMutedWhenTapped` → while our IOProc consumes the tap, the
   original audio is silenced *at the device*; the moment we stop, audio passes
   through untouched. (Built-in fail-safe: if the app crashes, sound keeps playing.)
2. Wrap the tap + the built-in-speakers device in a private **aggregate device**
   (tap = input side, speakers = output sub-device, drift compensation on).
3. One **IOProc** on the aggregate: input buffers = system mixdown, apply biquad
   EQ, write to output buffers → speakers. One unified clock, no ring buffer,
   no AVAudioEngine. (iQualize routes through AVAudioEngine + a ring buffer;
   we deliberately don't — lighter and lower latency.)
4. Hardware volume keys keep working: the tap reads the post-mix bus *before*
   device volume, and the OS still owns the output device.

### Engage / disengage = the auto-bypass feature

Listen on `kAudioHardwarePropertyDefaultOutputDevice` (system object):

- default output **is** built-in speakers → **engage** (build tap + aggregate + IOProc)
- default output is anything else (headphones, AirPods, HDMI) → **disengage**
  (full teardown) — original audio path is restored, EQ is simply out of the picture.

We never change the default device and never run against any device other than the
built-in speakers — which is also the most stable possible target (fixed 48 kHz,
never disconnects). This sidesteps most known device-change bugs by design.

> **Superseded by multi-device support (see `docs/CONTRACT.md`).** The app no
> longer engages/disengages on the system default-output route; instead the user
> checks any number of output devices independently (built-in speakers checked by
> default), each running its own tap+aggregate+IOProc concurrently. The
> single-device design above is kept for historical rationale (why built-in
> speakers were the original target); the component list and engage-sequence
> below are per-device and instantiated once per checked device, not once
> globally — see `EQDeviceEngine`/`OutputDeviceCatalog`/`OutputDeviceEQCoordinator`.

---

## 2. Components

```
eqYourMacbook.app  (Swift, menu bar only, LSUIElement)
│
├── EQDeviceEngine          per-device tap + aggregate device + IOProc + vDSP biquads
├── EQDeviceRTContext       per-device RT-thread scratch state + IOProc closure factory
├── OutputDeviceCatalog     kAudioHardwarePropertyDevices listener → live output-device list
├── OutputDeviceEQCoordinator  reconciles checked devices ↔ running EQDeviceEngine instances
├── EQModels / EQCoefficients   bands, coefficient math (Orfanidis/Vicanek exact designs)
├── PresetStore         persistence (Application Support JSON), named presets
└── UI (SwiftUI)        MenuBarExtra(.window): curve Canvas + device rows + band controls
```

### EQDeviceEngine — per-device engage sequence (precise API flow)

```text
1. pid → AudioObjectID:  kAudioHardwarePropertyTranslatePIDToProcessObject (getpid())
2. CATapDescription initStereoGlobalTapButExcludeProcesses:@[ownProcessID]
      .muteBehavior = CATapMutedWhenTapped      // key to the whole pattern
      .privateTap   = YES
      .name / .UUID set (UUID becomes the tap UID)
3. AudioHardwareCreateProcessTap(desc, &tapID)
4. Target device is injected by OutputDeviceEQCoordinator (from OutputDeviceCatalog's
   live enumeration), not discovered internally — read its UID
5. AudioHardwareCreateAggregateDevice with:
      kAudioAggregateDeviceSubDeviceListKey = [builtInUID]
      kAudioAggregateDeviceMainSubDeviceKey = builtInUID        // clock master
      kAudioAggregateDeviceTapListKey =                         // MUST be set at
          [{kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: YES}]
          // creation time — adding the tap later delivers zero-filled buffers
      kAudioAggregateDeviceIsPrivateKey = YES
6. AudioDeviceCreateIOProcIDWithBlock on the aggregate:
      in callback: vDSP_biquadm(input → output); zero-fill output if input missing
7. AudioDeviceStart
```

Disengage = exact reverse: `AudioDeviceStop → AudioDeviceDestroyIOProcID →
AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap`.
**Always tear down the full stack — partial rebuilds are documented as unreliable.**

CRITICAL: the self-exclusion in step 2 is what prevents a feedback loop (our own
rendered output being re-captured). Never create the tap without it.

### DSP

- `vDSP_biquadm` (Accelerate): N cascaded sections × 2 channels, SIMD. Budget for
  ~10 bands is well under 1 % of one core on Apple Silicon.
- Coefficients: RBJ cookbook BW→alpha (sinh-based, gain-independent) pole placement
  for peaking/band-pass/notch — exact-bandwidth-edge-gain-matched in practice (an
  earlier "Orfanidis" derivation here divided alpha by the linear gain A, which was
  a bug: the bandwidth-edge-gain condition is provably independent of A; fixed
  2026-08-15, see `BiquadResponse.swift` and `EngineCoefficientTests.swift`) —
  and Vicanek matched-filter design for shelves/LP/HP — replaces the original RBJ
  Audio EQ Cookbook approximation (`BiquadResponse.swift`, all 7 filter types),
  which measurably warped shelf/peak shape near Nyquist.
- Latency: one hardware buffer period total. 512 frames @ 48 kHz = 10.7 ms;
  read/try `kAudioDevicePropertyBufferFrameSize` — at 256 frames it's 5.3 ms.
  (iqualize's ring-buffer + AVAudioEngine chain measures ~16–21 ms typical;
  direct IOProc halves it or better.)
- Live updates without zipper noise: `vDSP_biquadm_SetTargetsDouble` (built-in
  coefficient ramping). Verify its RT-safety in M3; if in doubt, fall back to
  double-buffered setups with an atomic pointer swap applied at callback start.
- **RT rules in the IOProc: no allocation, no locks, no logging, no Swift
  runtime surprises** (keep the callback in a confined, pre-allocated path).
  This is the "no glitches under load" guarantee.
- No gain cap. UI range ±24 dB (constant, trivially changeable).
- Default preset "MBA tame-the-highs": high-shelf ≈ −4 dB @ 8 kHz + gentle peak
  cut ≈ −2 dB @ 2.5 kHz, Q 1.0 — starting point, tune by ear in M2.
- Later (M5, optional): output safety for positive gains — auto pre-gain
  (−maxBoost) or a simple peak limiter. With cuts-only presets it's a non-issue.

### UI

- `MenuBarExtra` with `.menuBarExtraStyle(.window)`; `LSUIElement = true` (no Dock icon).
- Dropdown content:
  - frequency-response curve (`Canvas`, |H(f)| product over log-spaced grid 20 Hz–20 kHz)
  - per-band controls: type, freq, gain, Q; add/remove band (parametric — "choose
    any frequencies freely" is the point of this app)
  - master enable/bypass toggle, preset picker, launch-at-login toggle (`SMAppService`)
  - small status line: engaged (speakers) / bypassed (other output) / permission missing
- Idle cost: SwiftUI renders only while the dropdown is open; nothing polls.

### Permission (TCC) — known UX trap

- First `AudioHardwareCreateProcessTap` triggers the **System Audio Recording**
  prompt. `NSAudioCaptureUsageDescription` must be added to Info.plist **manually**
  (not in Xcode's dropdown).
- Entitlement: `com.apple.security.device.audio-input` (Hardened Runtime).
- **Denial is silent** — the tap just delivers zeros, no error. The Watchdog detects
  "engaged but all-zero input while device is running" and the UI then shows a
  "grant permission in System Settings → Privacy & Security" hint. There is no
  public permission-query API (AudioCap uses private TCC SPI behind a compile
  flag — skip that; personal app, prompt-and-detect is enough).
- The **purple dot** (system-audio-capture indicator) in the menu bar is
  unavoidable whenever the tap is active. Accepted cost of the driverless path.

### Watchdog — the one real production bug

Apple Developer Forums thread 825780: after sample-rate renegotiations or BT
sleep/wake cycles, the IOProc can keep firing with **all-zero buffers** while
system audio plays (M2 MacBook Air reportedly more affected). Our design already
avoids the main triggers (we only ever run on built-in speakers and tear down
when any other device becomes default), but still:

- While engaged, a low-frequency check (every few seconds, only when engaged —
  not a hot poll) verifies input isn't permanently zero while the device is running.
- Tripped → full disengage + engage (complete stack rebuild).
- `NSWorkspace.didWakeNotification` → preventive rebuild after sleep.
- Same detector doubles as the TCC-denial detector (see above).

---

## 3. Project setup

- **Built directly with `swiftc`, no `.xcodeproj`/`xcodebuild`** — `scripts/build.sh`
  assembles the `.app` bundle by hand (Info.plist, entitlements, ad-hoc
  codesign); only Command Line Tools needed, no Xcode.app. Same approach as the
  `ClaudeMonitor` project. Tests use swift-testing via a `TestRunner` executable
  (`Package.swift`), not `swift test` — `XCTest.framework` needs full Xcode.app,
  `Testing.framework` ships with CLT too. Settings live in `scripts/build-config.sh`.
- Swift 6 language mode, default isolation `nonisolated`, SwiftUI app lifecycle, single target.
- **Deployment target macOS 14.4** — the APIs need nothing newer, and it keeps a
  future public release open. Dev machine runs macOS 26 (Tahoe).
- Signing: Developer ID Application + Hardened Runtime. For personal use a locally
  built signed app is enough; **notarization only becomes relevant for distribution**
  (then: `notarytool submit` + `stapler staple`, no extra entitlements needed —
  fully public API).
- Repo layout:

```
eqyourmacbook/
├── PLAN.md                  (this file)
├── Package.swift            (SPM — test-running only, not the app build)
├── Sources/
│   ├── App/                 (main, MenuBarExtra, views)
│   ├── Engine/              (EQDeviceEngine, EQDeviceRTContext, OutputDeviceCatalog — Swift + C interop)
│   └── Model/               (EQModel, coefficients, PresetStore)
├── Tests/eqYourMacbookTests/ (swift-testing)
├── TestRunner/              (@main entry point for scripts/test.sh)
├── Resources/               (Info.plist, entitlements)
└── scripts/                 (build-config.sh, build.sh, test.sh, install.sh, release.sh, run.sh)
```

No git operations unless explicitly requested.

---

## 4. Milestones (each ends with a listening test on the Mac)

**M0 — Skeleton.** swiftc-built app, menu-bar icon with empty dropdown, signing,
LSUIElement, Info.plist + entitlements in place.
*Verify: app builds, icon appears, no Dock icon.*

**M1 — Tap passthrough (identity, no EQ).** EQEngine engage/disengage wired to a
manual toggle. TCC prompt appears; music keeps playing *through our chain*.
*Verify: (a) audio audible while engaged, (b) toggle off → audio continues seamlessly,
(c) `kill -9` the app while playing → audio must keep playing (decides
`.mutedWhenTapped` vs iqualize's `.muted` — see audit fact #4), (d) purple dot
appears/disappears, (e) measure round-trip latency and buffer frame size.*
**This is the riskiest milestone — everything after it is downhill.**

**M2 — Hardcoded EQ.** Fixed high-shelf cut in the IOProc via `vDSP_biquadm`.
*Verify: clearly audible treble difference vs bypass; no crackle while running
a parallel CPU load (e.g. video export); volume keys still work.*

**M3 — Dynamic parametric model.** EQModel + RBJ coefficients + live updates
(SetTargetsDouble or atomic swap) + persistence; default MBA preset tuned by ear.
*Verify: moving a slider changes sound live with no zipper/clicks.*

**M4 — Real UI.** Curve Canvas, band controls (add/remove/type/freq/gain/Q),
bypass, presets, status line.
*Verify: visual curve matches what you hear.*

**M5 — Autonomy.** DeviceWatcher auto-engage/disengage on output change, Watchdog,
sleep/wake rebuild, launch at login. Optional: output limiter / auto pre-gain;
optional idle optimization (stop IOProc when nothing plays — investigate
`kAudioDevicePropertyDeviceIsRunningSomewhere`; only if measured idle cost warrants it).
*Verify: plug/unplug AirPods repeatedly mid-playback → EQ engages only on speakers,
no stuck silence; close lid overnight → still working in the morning; CPU at idle ≈ 0 %,
during playback ~1 %.*

**M6 — (Optional, later) Distribution.** Notarization, release packaging, public repo.
Out of scope until requested.

Rough effort with the reference repos available: M0–M2 in a few focused days,
M3–M5 about a week of iteration. The build/test loop on the Mac is the pacing factor.

---

## First build session checklist (completed 2026-06-10)

The whole tree (M0–M5 feature scope) was written blind on Linux, then passed
two adversarial review waves + a fix wave + a consistency wave before this
checklist was worked through on the Mac:

1. ✅ DONE 2026-06-10: `scripts/build.sh` green — zero compile errors on first build.
2. ✅ DONE 2026-06-10: `scripts/test.sh` green (37 tests).
   - the 1×1 vDSP canary pins the biquad sign convention — PASSED;
   - the 2×2 stereo canary adjudicated SECTION-MAJOR layout CORRECT — `flatIndex`
     stays as written;
   - **runtime discovery:** `vDSP_biquadm_CreateSetup(coeffs, M, N)` takes
     **M=SECTIONS, N=CHANNELS** — the archived vDSP Programming Guide documents
     the opposite and is WRONG (verified empirically on-Mac; the swap crashed the
     IOProc by making vDSP read 16 "channel" pointers from 2-slot scratch arrays).
     The 2×2 canary is blind to this; the asymmetric canary
     `testVDSPBiquadmCreateSetupTakesSectionsThenChannels` now pins it.
3. SDK facts to confirm (each flagged inline in code):
   - ✅ `CATapDescription(stereoGlobalTapButExcludeProcesses:)` bridging and
     `.mutedWhenTapped` spelling — compiled and ran 2026-06-10;
   - `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput`
     (watchdog's "is anyone else playing" discriminator); fallback if absent:
     never auto-escalate to permissionNeeded;
   - `tapDesc.isPrivate` vs `.privateTap` spelling (currently commented out —
     aggregate-level privacy is set and sufficient; 2026-06-10: no stray
     aggregate visible in `system_profiler SPAudioDataType`, so not needed so far).
4. M1 listening tests (PLAN §Milestones): ✅ passthrough + audible EQ + live slider
   drags verified by ear 2026-06-10; ✅ **`kill -9` while playing → audio continued
   without interruption — `.mutedWhenTapped` ADJUDICATED CORRECT** (do not switch
   to iqualize's `.muted`). Still open: purple dot lifecycle, TCC prompt wording,
   deny-path → permissionNeeded + "Open Settings" button.
   (UI fix along the way: the band list ScrollView collapsed to zero height inside
   MenuBarExtra(.window) — needs an explicit frame height; fixed in BandListView.)
5. M2/M3 quality: audible EQ; no crackle under parallel CPU load; slider drags
   zipper-free (SetTargetsDouble ramp constants 0.005/0.0001 are untuned guesses);
   verify in Instruments that the IOProc makes no allocations (incl. the
   RT-side SetTargetsDouble assumption).
6. M5 autonomy: AirPods plug/unplug mid-playback (auto-engage/disengage), sleep/wake,
   overnight soak, idle CPU ≈ 0 %.
7. Measure: `kAudioDevicePropertyBufferFrameSize` and end-to-end latency;
   if 512 frames (10.7 ms), try 256 (5.3 ms) for stability.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| Zero-buffer bug after device churn (forums/825780) | Watchdog + full-stack rebuild; we only ever target built-in speakers |
| TCC denial is silent (zeros, no error) | Watchdog doubles as detector; UI hint to System Settings |
| Feedback loop | Mandatory self-exclusion in CATapDescription (step 2); M1 verify |
| RT violations → glitches under load | No alloc/locks/logging in IOProc; M2 verify under CPU load |
| Some apps bypass the HAL mix bus (MS Teams, some DRM) | Known platform limitation; irrelevant for music/video; document |
| Purple capture dot always visible when engaged | Unavoidable; accepted |
| Tap API regressions in future macOS | Fallback architecture documented (proxy-audio-device fork) |

## 6. Build & test loop (decide at M0)

- **Option A — user-driven:** code is written into this shared directory; Zdeněk runs
  `scripts/build.sh`/`scripts/test.sh` on the Mac and reports results/listening notes.
- **Option B — SSH:** passwordless SSH from the Linux dev box to the Mac; agent runs
  `scripts/build.sh` remotely itself. Faster iteration; needs one-time setup.
  (Listening tests stay human either way.)

## 7. Key references

- Apple: Capturing system audio with Core Audio taps —
  https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
- insidegui/AudioCap (canonical tap sample) — https://github.com/insidegui/AudioCap
- DariusCorvus/iqualize (open-source tap-based EQ, MIT) —
  https://github.com/DariusCorvus/iqualize (audited at commit 91f701b, 2026-06-10)
- sudara's gist (earliest API walkthrough, aggregate dict verbatim) —
  https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- maven.de — CoreAudio taps for dummies — https://www.maven.de/2025/04/coreaudio-taps-for-dummies/
- Zero-buffer bug thread — https://developer.apple.com/forums/thread/825780
- Fallback driver base — https://github.com/briankendall/proxy-audio-device
- RBJ Audio EQ Cookbook — biquad coefficient formulas (peaking/shelving)
