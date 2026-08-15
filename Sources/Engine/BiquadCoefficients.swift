// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
// Extracted from BiquadFilter.swift — NormalizedBiquadCoeffs only; scalar BiquadFilterChain dropped
// (we use vDSP_biquadm for SIMD processing per PLAN.md §2 DSP).
import Foundation

// MARK: - Normalized Biquad Coefficients

/// Pre-normalized biquad coefficients (divided by a0) for real-time processing.
struct NormalizedBiquadCoeffs: Sendable {
    let b0: Double, b1: Double, b2: Double
    let a1: Double, a2: Double

    // Stays Double throughout: the vDSP setup this feeds is Double-precision, so
    // truncating to Float here and widening back would only discard precision for
    // no benefit.
    init(from raw: BiquadCoefficients) {
        b0 = raw.b0 / raw.a0
        b1 = raw.b1 / raw.a0
        b2 = raw.b2 / raw.a0
        a1 = raw.a1 / raw.a0
        a2 = raw.a2 / raw.a0
    }

    static let passthrough = NormalizedBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }
}
