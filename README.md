# eqYourMacbook

A tiny menu-bar parametric EQ for the MacBook's built-in speakers. No Dock icon, no device picker, no audio driver install. Uses the macOS 14.4+ process-tap API (CATap → private aggregate device → IOProc → vDSP biquads) to intercept and equalize system audio with near-zero idle CPU cost. Automatically engages when the built-in speakers are the default output and steps aside for headphones, AirPods, and HDMI — no manual switching needed.

## Build prerequisites

- macOS 14.4+ (Sequoia or Tahoe), Xcode 16+
- `brew install xcodegen`

## Build and run

```sh
./scripts/build.sh   # generates project then builds (Debug)
./scripts/run.sh     # finds the built app and opens it
```

`run.sh` asks Xcode where the build output went (it lives under DerivedData,
not in the repo), so you don't have to look for the .app yourself.

## Run unit tests

```sh
./scripts/test.sh
```

## Key documents

- **PLAN.md** — architecture decisions, milestones, API facts, risks
- **docs/CONTRACT.md** — Engine/App module interface (SSOT for parallel agents)

## Status

Builds and runs; all unit tests pass. Core EQ verified by ear on the built-in
speakers (M1). See PLAN.md §4 for the milestone roadmap and what is still open.
