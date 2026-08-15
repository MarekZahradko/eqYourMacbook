# eqYourMacbook

A tiny menu-bar parametric EQ for the MacBook's built-in speakers. No Dock icon, no device picker, no audio driver install. Uses the macOS 14.4+ process-tap API (CATap → private aggregate device → IOProc → vDSP biquads) to intercept and equalize system audio with near-zero idle CPU cost. Automatically engages when the built-in speakers are the default output and steps aside for headphones, AirPods, and HDMI — no manual switching needed.

## Build prerequisites

- macOS 14.4+ (Sequoia or Tahoe)
- Command Line Tools only — **no full Xcode.app required** (`xcode-select --install`)

The app is built directly with `swiftc` (see `scripts/build.sh`); SPM
(`Package.swift`) is used only to run unit tests. No `xcodebuild`, no
`xcodegen`, no `.xcodeproj` on the build path.

## Build, install, and run

```sh
./scripts/build.sh     # builds .build/eqYourMacbook.app (Debug)
./scripts/run.sh       # opens .build/eqYourMacbook.app
./scripts/install.sh   # test + build, installs to /Applications, launches it
```

`install.sh` is the one to use for real listening/M1 tests: it installs a
genuine `/Applications/eqYourMacbook.app` you can `kill -9` while it's running,
rather than a build-directory binary.

## Run unit tests

```sh
./scripts/test.sh
```

## Releases

Releases are cut from git tags. Pushing a `v*` tag runs the tests, builds a
Release `.app`, and publishes it as a GitHub Release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

To build the distributable zip locally:

```sh
./scripts/release.sh   # -> build/dist/eqYourMacbook.zip
```

The app is **ad-hoc signed** (personal-use; no Apple Developer team or
notarization). After downloading the released `.app`, strip its quarantine
attribute before first launch, otherwise Gatekeeper will refuse to open it:

```sh
xattr -dr com.apple.quarantine /path/to/eqYourMacbook.app
```

## Key documents

- **PLAN.md** — architecture decisions, milestones, API facts, risks
- **docs/CONTRACT.md** — Engine/App module interface (SSOT for parallel agents)

## Status

Builds and runs; all unit tests pass. Core EQ verified by ear on the built-in
speakers (M1). See PLAN.md §4 for the milestone roadmap and what is still open.
