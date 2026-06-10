// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
// Extracted from BiquadFilter.swift — NormalizedBiquadCoeffs only; scalar BiquadFilterChain dropped
// (we use vDSP_biquadm for SIMD processing per PLAN.md §2 DSP).
import Foundation

// MARK: - Normalized Biquad Coefficients

/// Pre-normalized biquad coefficients (divided by a0) for real-time processing.
struct NormalizedBiquadCoeffs: Sendable {
    let b0: Float, b1: Float, b2: Float
    let a1: Float, a2: Float

    init(from raw: BiquadCoefficients) {
        let a0 = Float(raw.a0)
        b0 = Float(raw.b0) / a0
        b1 = Float(raw.b1) / a0
        b2 = Float(raw.b2) / a0
        a1 = Float(raw.a1) / a0
        a2 = Float(raw.a2) / a0
    }

    static let passthrough = NormalizedBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }
}
