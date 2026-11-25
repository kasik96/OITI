import CoreVideo
import Foundation

/// Extracts the thermal half (lower 192 rows) from the camera's 256x384 UVC frame.
/// The camera labels it YUY2, but each YUY2 pixel of the lower half is really a 16-bit value: Y = low byte, chroma = high byte.
enum FrameDecoder {
    /// Formats that keep the bytes intact, best first. 420f is left out on purpose: converting rescales the luma byte.
    static let preferredFormats: [OSType] = [
        kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ]

    static func decode(_ pb: CVPixelBuffer) -> ThermalFrame? {
        guard CVPixelBufferGetWidth(pb) == ThermalFrame.width, CVPixelBufferGetHeight(pb) == ThermalFrame.height * 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_422YpCbCr8_yuvs: return packed(pb, lowByteFirst: true)
        case kCVPixelFormatType_422YpCbCr8: return packed(pb, lowByteFirst: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return biplanar(pb)
        default: return nil
        }
    }

    private static func packed(_ pb: CVPixelBuffer, lowByteFirst: Bool) -> ThermalFrame? {
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt16](repeating: 0, count: ThermalFrame.count)
        for y in 0..<ThermalFrame.height {
            let row = base.advanced(by: (y + ThermalFrame.height) * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<ThermalFrame.width {
                let a = UInt16(row[x * 2]), b = UInt16(row[x * 2 + 1])
                out[y * ThermalFrame.width + x] = lowByteFirst ? a | b << 8 : b | a << 8
            }
        }
        return ThermalFrame(raw: out)
    }

    /// iOS hands apps 4:2:0 (NV12-style): plane 0 = luma = the low byte at full resolution; plane 1 = CbCr
    /// interleaved, carrying the high byte per luma column but vertically averaged over each 2-row pair.
    /// (Verified against a real iPad frame, 2026-11-25: format '420v', chroma 128x192 interleaved.)
    ///
    /// The low byte (fine temperature) is always exact — so all sub-4°C detail is lossless. Only the high byte
    /// (coarse, 4°C steps) loses vertical resolution, which shows as salt-and-pepper dots where a scene straddles
    /// a 4°C boundary. `cleanupDots` removes those without chaining (no streaks). Detail enhancement in the
    /// renderer then brings out the preserved low-byte structure.
    private static func biplanar(_ pb: CVPixelBuffer) -> ThermalFrame? {
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let w = ThermalFrame.width, h = ThermalFrame.height
        var raw = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            let lrow = (y + h) * ys, crow = (y / 2 + h / 2) * cs
            for x in 0..<w { raw[y * w + x] = UInt16(yBase[lrow + x]) | UInt16(cBase[crow + x]) << 8 }
        }
        // Dot cleanup is applied later (toggleable) by the camera pipeline, so this stays the raw naive frame.
        return ThermalFrame(raw: raw)
    }

    /// Removes isolated/clustered high-byte dots by snapping any pixel that is a ~256-count (4°C) outlier from its
    /// 3x3 median to the locally-consistent high byte, keeping its exact low byte. No chaining, so no streaks.
    /// (A truly single-pixel >4°C feature is indistinguishable from a dot and will be damped — the renderer's
    /// detail enhancement recovers fine structure from the untouched low byte instead.)
    static func cleanupDots(_ input: [UInt16], passes: Int = 1) -> [UInt16] {
        let w = ThermalFrame.width, h = ThermalFrame.height
        var raw = input
        var nb = [Int](repeating: 0, count: 9)
        for _ in 0..<passes {
            let src = raw
            for y in 0..<h {
                for x in 0..<w {
                    let v = Int(src[y * w + x])
                    var n = 0
                    for dy in -1...1 {
                        let yy = y + dy; if yy < 0 || yy >= h { continue }
                        for dx in -1...1 {
                            let xx = x + dx; if xx < 0 || xx >= w { continue }
                            nb[n] = Int(src[yy * w + xx]); n += 1
                        }
                    }
                    for i in 1..<n { let key = nb[i]; var j = i - 1; while j >= 0 && nb[j] > key { nb[j + 1] = nb[j]; j -= 1 }; nb[j + 1] = key }
                    let med = nb[n / 2], diff = abs(v - med)
                    if diff > 180 && diff < 340 {
                        let low = v & 0xFF
                        raw[y * w + x] = UInt16(clamping: (Int((Double(med - low) / 256).rounded()) << 8) | low)
                    }
                }
            }
        }
        return raw
    }
}
