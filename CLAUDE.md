# eqYourMacbook — project instructions

Tiny menu-bar system-wide EQ, built on the driverless macOS Core Audio
process-tap API (no HAL driver, no .pkg, no root). Lets the user pick which
single output device to EQ from any available output device (checkboxes,
mutually exclusive; built-in speakers is the default-enabled device on first
launch); that device's EQ engine only actually runs while it's also the OS's
current default-output route — the app never selects or overrides output
routing itself — see `docs/CONTRACT.md` and PLAN.md §1's multi-device
blockquote. Personal-use app, owner: Zdeněk (communicates in Czech; all code,
comments, and docs stay in English).

## Current state (updated 2026-08-15)

Build and M1 listening tests (passthrough, audible EQ, `kill -9` fail-safe)
passed on the Mac 2026-06-10 — see PLAN.md's "First build session checklist".
M2/M3/M5 milestones (RT-load quality, autonomy/soak testing) are still open.
The build system was since migrated off xcodegen/xcodebuild to a direct
`swiftc` build + Swift 6 language mode, and tests off `swift test`/XCTest to a
swift-testing `TestRunner` (see Build section below) — neither xcodegen nor a
full Xcode.app install is needed anymore.

## Sources of truth

- `PLAN.md` — architecture, decisions, audited-reference facts, milestones,
  first-build checklist. Read it before touching code.
- `docs/CONTRACT.md` — the inter-module API contract (Engine ↔ App). Update it
  BEFORE deviating from any signature or documented semantic.

## Build

Builds directly with `swiftc` — **no full Xcode.app required**, Command Line
Tools are enough. No `xcodegen`/`xcodebuild`/`.xcodeproj` on the build path
(same approach as the `ClaudeMonitor` project). Tests use swift-testing via a
`TestRunner` executable (`Package.swift`), not `swift test` — `XCTest.framework`
only ships with full Xcode.app, `Testing.framework` ships with CLT too.

```
scripts/build.sh      # swiftc -> .build/eqYourMacbook.app (Debug)
scripts/test.sh        # swift build + run eqYourMacbookTestRunner
scripts/install.sh     # test + build, install to /Applications, launch
scripts/release.sh     # --release build + zip in build/dist/
```

## Non-negotiable rules

- **Test integrity.** The unit tests encode adjudicated decisions. If
  `testVDSPBiquadmStereoMatchesScalarReference` fails, the ONLY correct fix is
  flipping `EQCoefficients.flatIndex(section:channel:channels:)` (section-major vs
  channel-major was disputed; this canary adjudicates it). Never loosen
  tolerances, never delete or skip tests to get green.
- **RT rules.** No allocation, locks, logging, or ObjC/Swift-runtime calls in
  the IOProc. Teardown order is contractual (see CONTRACT.md). Don't "simplify"
  the atomic-flag protocols.
- **M1 decision rule:** `kill -9` the app while music plays → audio MUST keep
  playing. This adjudicates `.mutedWhenTapped` (current) vs `.muted`
  (iqualize's choice). If it fails, switch the mute behavior and re-test.
- Inline comments flag SDK uncertainties to **VERIFY ON FIRST MAC BUILD**
  (process-object property constants for the watchdog discriminator,
  `CATapDescription` array bridging, `isPrivate`/`privateTap` spelling).
  Resolve each against the real SDK, then update the comment.
- Keep the MIT attribution headers in files cherry-picked from iqualize.
- No git operations unless the user explicitly asks.
- Swift 6 language mode, default isolation `nonisolated` (see `scripts/build-config.sh`).

## Reference

Audited reference codebase: https://github.com/DariusCorvus/iqualize
(MIT, commit `91f701b`, security-audited SAFE on 2026-06-10). Re-clone if
needed — its `AudioEngine.swift` holds the proven tap/aggregate construction
patterns. Its architecture (ring buffer + AVAudioEngine) is NOT ours; we
process directly in the aggregate device's IOProc (see PLAN.md).
