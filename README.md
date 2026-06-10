# eqYourMacbook

A tiny menu-bar parametric EQ for the MacBook's built-in speakers. No Dock icon, no device picker, no audio driver install. Uses the macOS 14.4+ process-tap API (CATap → private aggregate device → IOProc → vDSP biquads) to intercept and equalize system audio with near-zero idle CPU cost. Automatically engages when the built-in speakers are the default output and steps aside for headphones, AirPods, and HDMI — no manual switching needed.

## Build prerequisites

- macOS 14.4+ (Sequoia or Tahoe), Xcode 16+
- `brew install xcodegen`

## Build and run

```sh
./scripts/build.sh   # generates project then builds (Debug)
open build/Debug/eqYourMacbook.app
```

## Run unit tests

```sh
./scripts/test.sh
```

## Key documents

- **PLAN.md** — architecture decisions, milestones, API facts, risks
- **docs/CONTRACT.md** — Engine/App module interface (SSOT for parallel agents)

## Status

Pre-build development (M0 skeleton). See PLAN.md §4 for milestone roadmap.
