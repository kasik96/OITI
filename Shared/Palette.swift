import Foundation

/// A false-colour map stored as a 256-entry RGBA lookup table.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let lut: [UInt8] // 256 * 4, RGBA8

    private static func build(_ id: String, _ name: String, _ stops: [(Double, (Double, Double, Double))]) -> Palette {
        var lut = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255
            var lo = stops[0], hi = stops[stops.count - 1]
            for k in 0..<(stops.count - 1) where t >= stops[k].0 && t <= stops[k + 1].0 {
                lo = stops[k]; hi = stops[k + 1]; break
            }
            let span = Swift.max(1e-9, hi.0 - lo.0)
            let f = Swift.min(1, Swift.max(0, (t - lo.0) / span))
            func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8(Swift.min(255, Swift.max(0, (a + (b - a) * f) * 255))) }
            lut[i * 4] = mix(lo.1.0, hi.1.0)
            lut[i * 4 + 1] = mix(lo.1.1, hi.1.1)
            lut[i * 4 + 2] = mix(lo.1.2, hi.1.2)
            lut[i * 4 + 3] = 255
        }
        return Palette(id: id, name: name, lut: lut)
    }

    static let all: [Palette] = [
        build("iron", "Iron", [
            (0.00, (0, 0, 0)), (0.20, (0.15, 0.00, 0.35)), (0.40, (0.55, 0.05, 0.55)),
            (0.60, (0.90, 0.25, 0.20)), (0.80, (1.00, 0.65, 0.00)), (1.00, (1.00, 1.00, 0.85)),
        ]),
        build("rainbow", "Rainbow", [
            (0.00, (0, 0, 0)), (0.15, (0.0, 0.0, 0.6)), (0.35, (0.0, 0.6, 0.9)),
            (0.55, (0.0, 0.8, 0.2)), (0.75, (1.0, 0.9, 0.0)), (0.9, (1.0, 0.4, 0.0)), (1.00, (1.0, 1.0, 1.0)),
        ]),
        build("white", "White hot", [(0.0, (0, 0, 0)), (1.0, (1, 1, 1))]),
        build("black", "Black hot", [(0.0, (1, 1, 1)), (1.0, (0, 0, 0))]),
        build("lava", "Lava", [
            (0.0, (0, 0, 0)), (0.3, (0.4, 0.0, 0.0)), (0.6, (0.9, 0.3, 0.0)),
            (0.85, (1.0, 0.8, 0.1)), (1.0, (1.0, 1.0, 0.9)),
        ]),
        build("arctic", "Arctic", [
            (0.0, (0, 0, 0.1)), (0.4, (0.0, 0.3, 0.6)), (0.7, (0.2, 0.7, 0.9)),
            (0.9, (0.8, 0.95, 1.0)), (1.0, (1, 1, 1)),
        ]),
        build("medical", "Medical", [
            (0.0, (0, 0, 0)), (0.25, (0.2, 0.0, 0.5)), (0.5, (0.8, 0.0, 0.5)),
            (0.7, (1.0, 0.3, 0.2)), (0.85, (1.0, 0.8, 0.2)), (1.0, (1, 1, 1)),
        ]),
    ]
}
