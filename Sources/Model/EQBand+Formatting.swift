// Display-string formatting helpers for EQBand (frequency/gain/bandwidth labels).

import Foundation

extension EQBand {
    var frequencyLabel: String {
        if frequency >= 1000 {
            let k = frequency / 1000
            if k == Float(Int(k)) {
                return "\(Int(k)) kHz"
            } else {
                return String(format: "%.1f kHz", k)
            }
        } else if frequency == Float(Int(frequency)) {
            return "\(Int(frequency)) Hz"
        } else {
            return String(format: "%.1f Hz", frequency)
        }
    }

    /// Convert bandwidth in octaves to Q factor (frequency-independent approximation).
    static func octavesToQ(_ bw: Float) -> Float {
        let p = powf(2, bw)
        return sqrtf(p) / (p - 1)
    }

    static func qToOctaves(_ q: Float) -> Float {
        return 2 * asinh(1 / (2 * q)) / logf(2)
    }

    func bandwidthLabel(asQ: Bool) -> String {
        if asQ {
            let q = Self.octavesToQ(bandwidth)
            if q >= 10 {
                return String(format: "Q %.0f", q)
            }
            return String(format: "Q %.2f", q)
        } else {
            if bandwidth == Float(Int(bandwidth)) {
                return "\(Int(bandwidth)) oct"
            }
            return String(format: "%.1f oct", bandwidth)
        }
    }

    var gainLabel: String {
        if gain == 0 { return "0 dB" }
        if gain == Float(Int(gain)) {
            return String(format: "%+d dB", Int(gain))
        }
        return String(format: "%+.1f dB", gain)
    }
}
