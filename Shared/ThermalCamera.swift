import AVFoundation
import Combine
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Snapshot of render settings shared from the main actor to the capture queue.
private struct RenderConfig {
    var lut: [UInt8] = Palette.all[0].lut
    var emissivity = EmissivityCorrection()
    var autoRange = true
    var manualMinC: Float = 15
    var manualMaxC: Float = 45
    var transform = DisplayTransform()
    var detail: Float = 0.5
    var temporalA: Float = 0.5  // fraction of the new frame blended in; <1 averages over time to cut noise/flicker
    var cleanup = true          // remove 4:2:0 high-byte dots
}

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cfg = RenderConfig()
    var value: RenderConfig {
        get { lock.lock(); defer { lock.unlock() }; return cfg }
        set { lock.lock(); cfg = newValue; lock.unlock() }
    }
}

/// The result of processing one frame, handed back to the main actor.
struct RenderedFrame {
    var image: CGImage
    var stats: ThermalStats
    var loC: Float
    var hiC: Float
}

@MainActor
final class ThermalCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var image: CGImage?
    @Published var stats = ThermalStats()
    @Published var rangeC: (lo: Float, hi: Float) = (15, 45)
    @Published var connected = false
    @Published var warming = false
    @Published var status = "Searching for camera…"
    @Published var formatInfo = ""
    @Published private(set) var latest: ThermalFrame?

    // User settings.
    @Published var paletteIndex = 0 { didSet { pushConfig() } }
    @Published var emissivity: Float = 0.95 { didSet { pushConfig() } }
    @Published var reflected: Float = 20 { didSet { pushConfig() } }
    @Published var autoRange = true { didSet { pushConfig() } }
    @Published var manualMinC: Float = 15 { didSet { pushConfig() } }
    @Published var manualMaxC: Float = 45 { didSet { pushConfig() } }
    /// nil = auto (image follows the device orientation); otherwise a locked angle 0/90/180/270.
    @Published var rotationLock: Int? = nil { didSet { pushConfig() } }
    @Published private(set) var deviceRotation = 0
    @Published private(set) var orientationDebug = "—"
    @Published var mirror = false { didSet { pushConfig() } }
    /// Fixed sensor mounting offset. iOS already rotates the whole UI upright per device orientation, so in auto
    /// mode we only need this constant to correct how the camera module is mounted relative to the iPad.
    @Published var autoBase = 90 { didSet { pushConfig() } }
    var effectiveRotation: Int { rotationLock ?? ((deviceRotation + autoBase) % 360) }
    var isRotationLocked: Bool { rotationLock != nil }
    /// Advance the rotate button: auto → 0 → 90 → 180 → 270 → auto.
    func cycleRotation() {
        switch rotationLock {
        case nil: rotationLock = 0
        case 270: rotationLock = nil
        case let a?: rotationLock = a + 90
        }
    }
    @Published var detail: Float = 0.5 { didSet { pushConfig() } }
    @Published var smoothing: Float = 0.5 { didSet { pushConfig() } } // temporal noise reduction, 0 = live
    /// Master A/B switch: Enhanced = cleanup + AGC + temporal; Classic = raw linear look (for comparison).
    @Published var enhanced = true { didSet { pushConfig() } }

    /// Restore every user setting to its default.
    func resetDefaults() {
        paletteIndex = 0
        emissivity = 0.95; reflected = 20
        autoRange = true; manualMinC = 15; manualMaxC = 45
        detail = 0.5; smoothing = 0.5; enhanced = true
        rotationLock = nil; mirror = false
        spots = []
    }
    @Published var spots: [CGPoint] = [] // unit points in display space

    let palettes = Palette.all
    var transform: DisplayTransform { .init(rotation: effectiveRotation, mirror: mirror) }

    // AVCaptureSession start/stop is documented thread-safe; we drive it from the capture queue.
    private nonisolated(unsafe) let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "oiti.capture")
    private let config = ConfigBox()
    private var currentDeviceID: String?
    private nonisolated(unsafe) var accum: [Float]?  // temporal average, touched only on the capture queue

    override init() {
        super.init()
        pushConfig()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if !granted { self.status = "Camera access denied. Enable it in Settings."; return }
                self.observeConnections()
                self.observeOrientation()
                self.scan()
            }
        }
    }

    private func observeOrientation() {
        #if canImport(UIKit) && !os(macOS)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateDeviceRotation()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateDeviceRotation() }
        }
        #endif
    }

    private func updateDeviceRotation() {
        #if canImport(UIKit) && !os(macOS)
        // Use the interface orientation (what iOS actually rotated the UI to) so our image counter-rotation
        // agrees with the UI and never double-counts.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let r: Int
        switch scene?.interfaceOrientation ?? .portrait {
        case .portrait: r = 0; orientationDebug = "portrait"
        case .landscapeLeft: r = 90; orientationDebug = "landscapeLeft"
        case .portraitUpsideDown: r = 180; orientationDebug = "portraitUpsideDown"
        case .landscapeRight: r = 270; orientationDebug = "landscapeRight"
        default: orientationDebug = "unknown"; return
        }
        if r != deviceRotation { deviceRotation = r; if rotationLock == nil { pushConfig() } }
        #endif
    }

    private func observeConnections() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.handleDisconnect(n.object as? AVCaptureDevice) }
        }
    }

    private func externalDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }

    private func scan() {
        guard currentDeviceID == nil else { return }
        guard let device = externalDevices().first else {
            status = "Searching for camera…"; connected = false; return
        }
        configure(device)
    }

    private func handleDisconnect(_ device: AVCaptureDevice?) {
        guard device == nil || device?.uniqueID == currentDeviceID else { return }
        queue.async { self.session.stopRunning() }
        session.inputs.forEach { session.removeInput($0) }
        currentDeviceID = nil
        connected = false
        image = nil
        status = "Camera unplugged."
        scan()
    }

    private func configure(_ device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            guard session.canAddInput(input) else { throw CamError.cannotAdd }
            session.addInput(input)

            // Prefer the tall 256x384 format (image + radiometric half).
            let fmt = device.formats.first { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.width == Int32(ThermalFrame.width) && d.height == Int32(ThermalFrame.height * 2)
            }
            if let fmt {
                try device.lockForConfiguration()
                device.activeFormat = fmt
                device.unlockForConfiguration()
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            let available = output.availableVideoPixelFormatTypes
            let chosen = FrameDecoder.preferredFormats.first { available.contains($0) } ?? available.first
            if let chosen { output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen] }
            let dims = fmt.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            formatInfo = "in \(dims.map { "\($0.width)x\($0.height)" } ?? "?") · use \(fourCC(chosen)) · avail \(available.map(fourCC).joined(separator: ","))"
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CamError.cannotAdd }
            session.addOutput(output)
            session.commitConfiguration()

            currentDeviceID = device.uniqueID
            queue.async { self.accum = nil }  // reset temporal average for the new stream
            connected = true
            warming = true
            status = "Starting \(device.localizedName)…"
            queue.async { self.session.startRunning() }
        } catch {
            status = "Could not open camera: \(error.localizedDescription)"
            connected = false
        }
    }

    private enum CamError: Error { case cannotAdd }

    private func pushConfig() {
        config.value = RenderConfig(
            lut: palettes[min(paletteIndex, palettes.count - 1)].lut,
            emissivity: EmissivityCorrection(emissivity: emissivity, reflected: reflected),
            autoRange: autoRange, manualMinC: manualMinC, manualMaxC: manualMaxC,
            transform: DisplayTransform(rotation: effectiveRotation, mirror: mirror),
            // Cleanup + temporal always run, so the measured temperatures are the same stable data in both modes.
            // The toggle only changes the display: Enhanced = AGC contrast, Classic = linear (color ∝ temperature).
            detail: enhanced ? detail : 0,
            temporalA: 1 - 0.8 * smoothing,
            cleanup: true)
    }

    // MARK: Capture (runs on `queue`)

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let decoded = FrameDecoder.decode(pb) else { return }
        if decoded.isWarmup { Task { @MainActor in self.warming = true }; return }

        let cfg = config.value
        let clean = cfg.cleanup ? ThermalFrame(raw: FrameDecoder.cleanupDots(decoded.raw, passes: 1)) : decoded

        // Temporal averaging: random sensor noise and near-boundary flicker cancel across frames while the
        // stable image stays sharp. accum is an exponential moving average in raw counts (capture queue only).
        let frame: ThermalFrame
        if cfg.temporalA < 0.999 {
            let a = cfg.temporalA, count = clean.raw.count
            if accum?.count != count { accum = clean.raw.map { Float($0) } }
            accum!.withUnsafeMutableBufferPointer { acc in
                clean.raw.withUnsafeBufferPointer { src in
                    for i in 0..<count { acc[i] += a * (Float(src[i]) - acc[i]) }
                }
            }
            frame = ThermalFrame(raw: accum!.map { UInt16(clamping: Int($0.rounded())) })
        } else {
            accum = nil
            frame = clean
        }

        let stats = frame.stats(cfg.emissivity.apply)
        let range: (lo: Float, hi: Float)
        if cfg.autoRange {
            let r = ThermalRenderer.autoRange(frame)
            range = (r.lo, r.hi)
        } else {
            range = (ThermalFrame.raw(celsius: cfg.manualMinC).toFloat, ThermalFrame.raw(celsius: cfg.manualMaxC).toFloat)
        }
        guard let img = ThermalRenderer.cgImage(frame, lut: cfg.lut, loRaw: range.lo, hiRaw: range.hi,
                                                transform: cfg.transform, detail: cfg.detail) else { return }
        let loC = ThermalFrame.celsius(raw: UInt16(clamping: Int(range.lo)))
        let hiC = ThermalFrame.celsius(raw: UInt16(clamping: Int(range.hi)))
        Task { @MainActor in
            self.warming = false
            self.image = img
            self.stats = stats
            self.rangeC = (loC, hiC)
            self.latest = frame
        }
    }
}

private extension UInt16 { var toFloat: Float { Float(self) } }

/// Writes the first real pixel buffer to Documents/oiti-rawdump.bin once, so the true device byte layout
/// can be analysed and an exact decoder written. Self-describing header, little-endian.

/// Human-readable FourCC for a CoreVideo pixel format (e.g. 'yuvs', '420v', 'BGRA').
func fourCC(_ code: OSType?) -> String {
    guard let c = code, c != 0 else { return "—" }
    let bytes = [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "\(c)"
    return s.trimmingCharacters(in: .whitespaces)
}
