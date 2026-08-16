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

    /// Shared pole-placement derivation for a band at a given sample rate: the Nyquist
    /// clamp, gainless-type gain override, bandwidth floor, w0/cosW0/sinW0, the RBJ
    /// sinh-based BW→Q→alpha chain, and the linear gain amplitude A. Both
    /// `coefficients(for:)` (Vicanek-matched shelf/LP/HP) and `displayCoefficients(for:)`
    /// (plain RBJ cookbook shelf/LP/HP) start from these identical numbers before
    /// diverging on the actual filter-shape formulas — this struct is that shared setup,
    /// factored out so it can't drift between the two call sites.
    private struct PoleParams {
        let f0: Double
        let w0: Double
        let cosW0: Double
        let sinW0: Double
        let Q: Double
        let alpha: Double
        let A: Double
        let phi0: Double

        init(band: EQBand, sampleRate: Double) {
            // Nyquist-safe clamp: last line of defense before the math, independent of
            // EQBand's own validation — also prevents f0 > Nyquist silently aliasing (w0 > π).
            f0 = min(Double(band.frequency), sampleRate * 0.49)
            // Gain is meaningless for bandPass/notch/lowPass/highPass; the UI already resets
            // it to 0 for these, but clamp here too in case a hand-edited preset bypasses that.
            let gain = FilterType.gainless.contains(band.filterType) ? 0.0 : Double(band.gain)
            let bw = Double(max(band.bandwidth, 0.05))

            w0 = 2.0 * .pi * f0 / sampleRate
            cosW0 = cos(w0)
            sinW0 = sin(w0)

            // Bandwidth (octaves) → Q → alpha (RBJ cookbook BW→alpha formula). Shared
            // pole-placement parameter for every filter type below — the bandwidth-edge gain
            // match depends only on alpha/w0, not on A, so peaking/BPF/notch reuse it directly.
            let sinW0Safe = abs(sinW0) > 1e-10 ? sinW0 : 1e-10
            Q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0Safe))
            alpha = sinW0 / (2.0 * Q)

            A = pow(10.0, gain / 40.0)

            phi0 = (1.0 - cosW0) / 2.0
        }
    }

    /// Shared a0/a1/a2 + vicanekMatchedNumerator + BiquadCoefficients construction used
    /// identically by the .lowShelf/.highShelf/.lowPass/.highPass cases below — they
    /// differ only in which three gain anchors they pass in.
    private static func vicanekMatchedCoefficients(
        gainDCSq: Double, gainNyquistSq: Double, gainCornerSq: Double, pole: PoleParams
    ) -> BiquadCoefficients {
        let a0 = 1.0 + pole.alpha, a1 = -2.0 * pole.cosW0, a2 = 1.0 - pole.alpha
        let (b0, b1, b2) = vicanekMatchedNumerator(
            gainDCSq: gainDCSq, gainNyquistSq: gainNyquistSq, gainCornerSq: gainCornerSq,
            phi0: pole.phi0, a0: a0, a1: a1, a2: a2, cosW0: pole.cosW0, sinW0: pole.sinW0
        )
        return BiquadCoefficients(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// Compute biquad coefficients for a band: RBJ cookbook peaking/BPF/notch,
    /// Vicanek matched shelf/LP/HP.
    static func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        let p = PoleParams(band: band, sampleRate: sampleRate)

        switch band.filterType {
        case .parametric:
            // RBJ peaking shape; alpha (gain-independent, see above) gives an exact
            // bandwidth-edge gain of half the peak gain at the requested octave bandwidth.
            return BiquadCoefficients(
                b0: 1.0 + p.alpha * p.A,
                b1: -2.0 * p.cosW0,
                b2: 1.0 - p.alpha * p.A,
                a0: 1.0 + p.alpha / p.A,
                a1: -2.0 * p.cosW0,
                a2: 1.0 - p.alpha / p.A
            )

        case .lowShelf:
            // Vicanek matched shelf: gain anchored exactly at DC/Nyquist/f0.
            return vicanekMatchedCoefficients(
                gainDCSq: p.A * p.A * p.A * p.A, gainNyquistSq: 1.0, gainCornerSq: p.A * p.A,
                pole: p
            )

        case .highShelf:
            // Vicanek matched shelf: gain anchored exactly at DC/Nyquist/f0.
            return vicanekMatchedCoefficients(
                gainDCSq: 1.0, gainNyquistSq: p.A * p.A * p.A * p.A, gainCornerSq: p.A * p.A,
                pole: p
            )

        case .lowPass:
            // Vicanek matched low-pass: passband/Nyquist/cutoff gain anchored exactly.
            return vicanekMatchedCoefficients(
                gainDCSq: 1.0, gainNyquistSq: 0.0, gainCornerSq: p.Q * p.Q, pole: p
            )

        case .highPass:
            // Vicanek matched high-pass: passband/Nyquist/cutoff gain anchored exactly.
            return vicanekMatchedCoefficients(
                gainDCSq: 0.0, gainNyquistSq: 1.0, gainCornerSq: p.Q * p.Q, pole: p
            )

        case .bandPass:
            // RBJ BPF shape; gain is forced to 0 (A=1) for this type.
            return BiquadCoefficients(
                b0: p.alpha,
                b1: 0.0,
                b2: -p.alpha,
                a0: 1.0 + p.alpha,
                a1: -2.0 * p.cosW0,
                a2: 1.0 - p.alpha
            )

        case .notch:
            // RBJ notch shape; gain is forced to 0 (A=1) for this type.
            return BiquadCoefficients(
                b0: 1.0,
                b1: -2.0 * p.cosW0,
                b2: 1.0,
                a0: 1.0 + p.alpha,
                a1: -2.0 * p.cosW0,
                a2: 1.0 - p.alpha
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
        let p = PoleParams(band: band, sampleRate: sampleRate)

        switch band.filterType {
        case .lowShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(p.A) * p.alpha
            return BiquadCoefficients(
                b0: p.A * ((p.A + 1) - (p.A - 1) * p.cosW0 + twoSqrtAAlpha),
                b1: 2.0 * p.A * ((p.A - 1) - (p.A + 1) * p.cosW0),
                b2: p.A * ((p.A + 1) - (p.A - 1) * p.cosW0 - twoSqrtAAlpha),
                a0: (p.A + 1) + (p.A - 1) * p.cosW0 + twoSqrtAAlpha,
                a1: -2.0 * ((p.A - 1) + (p.A + 1) * p.cosW0),
                a2: (p.A + 1) + (p.A - 1) * p.cosW0 - twoSqrtAAlpha
            )

        case .highShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(p.A) * p.alpha
            return BiquadCoefficients(
                b0: p.A * ((p.A + 1) + (p.A - 1) * p.cosW0 + twoSqrtAAlpha),
                b1: -2.0 * p.A * ((p.A - 1) + (p.A + 1) * p.cosW0),
                b2: p.A * ((p.A + 1) + (p.A - 1) * p.cosW0 - twoSqrtAAlpha),
                a0: (p.A + 1) - (p.A - 1) * p.cosW0 + twoSqrtAAlpha,
                a1: 2.0 * ((p.A - 1) - (p.A + 1) * p.cosW0),
                a2: (p.A + 1) - (p.A - 1) * p.cosW0 - twoSqrtAAlpha
            )

        case .lowPass:
            return BiquadCoefficients(
                b0: (1.0 - p.cosW0) / 2.0,
                b1: 1.0 - p.cosW0,
                b2: (1.0 - p.cosW0) / 2.0,
                a0: 1.0 + p.alpha,
                a1: -2.0 * p.cosW0,
                a2: 1.0 - p.alpha
            )

        case .highPass:
            return BiquadCoefficients(
                b0: (1.0 + p.cosW0) / 2.0,
                b1: -(1.0 + p.cosW0),
                b2: (1.0 + p.cosW0) / 2.0,
                a0: 1.0 + p.alpha,
                a1: -2.0 * p.cosW0,
                a2: 1.0 - p.alpha
            )

        case .parametric, .bandPass, .notch:
            return coefficients(for: band, sampleRate: sampleRate)
        }
    }
}
