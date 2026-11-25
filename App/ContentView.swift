import SwiftUI

struct ContentView: View {
    @EnvironmentObject var camera: ThermalCamera
    @State private var showSettings = false
    @State private var savedURLs: [URL] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            imageArea                              // fills the safe area (stays clear of the status bar / notch)
            controls.background(.black.opacity(0.45))  // controls float over the bottom of the image
        }
    }

    // MARK: Live image + measurement overlay

    private var imageArea: some View {
        GeometryReader { geo in
            let aspect = CGFloat(camera.transform.displaySize.w) / CGFloat(camera.transform.displaySize.h)
            let rect = fitted(container: geo.size, aspect: aspect)
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = camera.image {
                    Image(decorative: img, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    markers(in: rect)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(camera.status).foregroundStyle(.white.opacity(0.8)).font(.callout)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                if camera.warming && camera.image != nil {
                    Text("Calibrating…").font(.caption).padding(6)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                        .position(x: rect.midX, y: rect.minY + 20)
                }
                scaleBar(rect: rect)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                guard rect.contains(v.location) else { return }
                let u = CGPoint(x: (v.location.x - rect.minX) / rect.width, y: (v.location.y - rect.minY) / rect.height)
                camera.spots.append(u)
            })
        }
    }

    private func markers(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            marker(at: unit(for: camera.stats.maxIndex), in: rect, color: .red, label: temp(camera.stats.max), symbol: "triangle.fill")
            marker(at: unit(for: camera.stats.minIndex), in: rect, color: .cyan, label: temp(camera.stats.min), symbol: "triangle")
            marker(at: CGPoint(x: 0.5, y: 0.5), in: rect, color: .white, label: temp(camera.stats.center), symbol: "plus")
            ForEach(Array(camera.spots.enumerated()), id: \.offset) { _, u in
                marker(at: u, in: rect, color: .yellow, label: spotTemp(u), symbol: "circle")
            }
        }
    }

    private func marker(at u: CGPoint, in rect: CGRect, color: Color, label: String, symbol: String) -> some View {
        let p = CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
        return VStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        }
        .foregroundStyle(color)
        .shadow(radius: 1)
        .position(x: p.x, y: p.y)
    }

    private func scaleBar(rect: CGRect) -> some View {
        let lut = camera.palettes[min(camera.paletteIndex, camera.palettes.count - 1)].lut
        return VStack(alignment: .trailing, spacing: 2) {
            Text(temp(camera.rangeC.hi)).font(.caption2).foregroundStyle(.white)
            LinearGradient(colors: gradientColors(lut), startPoint: .top, endPoint: .bottom)
                .frame(width: 14, height: 120).clipShape(RoundedRectangle(cornerRadius: 3))
            Text(temp(camera.rangeC.lo)).font(.caption2).foregroundStyle(.white)
        }
        .padding(8)
        .position(x: rect.maxX - 28, y: rect.midY)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                readout("MIN", camera.stats.min, .cyan)
                readout("CENTER", camera.stats.center, .white)
                readout("MAX", camera.stats.max, .red)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(camera.palettes.enumerated()), id: \.offset) { i, p in
                        let selected = i == camera.paletteIndex
                        Button { camera.paletteIndex = i } label: {
                            VStack(spacing: 3) {
                                LinearGradient(colors: gradientColors(p.lut), startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 54, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(p.name).font(.system(size: 9, weight: selected ? .bold : .regular))
                            }
                            .padding(4)
                            .background(selected ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 4)
            }
            HStack(spacing: 12) {
                Button { camera.enhanced.toggle() } label: {
                    label(camera.enhanced ? "wand.and.stars" : "thermometer.medium", camera.enhanced ? "Enhanced" : "Linear")
                }.tint(camera.enhanced ? .green : .orange)
                Button { camera.cycleRotation() } label: {
                    camera.isRotationLocked
                        ? label("lock.rotation", "\(camera.rotationLock ?? 0)°")
                        : label("rotate.right", "Auto")
                }.tint(camera.isRotationLocked ? .yellow : .white)
                Button { camera.mirror.toggle() } label: { label("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip") }
                Button { camera.spots.removeAll() } label: { label("xmark.circle", "Clear") }.disabled(camera.spots.isEmpty)
                Button { showSettings = true } label: { label("slider.horizontal.3", "Tune") }
                Button { savedURLs = ImageExport.save(image: camera.image ?? blank(), frame: camera.latest, correction: EmissivityCorrection(emissivity: camera.emissivity, reflected: camera.reflected)) } label: {
                    label("camera.aperture", "Save")
                }.disabled(camera.image == nil)
                if let png = savedURLs.first(where: { $0.pathExtension == "png" }) {
                    ShareLink(item: png) { label("square.and.arrow.up", "Share") }
                }
            }
            .buttonStyle(.bordered).tint(.white)
            if !savedURLs.isEmpty {
                Text("Saved \(savedURLs.count) file(s) to Documents").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.black)
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Emissivity") {
                    HStack { Text("ε \(camera.emissivity, specifier: "%.2f")"); Slider(value: $camera.emissivity, in: 0.50...1.00, step: 0.01) }
                    HStack { Text("Reflected \(camera.reflected, specifier: "%.0f")°C"); Slider(value: $camera.reflected, in: -20...120, step: 1) }
                    Text("Common ε: skin 0.98, matte paint 0.95, wood 0.9, brick 0.93, shiny metal 0.1–0.3.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Contrast (AGC)") {
                    HStack { Text("Detail \(camera.detail, specifier: "%.1f")"); Slider(value: $camera.detail, in: 0...1, step: 0.1) }
                    Text("Histogram equalization — allocates contrast where the data is, so subtle structure (heating lines, texture) stands out. 0 = linear (color ∝ temperature), 1 = maximum detail.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Smoothing \(camera.smoothing, specifier: "%.1f")"); Slider(value: $camera.smoothing, in: 0...1, step: 0.1) }
                    Text("Temporal noise reduction — averages consecutive frames to cut graininess and flicker. Higher is cleaner but ghosts on fast motion. 0 = live.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Temperature range") {
                    Toggle("Auto range", isOn: $camera.autoRange)
                    if !camera.autoRange {
                        HStack { Text("Min \(camera.manualMinC, specifier: "%.0f")°C"); Slider(value: $camera.manualMinC, in: -20...150, step: 1) }
                        HStack { Text("Max \(camera.manualMaxC, specifier: "%.0f")°C"); Slider(value: $camera.manualMaxC, in: -20...550, step: 1) }
                    }
                }
                Section {
                    Text("This USB-C camera streams at emissivity 1.0; correction is applied here. Shutter (NUC) is automatic. Gain is fixed at the camera's power-on setting (≈ −10…150 °C).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) { camera.resetDefaults() } label: {
                        Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Tune")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    // MARK: Helpers

    private func readout(_ title: String, _ c: Float, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text(temp(c)).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).labelStyle(.titleAndIcon)
    }

    private func temp(_ c: Float) -> String { String(format: "%.1f°", c) }

    private func unit(for index: Int) -> CGPoint {
        camera.transform.unit(x: index % ThermalFrame.width, y: index / ThermalFrame.width)
    }

    private func spotTemp(_ u: CGPoint) -> String {
        guard let f = camera.latest else { return "–" }
        let p = camera.transform.pixel(ux: u.x, uy: u.y)
        let raw = f.raw[p.y * ThermalFrame.width + p.x]
        return temp(EmissivityCorrection(emissivity: camera.emissivity, reflected: camera.reflected).apply(ThermalFrame.celsius(raw: raw)))
    }

    private func gradientColors(_ lut: [UInt8]) -> [Color] {
        stride(from: 0, to: 256, by: 32).reversed().map { i in
            Color(.sRGB, red: Double(lut[i * 4]) / 255, green: Double(lut[i * 4 + 1]) / 255, blue: Double(lut[i * 4 + 2]) / 255)
        }
    }

    private func fitted(container: CGSize, aspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        var size = container
        if container.width / container.height > aspect { size.width = container.height * aspect }
        else { size.height = container.width / aspect }
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func blank() -> CGImage {
        ThermalRenderer.cgImage(ThermalFrame(raw: .init(repeating: 0, count: ThermalFrame.count)),
                                lut: camera.palettes[0].lut, loRaw: 0, hiRaw: 1)!
    }
}
