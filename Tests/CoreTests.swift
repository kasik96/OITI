import XCTest

final class CoreTests: XCTestCase {
    func testTemperatureFormulaMatchesCamera() {
        // Real room reading captured 2026-11-25: raw 18684 -> 18.79 °C.
        XCTAssertEqual(ThermalFrame.celsius(raw: 18684), 18.7875, accuracy: 0.001)
        XCTAssertEqual(ThermalFrame.raw(celsius: 18.7875), 18684)
    }

    func testWarmupDetection() {
        XCTAssertTrue(ThermalFrame(raw: .init(repeating: 0x8000, count: ThermalFrame.count)).isWarmup)
        var r = [UInt16](repeating: 0x8000, count: ThermalFrame.count); r[7] = 1
        XCTAssertFalse(ThermalFrame(raw: r).isWarmup)
    }

    func testEmissivity() {
        XCTAssertEqual(EmissivityCorrection(emissivity: 1, reflected: 20).apply(50), 50, accuracy: 0.001)
        XCTAssertGreaterThan(EmissivityCorrection(emissivity: 0.9, reflected: 20).apply(50), 50)
        XCTAssertEqual(EmissivityCorrection(emissivity: 0.9, reflected: 20).apply(20), 20, accuracy: 0.01)
    }

    func testDisplayTransformRoundTripsAllOrientations() {
        let w = ThermalFrame.width, h = ThermalFrame.height
        for rot in [0, 90, 180, 270] {
            for mir in [false, true] {
                let t = DisplayTransform(rotation: rot, mirror: mir)
                for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (123, 77)] {
                    let u = t.unit(x: x, y: y)
                    let p = t.pixel(ux: u.x, uy: u.y)
                    XCTAssertEqual(p.x, x, "rot \(rot) mir \(mir)")
                    XCTAssertEqual(p.y, y, "rot \(rot) mir \(mir)")
                }
                let s = t.displaySize
                XCTAssertEqual(s.w * s.h, w * h)
            }
        }
    }

    func testRendererProducesCorrectlySizedImage() {
        let frame = ThermalFrame(raw: (0..<ThermalFrame.count).map { UInt16(truncatingIfNeeded: $0) })
        let img = ThermalRenderer.cgImage(frame, lut: Palette.all[0].lut, loRaw: 0, hiRaw: 65535)
        XCTAssertEqual(img?.width, ThermalFrame.width)
        XCTAssertEqual(img?.height, ThermalFrame.height)
        let rot = ThermalRenderer.cgImage(frame, lut: Palette.all[0].lut, loRaw: 0, hiRaw: 65535, transform: .init(rotation: 90))
        XCTAssertEqual(rot?.width, ThermalFrame.height)
        XCTAssertEqual(rot?.height, ThermalFrame.width)
    }

    func testPalettesAreMonotonicBrightness() {
        for p in Palette.all where p.id == "white" {
            XCTAssertLessThan(p.lut[0], p.lut[255 * 4]) // black hot -> white
        }
        XCTAssertEqual(Palette.all.count, 7)
        for p in Palette.all { XCTAssertEqual(p.lut.count, 256 * 4) }
    }

    // Count ~256-count (4°C) jumps between neighbours — the signature of high-byte decode errors (streaks/dots).
    private func artifactCount(_ raw: [UInt16]) -> Int {
        let w = ThermalFrame.width, h = ThermalFrame.height
        var n = 0
        for y in 0..<h {
            for x in 0..<w {
                let v = Int(raw[y * w + x])
                if x + 1 < w { let d = abs(v - Int(raw[y * w + x + 1])); if d > 180 && d < 340 { n += 1 } }
                if y + 1 < h { let d = abs(v - Int(raw[(y + 1) * w + x])); if d > 180 && d < 340 { n += 1 } }
            }
        }
        return n
    }

    /// The real iPad 4:2:0 frame (format 420v, captured 2026-11-25), decoded exactly as the app does
    /// (vertical integration). The raw naive frame is dotty; the decoded frame must be essentially artifact-free.
    func testRealDeviceFrameDecodesClean() throws {
        let candidates = [ProcessInfo.processInfo.environment["OITI_DUMP"],
                          Bundle(for: Self.self).path(forResource: "device-frame", ofType: "bin")].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let d = FileManager.default.contents(atPath: path),
              let planes = decodeDeviceDump(d) else { throw XCTSkip("device-frame.bin not available") }
        let before = artifactCount(planes.naive), after = artifactCount(FrameDecoder.cleanupDots(planes.naive))
        print("device frame artifacts: naive \(before) -> cleaned \(after)")
        XCTAssertGreaterThan(before, 1000)   // the raw frame really has the dot problem
        XCTAssertLessThan(after, 80)         // cleanup removes the clustered dots
    }

    /// Parses the app's OIR1 dump into the planes `biplanar` uses, plus the naive (pre-fix) reconstruction.
    private func decodeDeviceDump(_ d: Data) -> (low: [UInt8], chromaHalf: [UInt8], naive: [UInt16])? {
        let w = ThermalFrame.width, h = ThermalFrame.height
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        guard d.count > 20, Array(d.prefix(4)) == Array("OIR1".utf8), u32(16) == 2 else { return nil }
        var off = 20
        let lh = u32(off + 4), lbpr = u32(off + 8), lstart = off + 12
        off = lstart + lbpr * lh
        let cbpr = u32(off + 8), cstart = off + 12
        var low = [UInt8](repeating: 0, count: w * h)
        var chromaHalf = [UInt8](repeating: 0, count: w * (h / 2))
        var naive = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h { let r = lstart + (y + h) * lbpr; for x in 0..<w { low[y * w + x] = d[r + x] } }
        for cy in 0..<h / 2 { let r = cstart + (cy + h / 2) * cbpr; for x in 0..<w { chromaHalf[cy * w + x] = d[r + x] } }
        for y in 0..<h { for x in 0..<w { naive[y * w + x] = UInt16(low[y * w + x]) | UInt16(chromaHalf[(y / 2) * w + x]) << 8 } }
        return (low, chromaHalf, naive)
    }
}
