import SwiftUI

// MARK: - UI Constants (single definition)

enum UIConstants {
    static let maxGainDB: Float = 24
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

    private let frequencies = BiquadResponse.logFrequencies(count: UIConstants.responsePoints)

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

        // 0 dB midline (slightly more prominent)
        let midY = size.height / 2
        gridPath.move(to: CGPoint(x: 0, y: midY))
        gridPath.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(gridPath, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)

        // ±6, ±12, ±18 dB horizontal lines
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

        // Octave vertical lines: 20, 40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 20000
        let octaveFreqs: [Double] = [20, 40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 20000]
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
        let activeBands = bands.filter { !$0.muted }
        let dbs = BiquadResponse.compositeResponse(
            bands: activeBands,
            sampleRate: UIConstants.referenceSampleRate,
            frequencies: frequencies
        )

        guard !dbs.isEmpty else { return }

        // Build the stroke path
        var curvePath = Path()
        for (i, (freq, db)) in zip(frequencies, dbs).enumerated() {
            let x = xForFreq(freq, width: size.width)
            let y = yForDB(Float(db), height: size.height)
            let pt = CGPoint(x: x, y: y)
            if i == 0 {
                curvePath.move(to: pt)
            } else {
                curvePath.addLine(to: pt)
            }
        }

        // Fill: close path down to midline
        var fillPath = curvePath
        let midY = size.height / 2
        fillPath.addLine(to: CGPoint(x: xForFreq(frequencies.last!, width: size.width), y: midY))
        fillPath.addLine(to: CGPoint(x: xForFreq(frequencies.first!, width: size.width), y: midY))
        fillPath.closeSubpath()

        ctx.fill(fillPath, with: .color(Color.accentColor.opacity(0.12)))
        ctx.stroke(curvePath, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    // MARK: - Coordinate helpers

    private func xForFreq(_ freq: Double, width: CGFloat) -> CGFloat {
        let logMin = log10(20.0)
        let logMax = log10(20000.0)
        let t = (log10(freq) - logMin) / (logMax - logMin)
        return CGFloat(t) * width
    }

    private func yForDB(_ db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(-Float(UIConstants.maxGainDB), min(Float(UIConstants.maxGainDB), db))
        let t = CGFloat((Float(UIConstants.maxGainDB) - clamped) / (2 * Float(UIConstants.maxGainDB)))
        return t * height
    }
}
