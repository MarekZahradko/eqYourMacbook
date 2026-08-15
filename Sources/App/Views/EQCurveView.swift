import SwiftUI

// MARK: - UI Constants (single definition)

enum UIConstants {
    // Derived from EQBand.gainRange (Sources/Model/EQModels.swift), the enforced
    // model invariant — assumes that range is symmetric about 0, which it is
    // (-24...24). Kept as its own constant (rather than inlining gainRange.upperBound
    // at each call site) since callers here want a scalar magnitude, not a range.
    static let maxGainDB: Float = EQBand.gainRange.upperBound
    static let panelWidth: CGFloat = 360
    static let curveHeight: CGFloat = 130
    // Built-in MacBook speakers run at 48 kHz regardless of system sample rate.
    // The engine uses the actual device-read rate at runtime; this constant is
    // only a UI approximation for drawing the curve against built-in speakers.
    static let referenceSampleRate: Double = 48000
    static let responsePoints = 200
}

// MARK: - EQCurveView

struct EQCurveView: View {
    let bands: [EQBand]
    let dimmed: Bool   // bypass or disabled state

    // Pure function of a fixed constant (UIConstants.responsePoints never varies at
    // runtime) — computed once for the type rather than per-instance-init, since a
    // stored instance property here was being recomputed (~200 pow() calls) on every
    // SwiftUI redraw of this View value.
    private static let logFrequencies = BiquadResponse.logFrequencies(count: UIConstants.responsePoints)

    // Single-entry memoization for BiquadResponse.compositeResponse(): that call rebuilds
    // full biquad coefficients (sqrt/sinh/log/pow per band) and evaluates them at every
    // log-frequency point from scratch, which is wasted work when `bands` hasn't
    // actually changed since the last redraw (e.g. a redraw triggered by an unrelated
    // @Published change like deviceRows updating from a watchdog transition). @State
    // gives this cache instance stable identity across body re-evaluations for this
    // view; only its own internal vars are mutated (never the @State box itself), so
    // this does not trip SwiftUI's "modifying state during view update" diagnostics.
    @State private var responseCache = CompositeResponseCache()

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx: ctx, size: size)
            drawCurve(ctx: ctx, size: size)
        }
        .frame(height: UIConstants.curveHeight)
        .opacity(dimmed ? 0.35 : 1.0)
    }

    // MARK: - Grid

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let gridColor = Color.secondary.opacity(0.2)
        var gridPath = Path()

        let midY = size.height / 2
        gridPath.move(to: CGPoint(x: 0, y: midY))
        gridPath.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(gridPath, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)

        let dbMarks: [Float] = [6, 12, 18]
        for db in dbMarks {
            for sign: Float in [1, -1] {
                var p = Path()
                let y = yForDB(sign * db, height: size.height)
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }
        }

        // Endpoints tie to EQBand.frequencyRange; the interior grid marks are fixed
        // octave-ish points independent of that range.
        let octaveFreqs: [Double] = [Double(EQBand.frequencyRange.lowerBound),
                                      40, 80, 160, 315, 630, 1250, 2500, 5000, 10000,
                                      Double(EQBand.frequencyRange.upperBound)]
        for f in octaveFreqs {
            var p = Path()
            let x = xForFreq(f, width: size.width)
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    // MARK: - Curve

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        // Note: activeBands (post-mute-filter) is the actual input compositeResponse
        // depends on, so the cache is keyed on it rather than on `bands` directly —
        // EQBand.== deliberately ignores `muted` (preset-identity semantics, see
        // EQModels.swift), so keying on raw `bands` would miss a pure mute toggle.
        // Filtering first means every element remaining in activeBands has muted ==
        // false, so that ignored-field caveat doesn't matter for this comparison.
        let activeBands = bands.filter { !$0.muted }
        let dbs = responseCache.response(
            bands: activeBands,
            sampleRate: UIConstants.referenceSampleRate,
            frequencies: Self.logFrequencies
        )

        guard !dbs.isEmpty else { return }

        var curvePath = Path()
        for (i, (freq, db)) in zip(Self.logFrequencies, dbs).enumerated() {
            let x = xForFreq(freq, width: size.width)
            let y = yForDB(Float(db), height: size.height)
            let pt = CGPoint(x: x, y: y)
            if i == 0 {
                curvePath.move(to: pt)
            } else {
                curvePath.addLine(to: pt)
            }
        }

        var fillPath = curvePath
        let midY = size.height / 2
        fillPath.addLine(to: CGPoint(x: xForFreq(Self.logFrequencies.last!, width: size.width), y: midY))
        fillPath.addLine(to: CGPoint(x: xForFreq(Self.logFrequencies.first!, width: size.width), y: midY))
        fillPath.closeSubpath()

        ctx.fill(fillPath, with: .color(Color.accentColor.opacity(0.12)))
        ctx.stroke(curvePath, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    // MARK: - Coordinate helpers

    private func xForFreq(_ freq: Double, width: CGFloat) -> CGFloat {
        let logMin = log10(Double(EQBand.frequencyRange.lowerBound))
        let logMax = log10(Double(EQBand.frequencyRange.upperBound))
        let t = (log10(freq) - logMin) / (logMax - logMin)
        return CGFloat(t) * width
    }

    private func yForDB(_ db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(-Float(UIConstants.maxGainDB), min(Float(UIConstants.maxGainDB), db))
        let t = CGFloat((Float(UIConstants.maxGainDB) - clamped) / (2 * Float(UIConstants.maxGainDB)))
        return t * height
    }
}

// MARK: - CompositeResponseCache

/// Last-computed-result cache for BiquadResponse.compositeResponse(), keyed on the exact
/// inputs that determine its output (bands, sampleRate — `frequencies` is always
/// EQCurveView.logFrequencies, a fixed constant, so it isn't part of the key). A single
/// entry is sufficient: EQCurveView shows one bands array at a time, so there's nothing
/// to evict/rotate between multiple keys, unlike the engine's genuinely-multi-device
/// per-device cache.
private final class CompositeResponseCache {
    private var lastBands: [EQBand]?
    private var lastSampleRate: Double?
    private var lastResult: [Double] = []

    func response(bands: [EQBand], sampleRate: Double, frequencies: [Double]) -> [Double] {
        if let lastBands, let lastSampleRate,
           lastBands == bands, lastSampleRate == sampleRate {
            return lastResult
        }
        let result = BiquadResponse.compositeResponse(bands: bands, sampleRate: sampleRate, frequencies: frequencies)
        lastBands = bands
        lastSampleRate = sampleRate
        lastResult = result
        return result
    }
}
