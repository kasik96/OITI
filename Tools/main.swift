import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders real captured camera frames through the app's decode + palette pipeline into a montage PNG,
// so the image and temperatures can be eyeballed without a camera attached.
// Usage: renderproof <raw-256x384-yuy2-dump> <out.png>

let args = CommandLine.arguments
guard args.count >= 3, let data = FileManager.default.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("usage: renderproof <raw.bin> <out.png>\n".utf8)); exit(1)
}
let fullFrame = ThermalFrame.width * (ThermalFrame.height * 2) * 2   // 256x384 YUY2 bytes
let halfOffset = fullFrame / 2
let frameCount = data.count / fullFrame
print("frames in file: \(frameCount)")

let frameIndices = [120, 200, 230, 340].filter { $0 < frameCount }
let palettes = Palette.all
let tileW = ThermalFrame.width, tileH = ThermalFrame.height, gap = 6
let cols = palettes.count, rows = frameIndices.count
let W = cols * tileW + (cols + 1) * gap, H = rows * tileH + (rows + 1) * gap

guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

for (r, fi) in frameIndices.enumerated() {
    let start = fi * fullFrame + halfOffset
    guard let frame = ThermalFrame(littleEndian: data.subdata(in: start..<(start + ThermalFrame.byteCount))) else { continue }
    let s = frame.stats()
    print(String(format: "frame %d: min %.1f  center %.1f  max %.1f  (warmup=%@)", fi, s.min, s.center, s.max, frame.isWarmup ? "yes" : "no"))
    let range = ThermalRenderer.autoRange(frame)
    for (c, p) in palettes.enumerated() {
        guard let img = ThermalRenderer.cgImage(frame, lut: p.lut, loRaw: range.lo, hiRaw: range.hi) else { continue }
        let x = gap + c * (tileW + gap)
        let y = H - (gap + (r + 1) * tileH + r * gap) // CG origin is bottom-left
        ctx.draw(img, in: CGRect(x: x, y: y, width: tileW, height: tileH))
    }
}

guard let out = ctx.makeImage() else { fatalError("img") }
let url = URL(fileURLWithPath: args[2])
if let d = ImageExport.pngData(out) { try? d.write(to: url); print("wrote \(url.path)") } else { fatalError("png encode") }
