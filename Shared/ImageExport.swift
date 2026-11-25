import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageExport {
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Per-pixel temperatures in °C (emissivity-corrected), 256 columns x 192 rows.
    static func csv(_ frame: ThermalFrame, _ correction: EmissivityCorrection) -> Data {
        var s = ""
        s.reserveCapacity(ThermalFrame.count * 6)
        for y in 0..<ThermalFrame.height {
            for x in 0..<ThermalFrame.width {
                if x > 0 { s += "," }
                s += String(format: "%.2f", correction.apply(ThermalFrame.celsius(raw: frame.raw[y * ThermalFrame.width + x])))
            }
            s += "\n"
        }
        return Data(s.utf8)
    }

    /// Writes a PNG and a CSV into a dated folder in the app's Documents directory. Returns the written files.
    @discardableResult
    static func save(image: CGImage, frame: ThermalFrame?, correction: EmissivityCorrection) -> [URL] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var urls: [URL] = []
        if let png = pngData(image) {
            let u = docs.appendingPathComponent("OITI-\(stamp).png")
            if (try? png.write(to: u)) != nil { urls.append(u) }
        }
        if let frame {
            let u = docs.appendingPathComponent("OITI-\(stamp).csv")
            if (try? csv(frame, correction).write(to: u)) != nil { urls.append(u) }
        }
        return urls
    }
}
