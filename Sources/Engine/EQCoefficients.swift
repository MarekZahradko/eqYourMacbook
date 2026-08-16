// Pure, allocation-free coefficient-layout math shared by every per-device engine and
// by the RT IOProc factory (EQDeviceRTContext.makeIOBlock). Extracted out of the
// (formerly single-instance) EQEngine so N per-device EQDeviceEngine instances and the
// RT context can both reach it without depending on the full engine class. No CoreAudio
// here — math only, kept nonisolated/static so it's callable from anywhere (including
// unit tests) with zero setup.

import Accelerate
import Foundation

enum EQCoefficients {

    // Pre-allocated RT capacities (CONTRACT.md: max 16 sections, 2 channels).
    // CANONICAL value lives on EQPresetData.maxBandCount (Sources/Model) — the RT
    // buffer just needs to hold at least as many sections as a preset can have bands;
    // mirrored here rather than re-declared so the two ceilings can't drift apart.
    static let maxSections = EQPresetData.maxBandCount
    static let channels = 2

    /// SINGLE POINT OF TRUTH for the (section, channel) → flat coefficient index in
    /// the `5 * channels * sections` array vDSP_biquadm wants. Laid out SECTION-MAJOR
    /// (channel varies fastest: s0ch0, s0ch1, s1ch0, s1ch1, …).
    ///
    /// vDSP_biquadm's expected layout was disputed; section-major is empirical, pinned
    /// by the canary test testVDSPBiquadmStereoMatchesScalarReference. If that fails on
    /// the Mac, flip ONLY this helper (channel-major = `(channel * sections + section) * 5`)
    /// — every builder/reader routes through it.
    static func flatIndex(section: Int, channel: Int, channels: Int) -> Int {
        (section * channels + channel) * 5
    }

    /// Pure mapping: EQBand list → flat double coefficient array in the layout
    /// vDSP_biquadm_CreateSetup(coeffs, M=sections, N=channels) expects: `5 * channels
    /// * sections` doubles, SECTION-MAJOR via `flatIndex`. Each section is 5 doubles,
    /// order **[b0, b1, b2, a1, a2]**. Same cascade applied to both channels.
    ///
    /// vDSP computes y[s][n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
    /// (subtracts the a-terms internally), so a1/a2 are passed in their natural
    /// transfer-function sign, not negated — matches BiquadResponse's RBJ output and
    /// iqualize's scalar DFII-T loop.
    ///
    /// Muted bands are skipped. Unused sections (and any beyond 16) are identity
    /// passthrough (b0=1, rest 0). bands.count > 16 is silently clamped to 16.
    ///
    /// `channels` defaults to the fixed engine channel count; tests build a single
    /// channel to compare against a scalar reference.
    //
    // Multi-entry memoization, keyed per distinct device configuration
    // (bands/mutedFlags/sampleRate/channels/masterGainDB). N devices commonly share
    // bands/masterGainDB but can differ in sampleRate — a single-slot cache thrashed to
    // near-0% hit rate with 2+ devices at different sample rates, since each device's
    // coalesced update tick evicted the other's entry. Capacity is a small bound
    // (`cacheCapacity`) with simple LRU eviction; the app's own soft cap is 4
    // simultaneous devices (OutputDeviceEQCoordinator.maxSimultaneousDevices), so a
    // handful of entries is enough.
    //
    // Thread-safety: `sectionCoefficients` is called only from the main-actor
    // coalescing path (EQDeviceEngine+LiveUpdate.swift's flushPendingUpdate,
    // EQDeviceEngine+RTState.swift's installBiquadSetup) — NEVER from the RT IOProc
    // callback — so a lock here is not an RT-safety violation. It IS still needed:
    // Tests/eqYourMacbookTests/EngineCoefficientTests.swift's `@Test` functions run
    // concurrently by default (Swift Testing parallelizes within a non-`.serialized`
    // `@Suite`) and were mutating this single static cache with no synchronization at
    // all — a real concurrent read/write race on the cache's backing Arrays (COW,
    // refcounted), independent of the per-device thrash problem above. A plain `NSLock`
    // around the small linear scan is simplest here (an array, not a Dictionary:
    // `EQBand` isn't `Hashable`, and a ≤`cacheCapacity`-entry scan is cheap enough that
    // keying by a hash isn't worth it).
    //
    // EQBand.== ignores `muted`/`id` (preset value identity, not runtime state), but
    // muted affects this function's output, so the cache key tracks it separately.
    private static let cacheCapacity = 8

    private final class CoefficientCache: @unchecked Sendable {
        struct Entry {
            let bands: [EQBand]
            let mutedFlags: [Bool]
            let sampleRate: Double
            let channels: Int
            let masterGainDB: Double
            let result: [Double]
        }

        private let lock = NSLock()
        // Ordered least-recently-used → most-recently-used (appended on hit/store).
        private var entries: [Entry] = []

        private func matches(_ e: Entry, bands: [EQBand], mutedFlags: [Bool],
                              sampleRate: Double, channels: Int, masterGainDB: Double) -> Bool {
            e.sampleRate == sampleRate && e.channels == channels && e.masterGainDB == masterGainDB
                && e.mutedFlags == mutedFlags && e.bands == bands
        }

        func lookup(bands: [EQBand], mutedFlags: [Bool], sampleRate: Double,
                    channels: Int, masterGainDB: Double) -> [Double]? {
            lock.lock()
            defer { lock.unlock() }
            guard let idx = entries.firstIndex(where: {
                matches($0, bands: bands, mutedFlags: mutedFlags, sampleRate: sampleRate,
                        channels: channels, masterGainDB: masterGainDB)
            }) else { return nil }
            let entry = entries.remove(at: idx)
            entries.append(entry)   // most-recently-used moves to the end
            return entry.result
        }

        func store(bands: [EQBand], mutedFlags: [Bool], sampleRate: Double,
                    channels: Int, masterGainDB: Double, result: [Double]) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll {
                matches($0, bands: bands, mutedFlags: mutedFlags, sampleRate: sampleRate,
                        channels: channels, masterGainDB: masterGainDB)
            }
            entries.append(Entry(bands: bands, mutedFlags: mutedFlags, sampleRate: sampleRate,
                                  channels: channels, masterGainDB: masterGainDB, result: result))
            if entries.count > cacheCapacity {
                entries.removeFirst(entries.count - cacheCapacity)   // evict least-recently-used
            }
        }
    }

    private static let cache = CoefficientCache()

    static func sectionCoefficients(for bands: [EQBand], sampleRate: Double,
                                     channels: Int = EQCoefficients.channels,
                                     masterGainDB: Double = 0) -> [Double] {
        let mutedFlags = bands.map(\.muted)
        if let cached = cache.lookup(bands: bands, mutedFlags: mutedFlags, sampleRate: sampleRate,
                                      channels: channels, masterGainDB: masterGainDB) {
            return cached
        }
        var out = [Double](repeating: 0, count: maxSections * 5 * channels)
        // Identity everywhere first (b0=1, rest 0).
        for s in 0..<maxSections {
            for c in 0..<channels {
                out[flatIndex(section: s, channel: c, channels: channels)] = 1
            }
        }
        let active = bands.filter { !$0.muted }.prefix(maxSections)
        for (s, band) in active.enumerated() {
            let n = NormalizedBiquadCoeffs(from: BiquadResponse.coefficients(for: band, sampleRate: sampleRate))
            for c in 0..<channels {
                let base = flatIndex(section: s, channel: c, channels: channels)
                out[base + 0] = n.b0
                out[base + 1] = n.b1
                out[base + 2] = n.b2
                out[base + 3] = n.a1
                out[base + 4] = n.a2
            }
        }
        // Fold the (always ≤ 0 dB) master compensation into section 0's numerator:
        // sections cascade in series, so scaling one section's b-terms scales the
        // whole chain by the same factor, whether or not section 0 is active.
        if masterGainDB != 0 {
            let linearGain = pow(10.0, masterGainDB / 20.0)
            for c in 0..<channels {
                let base = flatIndex(section: 0, channel: c, channels: channels)
                out[base + 0] *= linearGain
                out[base + 1] *= linearGain
                out[base + 2] *= linearGain
            }
        }
        cache.store(bands: bands, mutedFlags: mutedFlags, sampleRate: sampleRate,
                    channels: channels, masterGainDB: masterGainDB, result: out)
        return out
    }

    /// Gain-staging compensation: only ever attenuates (never boosts), engaging solely
    /// when the largest non-muted band gain is positive. Disabled → always 0.
    static func masterGainDB(for bands: [EQBand], enabled: Bool) -> Double {
        guard enabled else { return 0 }
        let maxGain = bands.filter { !$0.muted }.map(\.gain).max() ?? 0
        return maxGain > 0 ? -Double(maxGain) : 0
    }
}
