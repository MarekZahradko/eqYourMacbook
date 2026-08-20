# eqYourMacbook

A tiny menu-bar parametric EQ. Pick which single output device to EQ from any available output device (checkbox list, mutually exclusive; built-in speakers enabled by default). No Dock icon, no audio driver install. Uses the macOS 14.4+ process-tap API (CATap → private aggregate device → IOProc → vDSP biquads) to intercept and equalize system audio with near-zero idle CPU cost. That device's EQ only actually runs while it's also the OS's current default output — the app never selects or overrides output routing itself.

## Filter quality

Each band is a biquad filter, cascaded via Accelerate's `vDSP_biquadm` in
double precision for near-zero CPU cost with numerically stable accuracy.
Peaking, band-pass, and notch bands use the standard RBJ Audio EQ Cookbook
design; shelf, low-pass, and high-pass bands use Vicanek's matched-filter
design, which tracks the true analog response more closely near Nyquist than
the RBJ approximation. Gain-staging auto-attenuates positive-gain bands to
avoid clipping, and coefficient updates are ramped smoothly, so slider drags
don't produce zipper noise.

## Build prerequisites

- macOS 26 — needed for a Swift 6.2+ toolchain (`-default-isolation` support);
  the app itself still targets macOS 14.4+ at runtime
- Command Line Tools only — **no full Xcode.app required** (`xcode-select --install`)

The app is built directly with `swiftc` (see `./build.sh`); SPM
(`Package.swift`) is used only to run unit tests. No `xcodebuild`, no
`xcodegen`, no `.xcodeproj` on the build path.

## Build, install, and run

```sh
./build.sh     # builds .build/eqYourMacbook.app (Debug)
./run.sh       # opens .build/eqYourMacbook.app
./install.sh   # test + build, installs to /Applications, launches it
```

`install.sh` is the one to use for real listening/M1 tests: it installs a
genuine `/Applications/eqYourMacbook.app` you can `kill -9` while it's running,
rather than a build-directory binary.

## Run unit tests

```sh
./test.sh
```

## Key documents

- **CLAUDE.md** — build/test loop, non-negotiable rules, and the invariants the
  code depends on (tap/mute semantics, teardown order, watchdog policy)

## License

MIT — see [LICENSE](LICENSE). Portions cherry-picked from
[iQualize](https://github.com/DariusCorvus/iqualize) (MIT); those files keep
their attribution headers.
