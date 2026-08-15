# eqYourMacbook — project instructions

Tiny menu-bar system-wide EQ, built on the driverless macOS Core Audio
process-tap API (no HAL driver, no .pkg, no root). Supports EQ'ing any number of
output devices simultaneously (per-device checkboxes; built-in speakers is the
default-enabled device on first launch) — see PLAN.md §5 "Multi-output-device EQ
support". Personal-use app, owner: Zdeněk (communicates in Czech; all code,
comments, and docs stay in English).

## Current state (2026-06-10)

**Code complete but written BLIND — it has never been compiled** (developed on
a Linux box without Xcode). It passed 2 adversarial review waves + a fix wave +
a consistency wave, but the compiler will still find things.

**The first task of any new session: work through `PLAN.md` § "First build
session checklist"** — build, run tests, resolve the inline-flagged SDK
uncertainties, then the M1 listening tests.

## Sources of truth

- `PLAN.md` — architecture, decisions, audited-reference facts, milestones,
  first-build checklist. Read it before touching code.
- `docs/CONTRACT.md` — the inter-module API contract (Engine ↔ App). Update it
  BEFORE deviating from any signature or documented semantic.

## Build

```
brew install xcodegen        # once
scripts/build.sh             # xcodegen generate + xcodebuild Debug
scripts/test.sh              # unit tests
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
- Swift 5 language mode (not 6) — deliberate; don't "upgrade".

## Reference

Audited reference codebase: https://github.com/DariusCorvus/iqualize
(MIT, commit `91f701b`, security-audited SAFE on 2026-06-10). Re-clone if
needed — its `AudioEngine.swift` holds the proven tap/aggregate construction
patterns. Its architecture (ring buffer + AVAudioEngine) is NOT ours; we
process directly in the aggregate device's IOProc (see PLAN.md).
