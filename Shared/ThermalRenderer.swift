import CoreGraphics
import Foundation

/// Maps between sensor pixels (256x192) and the displayed image, applying rotation and mirroring consistently
/// so the picture, the measurement markers, and taps all agree.
struct DisplayTransform: Equatable {
    var rotation = 0   // clockwise degrees, one of 0/90/180/270
    var mirror = false // horizontal flip in sensor space

    private let w = ThermalFrame.width, h = ThermalFrame.height

    /// Displayed image size after rotation.
    var displaySize: (w: Int, h: Int) { rotation % 180 == 0 ? (w, h) : (h, w) }

    /// Sensor pixel -> integer display pixel.
    func displayPixel(x: Int, y: Int) -> (x: Int, y: Int) {
        let sx = mirror ? w - 1 - x : x
        switch rotation {
        case 90: return (h - 1 - y, sx)
        case 180: return (w - 1 - sx, h - 1 - y)
        case 270: return (y, w - 1 - sx)
        default: return (sx, y)
        }
    }

    /// Sensor pixel -> unit point (0...1) in the displayed image, at the pixel centre.
    func unit(x: Int, y: Int) -> CGPoint {
        let d = displayPixel(x: x, y: y), s = displaySize
        return CGPoint(x: (Double(d.x) + 0.5) / Double(s.w), y: (Double(d.y) + 0.5) / Double(s.h))
    }

    /// Unit point in the displayed image -> sensor pixel.
    func pixel(ux: Double, uy: Double) -> (x: Int, y: Int) {
        let s = displaySize
        let dx = Int((ux * Double(s.w)).rounded(.down)), dy = Int((uy * Double(s.h)).rounded(.down))
        var sx: Int, sy: Int
        switch rotation {
        case 90: sx = dy; sy = h - 1 - dx
        case 180: sx = w - 1 - dx; sy = h - 1 - dy
        case 270: sx = w - 1 - dy; sy = dx
        default: sx = dx; sy = dy
        }
        if mirror { sx = w - 1 - sx }
        return (Swift.min(Swift.max(sx, 0), w - 1), Swift.min(Swift.max(sy, 0), h - 1))
    }
}

enum ThermalRenderer {
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Renders a frame to an RGBA image. Pixels are mapped linearly from [loRaw, hiRaw] through the palette.
    static func cgImage(_ frame: ThermalFrame, lut: [UInt8], loRaw: Float, hiRaw: Float,
                        transform: DisplayTransform = .init(), detail: Float = 0) -> CGImage? {
        let w = ThermalFrame.width, h = ThermalFrame.height
        let size = transform.displaySize
        let span = Swift.max(1, hiRaw - loRaw)
        // `detail` blends the linear temperature map with histogram equalization (AGC): rank-based contrast that
        // allocates palette levels where the data actually is, so subtle structure (heating lines, texture) pops.
        // detail 0 = pure linear (color ∝ temperature); detail 1 = full equalization (clearest).
        let cdf = detail > 0 ? equalizationCDF(frame.raw) : nil
        var px = [UInt8](repeating: 255, count: size.w * size.h * 4)
        frame.raw.withUnsafeBufferPointer { src in
            lut.withUnsafeBufferPointer { l in
                px.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        for x in 0..<w {
                            let v = Float(src[y * w + x])
                            var t = (v - loRaw) / span
                            if t < 0 { t = 0 }; if t > 1 { t = 1 }
                            if let cdf { t = (1 - detail) * t + detail * cdf.lookup(v) }
                            let li = Int(t * 255) * 4
                            let d = transform.displayPixel(x: x, y: y)
                            let o = (d.y * size.w + d.x) * 4
                            out[o] = l[li]; out[o + 1] = l[li + 1]; out[o + 2] = l[li + 2]; out[o + 3] = 255
                        }
                    }
                }
            }
        }
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: size.w, height: size.h, bitsPerComponent: 8,
                                      bytesPerRow: size.w * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Cumulative histogram over the frame's value range, for histogram-equalized (AGC) display mapping.
    struct CDF {
        let vmin: Float, vspan: Float
        let cdf: [Float] // 256 entries, 0...1
        func lookup(_ v: Float) -> Float {
            var b = Int((v - vmin) / vspan * 255)
            if b < 0 { b = 0 }; if b > 255 { b = 255 }
            return cdf[b]
        }
    }

    static func equalizationCDF(_ raw: [UInt16]) -> CDF {
        var lo = UInt16.max, hi = UInt16.min
        for v in raw { if v < lo { lo = v }; if v > hi { hi = v } }
        let vmin = Float(lo), vspan = Swift.max(1, Float(hi) - Float(lo))
        var hist = [Int](repeating: 0, count: 256)
        for v in raw {
            var b = Int((Float(v) - vmin) / vspan * 255)
            if b < 0 { b = 0 }; if b > 255 { b = 255 }
            hist[b] += 1
        }
        var cdf = [Float](repeating: 0, count: 256)
        let total = Float(raw.count)
        var acc = 0
        for i in 0..<256 { acc += hist[i]; cdf[i] = Float(acc) / total }
        return CDF(vmin: vmin, vspan: vspan, cdf: cdf)
    }

    /// Auto range: robust span from percentiles so a single hot/cold pixel doesn't wash out the scene.
    static func autoRange(_ frame: ThermalFrame) -> (lo: Float, hi: Float) {
        let sorted = frame.raw.sorted()
        let lo = Float(sorted[Int(Double(sorted.count) * 0.02)])
        let hi = Float(sorted[Int(Double(sorted.count) * 0.98)])
        return (lo, Swift.max(lo + 64, hi))
    }
}
