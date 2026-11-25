import Foundation

/// One radiometric frame: 256x192 little-endian values, Kelvin * 64.
struct ThermalFrame: Equatable {
    static let width = 256
    static let height = 192
    static let count = width * height
    static let byteCount = count * 2

    var raw: [UInt16]

    static func celsius(raw: UInt16) -> Float { Float(raw) / 64 - 273.15 }
    static func raw(celsius: Float) -> UInt16 { UInt16(max(0, min(65535, ((celsius + 273.15) * 64).rounded()))) }

    /// The camera sends constant filler (0, then 0x8000) for about 4 s after the stream starts.
    var isWarmup: Bool {
        guard let first = raw.first else { return true }
        return !raw.contains { $0 != first }
    }

    init(raw: [UInt16]) { precondition(raw.count == Self.count); self.raw = raw }

    init?(littleEndian data: Data) {
        guard data.count == Self.byteCount else { return nil }
        raw = data.withUnsafeBytes { b in (0..<Self.count).map { UInt16(littleEndian: b.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) } }
    }

    var littleEndianData: Data { raw.map(\.littleEndian).withUnsafeBytes { Data($0) } }
}

struct ThermalStats: Equatable {
    var min: Float = 0, max: Float = 0, mean: Float = 0, center: Float = 0
    var minIndex = 0, maxIndex = 0
}

extension ThermalFrame {
    func stats(_ correct: (Float) -> Float = { $0 }) -> ThermalStats {
        var lo = UInt16.max, hi = UInt16.min, li = 0, hi_i = 0, sum = 0
        for i in 0..<raw.count { let v = raw[i]; sum += Int(v); if v < lo { lo = v; li = i }; if v > hi { hi = v; hi_i = i } }
        let cy = Self.height / 2, cx = Self.width / 2
        let c = (Int(raw[(cy - 1) * Self.width + cx - 1]) + Int(raw[(cy - 1) * Self.width + cx]) + Int(raw[cy * Self.width + cx - 1]) + Int(raw[cy * Self.width + cx])) / 4
        return ThermalStats(min: correct(Self.celsius(raw: lo)), max: correct(Self.celsius(raw: hi)),
                            mean: correct(Float(sum) / Float(raw.count) / 64 - 273.15), center: correct(Self.celsius(raw: UInt16(c))),
                            minIndex: li, maxIndex: hi_i)
    }
}

/// The camera is left at emissivity 1.0; correction happens in the app so it works over any source.
struct EmissivityCorrection: Equatable {
    var emissivity: Float = 0.95
    var reflected: Float = 20

    func apply(_ celsius: Float) -> Float {
        guard emissivity < 0.999 else { return celsius }
        let t = powf(celsius + 273.15, 4), r = powf(reflected + 273.15, 4)
        return powf(max(1, (t - (1 - emissivity) * r) / emissivity), 0.25) - 273.15
    }
}
