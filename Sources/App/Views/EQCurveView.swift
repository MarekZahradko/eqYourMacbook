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

    // Single-entry memoization for BiquadResponse.compositeResponse(): avoids rebuilding
    // full coefficients (sqrt/sinh/log/pow per band) when `bands` hasn't changed since the
    // last redraw (e.g. a redraw from an unrelated @Published change). @State gives this
    // cache stable identity across body re-evaluations; only its internal vars mutate
    // (never the @State box itself), so it doesn't trip SwiftUI's state-during-update checks.
    @State private var responseCache = CompositeResponseCache()

    var body: some View {
        Canvas { ctx, size in
            let plot = plotRect(for: size)
            drawGrid(ctx: ctx, plot: plot)
            drawCurve(ctx: ctx, plot: plot)
        }
        .frame(height: UIConstants.curveHeight)
        .opacity(dimmed ? 0.35 : 1.0)
    }

    // MARK: - Layout

    // Reserves a left gutter for dB-axis labels and a bottom gutter for frequency-axis
    // labels; the actual curve/grid draw into the remaining `plot` rect so labels never
    // overlap the curve itself.
    private static let leftMargin: CGFloat = 22
    private static let bottomMargin: CGFloat = 14

    private func plotRect(for size: CGSize) -> CGRect {
        CGRect(
            x: Self.leftMargin,
            y: 0,
            width: max(0, size.width - Self.leftMargin),
            height: max(0, size.height - Self.bottomMargin)
        )
    }

    // MARK: - Grid

    private func drawGrid(ctx: GraphicsContext, plot: CGRect) {
        let gridColor = Color.secondary.opacity(0.2)
        var gridPath = Path()

        let midY = plot.minY + plot.height / 2
        gridPath.move(to: CGPoint(x: plot.minX, y: midY))
        gridPath.addLine(to: CGPoint(x: plot.maxX, y: midY))
        ctx.stroke(gridPath, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        drawLabel("0", at: CGPoint(x: Self.leftMargin - 4, y: midY), ctx: ctx, align: .trailing)

        let dbMarks: [Float] = [6, 12, 18]
        for db in dbMarks {
            for sign: Float in [1, -1] {
                var p = Path()
                let y = yForDB(sign * db, plot: plot)
                p.move(to: CGPoint(x: plot.minX, y: y))
                p.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }
            // Only label every other ring (±6, ±18) to avoid crowding the narrow gutter;
            // ±12 is implied by the midpoint spacing between labeled rings.
            if db != 12 {
                drawLabel("+\(Int(db))", at: CGPoint(x: Self.leftMargin - 4, y: yForDB(db, plot: plot)), ctx: ctx, align: .trailing)
                drawLabel("-\(Int(db))", at: CGPoint(x: Self.leftMargin - 4, y: yForDB(-db, plot: plot)), ctx: ctx, align: .trailing)
            }
        }

        // Endpoints tie to EQBand.frequencyRange; the interior grid marks are fixed
        // octave-ish points independent of that range.
        let octaveFreqs: [Double] = [Double(EQBand.frequencyRange.lowerBound),
                                      40, 80, 160, 315, 630, 1250, 2500, 5000, 10000,
                                      Double(EQBand.frequencyRange.upperBound)]
        // Only a sparse subset gets a text label — labeling every gridline in a 360pt-wide
        // panel would overlap; these are the values users actually reference (100 Hz not
        // among logMarks below since 160 Hz is close enough and avoids crowding 40/80).
        let labeledFreqs: Set<Double> = [Double(EQBand.frequencyRange.lowerBound), 100, 1000, 10000,
                                          Double(EQBand.frequencyRange.upperBound)]
        for f in octaveFreqs {
            var p = Path()
            let x = xForFreq(f, plot: plot)
            p.move(to: CGPoint(x: x, y: plot.minY))
            p.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
        }
        for f in [Double(EQBand.frequencyRange.lowerBound), 100, 1000, 10000, Double(EQBand.frequencyRange.upperBound)]
        where labeledFreqs.contains(f) {
            let x = xForFreq(f, plot: plot)
            let text = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
            // Edge labels are nudged inward (leading/trailing instead of centered) so they
            // don't get clipped by the panel's own edge.
            let align: HorizontalAlignment = f == Double(EQBand.frequencyRange.lowerBound) ? .leading
                : f == Double(EQBand.frequencyRange.upperBound) ? .trailing : .center
            drawLabel(text, at: CGPoint(x: x, y: plot.maxY + 2), ctx: ctx, align: align, vertical: .top)
        }
    }

    private func drawLabel(
        _ text: String, at point: CGPoint, ctx: GraphicsContext,
        align: HorizontalAlignment = .center, vertical: VerticalAlignment = .center
    ) {
        let resolved = ctx.resolve(Text(text).font(.system(size: 8)).foregroundColor(.secondary))
        let sz = resolved.measure(in: CGSize(width: 100, height: 20))
        let x: CGFloat
        switch align {
        case .leading: x = point.x
        case .trailing: x = point.x - sz.width
        default: x = point.x - sz.width / 2
        }
        let y: CGFloat
        switch vertical {
        case .top: y = point.y
        case .bottom: y = point.y - sz.height
        default: y = point.y - sz.height / 2
        }
        ctx.draw(resolved, at: CGPoint(x: x + sz.width / 2, y: y + sz.height / 2))
    }

    // MARK: - Curve

    private func drawCurve(ctx: GraphicsContext, plot: CGRect) {
        // Cache is keyed on activeBands (post-mute-filter), not raw `bands`: EQBand.==
        // ignores `muted` (preset-identity semantics), so keying on raw `bands` would miss
        // a pure mute toggle. Filtering first sidesteps that since every remaining element has muted == false.
        let activeBands = bands.filter { !$0.muted }
        let dbs = responseCache.response(
            bands: activeBands,
            sampleRate: UIConstants.referenceSampleRate,
            frequencies: Self.logFrequencies
        )

        guard !dbs.isEmpty else { return }

        var curvePath = Path()
        for (i, (freq, db)) in zip(Self.logFrequencies, dbs).enumerated() {
            let x = xForFreq(freq, plot: plot)
            let y = yForDB(Float(db), plot: plot)
            let pt = CGPoint(x: x, y: y)
            if i == 0 {
                curvePath.move(to: pt)
            } else {
                curvePath.addLine(to: pt)
            }
        }

        var fillPath = curvePath
        let midY = plot.minY + plot.height / 2
        fillPath.addLine(to: CGPoint(x: xForFreq(Self.logFrequencies.last!, plot: plot), y: midY))
        fillPath.addLine(to: CGPoint(x: xForFreq(Self.logFrequencies.first!, plot: plot), y: midY))
        fillPath.closeSubpath()

        ctx.fill(fillPath, with: .color(Color.accentColor.opacity(0.12)))
        ctx.stroke(curvePath, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    // MARK: - Coordinate helpers

    private func xForFreq(_ freq: Double, plot: CGRect) -> CGFloat {
        let logMin = log10(Double(EQBand.frequencyRange.lowerBound))
        let logMax = log10(Double(EQBand.frequencyRange.upperBound))
        let t = (log10(freq) - logMin) / (logMax - logMin)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func yForDB(_ db: Float, plot: CGRect) -> CGFloat {
        let clamped = max(-Float(UIConstants.maxGainDB), min(Float(UIConstants.maxGainDB), db))
        let t = CGFloat((Float(UIConstants.maxGainDB) - clamped) / (2 * Float(UIConstants.maxGainDB)))
        return plot.minY + t * plot.height
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
