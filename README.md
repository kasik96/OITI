# Open Infrared Thermal Imager (OITI)

A SwiftUI thermal‑camera app for **USB‑C iPad** (and macOS) that drives an InfiRay/Tiny1C‑class
256×192 USB‑C UVC thermal camera (the "Infrared Thermal Imager" / DYT family, VID `0x3034` /
PID `0x5840`). Built because **iPhone cannot access USB UVC cameras at all** (no UVC class driver,
no DriverKit, no raw USB for apps — verified on iOS 27); a USB‑C iPad can, via AVFoundation.

## Features
- Live radiometric thermal view over USB‑C (AVFoundation external camera).
- Per‑pixel temperature: min / max / center / tap‑to‑add spot readouts.
- Emissivity + reflected‑temperature correction (applied in‑app).
- 7 palettes (Iron, Rainbow, White/Black hot, Lava, Arctic, Medical).
- **Enhanced** mode: histogram‑equalization (AGC) contrast + temporal denoise; **Linear** mode for
  strict colour‑proportional‑to‑temperature. Tunable detail/smoothing, with Reset to defaults.
- Auto‑rotation (follows the iPad) with a manual rotate‑lock + flip.
- Save PNG snapshot + per‑pixel CSV (temperatures in °C) to Files.

## How it works (the interesting part)
The camera is standard UVC and streams **256×384 YUY2**: the top 256×192 is the image, the bottom
256×192 is the radiometric half where each pixel is a 16‑bit value, `°C = raw/64 − 273.15`.

On macOS AVFoundation hands apps the lossless packed `yuvs` buffer. **On iPadOS it only offers
4:2:0 (`420v`)**: the low byte (fine temperature) survives at full resolution, but the high byte
(coarse, 4 °C steps) is vertically averaged over each 2‑row pair. Where a scene straddles a 4 °C
boundary this shows as salt‑and‑pepper dots. `FrameDecoder.cleanupDots` removes them (median snap on
the high byte only, keeping the exact low byte — so sub‑4 °C detail is never lost). Verified against a
real device frame in the test suite (`Tests/Fixtures/device-frame.bin`).

## Build
Requires [XcodeGen](https://github.com/yonyz/XcodeGen).

```bash
xcodegen
xcodebuild -scheme OITITests -destination 'platform=macOS' test   # unit tests
xcodebuild -scheme OITI -configuration Release -destination 'generic/platform=iOS' build
```

- `Shared/` — camera, decode, palettes, renderer, export (used by all targets).
- `App/` — SwiftUI app (iOS + macOS).
- `Tools/` — `renderproof`, renders a raw dump through the pipeline for inspection.
- `Tests/` — unit tests incl. a real‑device‑frame decode regression.

## Status
Personal project; sideloaded, not App Store. No affiliation with the camera manufacturer.
