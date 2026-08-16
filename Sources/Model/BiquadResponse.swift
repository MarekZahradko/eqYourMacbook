// Adapted from iQualize (MIT, Copyright (c) 2026 Darius) — https://github.com/DariusCorvus/iqualize
import Foundation

// MARK: - Biquad Coefficients

struct BiquadCoefficients: Sendable {
    let b0: Double, b1: Double, b2: Double
    let a0: Double, a1: Double, a2: Double

    func gainDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * .pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2.0 * w), sin2W = sin(2.0 * w)

        // Normalize by a0
        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0
        let na1 = a1 / a0, na2 = a2 / a0

        let numReal = nb0 + nb1 * cosW + nb2 * cos2W
        let numImag = -(nb1 * sinW + nb2 * sin2W)
        let denReal = 1.0 + na1 * cosW + na2 * cos2W
        let denImag = -(na1 * sinW + na2 * sin2W)

        let numMagSq = numReal * numReal + numImag * numImag
        let denMagSq = denReal * denReal + denImag * denImag

        guard denMagSq > 1e-30 else { return -120.0 }
        return 10.0 * log10(numMagSq / denMagSq)
    }
}

// MARK: - Biquad Response Computation

enum BiquadResponse {

    /// Vicanek (2016) "Matched Second Order Digital Filters": given a fixed a0/a1/a2
    /// denominator, solve the b0/b1/b2 numerator whose squared magnitude exactly hits
    /// the requested linear-gain² at DC, Nyquist, and the corner (φ = sin²(w/2)).
    /// Sign choice (+√ for the DC-sum, −√ for b1) is pinned by
    /// testHighShelfMatchesVicanekGainAnchors — the other root has the same |H|² but wrong phase/poles.
    private static func vicanekMatchedNumerator(
        gainDCSq: Double, gainNyquistSq: Double, gainCornerSq: Double,
        phi0: Double, a0: Double, a1: Double, a2: Double,
        cosW0: Double, sinW0: Double
    ) -> (b0: Double, b1: Double, b2: Double) {
        func denomMagSq(cosW: Double, sinW: Double) -> Double {
            let cos2W = 2.0 * cosW * cosW - 1.0
            let sin2W = 2.0 * sinW * cosW
            let real = a0 + a1 * cosW + a2 * cos2W
            let imag = -(a1 * sinW + a2 * sin2W)
            return real * real + imag * imag
        }
        let dDC = denomMagSq(cosW: 1.0, sinW: 0.0)
        let dNyquist = denomMagSq(cosW: -1.0, sinW: 0.0)
        let dCorner = denomMagSq(cosW: cosW0, sinW: sinW0)

        let v0 = gainDCSq * dDC
        let v1 = gainNyquistSq * dNyquist
        let vC = gainCornerSq * dCorner

        // Quadratic p(phi) = p0 + p1*phi + p2*phi^2 through (0,v0), (1,v1), (phi0,vC).
        // Floor at 1e-9: a real corner (20 Hz at 96 kHz) gives phi0 ≈ 4.3e-7, which a
        // 1e-6 floor would clamp and mis-anchor.
        let phi0Safe = min(max(phi0, 1e-9), 1.0 - 1e-9)
        let p0 = v0
        let rhs1 = v1 - p0
        let rhs2 = vC - p0
        let p2 = (rhs2 - rhs1 * phi0Safe) / (phi0Safe * phi0Safe - phi0Safe)
        let p1 = rhs1 - p2

        // Recover b0,b1,b2 from (b0+b1+b2)^2=p0, 16*b0*b2=p2, -4*b1*(b0+b2)-16*b0*b2=p1.
        let s = sqrt(max(p0, 0.0))
        let disc1 = max(s * s + (p1 + p2), 0.0)
        let b1 = (s - sqrt(disc1)) / 2.0
        let u = s - b1 // b0 + b2
        let prod = p2 / 16.0
        let disc2 = max(u * u - 4.0 * prod, 0.0)
        let b0 = (u + sqrt(disc2)) / 2.0
        let b2 = (u - sqrt(disc2)) / 2.0
        return (b0, b1, b2)
    }

    /// Compute biquad coefficients for a band: RBJ cookbook peaking/BPF/notch,
    /// Vicanek matched shelf/LP/HP.
    static func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        // Nyquist-safe clamp: last line of defense before the math, independent of
        // EQBand's own validation — also prevents f0 > Nyquist silently aliasing (w0 > π).
        let f0 = min(Double(band.frequency), sampleRate * 0.49)
        // Gain is meaningless for bandPass/notch/lowPass/highPass; the UI already resets
        // it to 0 for these, but clamp here too in case a hand-edited preset bypasses that.
        let gain = FilterType.gainless.contains(band.filterType) ? 0.0 : Double(band.gain)
        let bw = Double(max(band.bandwidth, 0.05))

        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        // Bandwidth (octaves) → Q → alpha (RBJ cookbook BW→alpha formula). Shared
        // pole-placement parameter for every filter type below — the bandwidth-edge gain
        // match depends only on alpha/w0, not on A, so peaking/BPF/notch reuse it directly.
        let sinW0Safe = abs(sinW0) > 1e-10 ? sinW0 : 1e-10
        let Q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0Safe))
        let alpha = sinW0 / (2.0 * Q)

        let A = pow(10.0, gain / 40.0)

        let phi0 = (1.0 - cosW0) / 2.0

        switch band.filterType {
        case .parametric:
            // RBJ peaking shape; alpha (gain-independent, see above) gives an exact
            // bandwidth-edge gain of half the peak gain at the requested octave bandwidth.
            return BiquadCoefficients(
                b0: 1.0 + alpha * A,
                b1: -2.0 * cosW0,
                b2: 1.0 - alpha * A,
                a0: 1.0 + alpha / A,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha / A
            )

        case .lowShelf:
            // Vicanek matched shelf: gain anchored exactly at DC/Nyquist/f0.
            let a0 = 1.0 + alpha, a1 = -2.0 * cosW0, a2 = 1.0 - alpha
            let (b0, b1, b2) = vicanekMatchedNumerator(
                gainDCSq: A * A * A * A, gainNyquistSq: 1.0, gainCornerSq: A * A,
                phi0: phi0, a0: a0, a1: a1, a2: a2, cosW0: cosW0, sinW0: sinW0
            )
            return BiquadCoefficients(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .highShelf:
            // Vicanek matched shelf: gain anchored exactly at DC/Nyquist/f0.
            let a0 = 1.0 + alpha, a1 = -2.0 * cosW0, a2 = 1.0 - alpha
            let (b0, b1, b2) = vicanekMatchedNumerator(
                gainDCSq: 1.0, gainNyquistSq: A * A * A * A, gainCornerSq: A * A,
                phi0: phi0, a0: a0, a1: a1, a2: a2, cosW0: cosW0, sinW0: sinW0
            )
            return BiquadCoefficients(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .lowPass:
            // Vicanek matched low-pass: passband/Nyquist/cutoff gain anchored exactly.
            let a0 = 1.0 + alpha, a1 = -2.0 * cosW0, a2 = 1.0 - alpha
            let (b0, b1, b2) = vicanekMatchedNumerator(
                gainDCSq: 1.0, gainNyquistSq: 0.0, gainCornerSq: Q * Q,
                phi0: phi0, a0: a0, a1: a1, a2: a2, cosW0: cosW0, sinW0: sinW0
            )
            return BiquadCoefficients(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .highPass:
            // Vicanek matched high-pass: passband/Nyquist/cutoff gain anchored exactly.
            let a0 = 1.0 + alpha, a1 = -2.0 * cosW0, a2 = 1.0 - alpha
            let (b0, b1, b2) = vicanekMatchedNumerator(
                gainDCSq: 0.0, gainNyquistSq: 1.0, gainCornerSq: Q * Q,
                phi0: phi0, a0: a0, a1: a1, a2: a2, cosW0: cosW0, sinW0: sinW0
            )
            return BiquadCoefficients(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .bandPass:
            // RBJ BPF shape; gain is forced to 0 (A=1) for this type.
            return BiquadCoefficients(
                b0: alpha,
                b1: 0.0,
                b2: -alpha,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .notch:
            // RBJ notch shape; gain is forced to 0 (A=1) for this type.
            return BiquadCoefficients(
                b0: 1.0,
                b1: -2.0 * cosW0,
                b2: 1.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        }
    }

    /// Display-only coefficients for the UI curve preview: classic RBJ cookbook shelf/LP/HP
    /// forms (pre-Vicanek), NOT used for audio. `coefficients(for:sampleRate:)`'s Vicanek
    /// matching can make the curve dip/swing back near Nyquist when the corner sits close
    /// to it — correct for the signal, but reads as a confusing artifact to a user designing
    /// by eye. The cookbook form stays monotonic instead. parametric/bandPass/notch don't
    /// use Vicanek matching, so they're identical to `coefficients(for:sampleRate:)`.
    static func displayCoefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        let f0 = min(Double(band.frequency), sampleRate * 0.49)
        let gain = FilterType.gainless.contains(band.filterType) ? 0.0 : Double(band.gain)
        let bw = Double(max(band.bandwidth, 0.05))

        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        let sinW0Safe = abs(sinW0) > 1e-10 ? sinW0 : 1e-10
        let Q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0Safe))
        let alpha = sinW0 / (2.0 * Q)
        let A = pow(10.0, gain / 40.0)

        switch band.filterType {
        case .lowShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            return BiquadCoefficients(
                b0: A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha),
                b1: 2.0 * A * ((A - 1) - (A + 1) * cosW0),
                b2: A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha),
                a0: (A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha,
                a1: -2.0 * ((A - 1) + (A + 1) * cosW0),
                a2: (A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha
            )

        case .highShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            return BiquadCoefficients(
                b0: A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha),
                b1: -2.0 * A * ((A - 1) + (A + 1) * cosW0),
                b2: A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha),
                a0: (A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha,
                a1: 2.0 * ((A - 1) - (A + 1) * cosW0),
                a2: (A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha
            )

        case .lowPass:
            return BiquadCoefficients(
                b0: (1.0 - cosW0) / 2.0,
                b1: 1.0 - cosW0,
                b2: (1.0 - cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .highPass:
            return BiquadCoefficients(
                b0: (1.0 + cosW0) / 2.0,
                b1: -(1.0 + cosW0),
                b2: (1.0 + cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )

        case .parametric, .bandPass, .notch:
            return coefficients(for: band, sampleRate: sampleRate)
        }
    }
}
