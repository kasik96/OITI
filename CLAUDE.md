# CLAUDE.md — Open Infrared Thermal Imager (OITI)

Context and hard-won findings for anyone (incl. Claude) working on this repo. Read before changing the
capture/decode pipeline or the App Store setup.

## What this is
A SwiftUI thermal-camera app for **USB-C iPad** that drives an InfiRay/Tiny1C-class **256×192 USB-C UVC**
thermal camera (the "Infrared Thermal Imager" / DYT family; shows as VID `0x3034` PID `0x5840`, aka
`0bda:5840`). Built after proving iPhone cannot use this camera at all.

## Core findings (do not re-learn the hard way)
- **iPhone cannot access USB UVC cameras, period** (verified on iOS 27): no UVC class driver, DriverKit
  doesn't load on iPhone, and raw IOKit `IOServiceOpen` on the USB device returns `kIOReturnNotPermitted`
  (0xe00002e2). The entitlement that would unlock it isn't issuable to an iOS app. No jailbreak for iOS 27.
  → **The app is iPad-only** (`TARGETED_DEVICE_FAMILY = 2`). A USB-C iPad enumerates the camera via
  `AVCaptureDevice` `.external`; macOS does too.
- **UVC format**: camera streams **256×384 YUY2**. Top 256×192 = visible/pseudocolor; **bottom 256×192 =
  radiometric**, each pixel a 16-bit value. `°C = raw_u16 / 64 − 273.15` (matches the vendor app; sanity-
  checked: skin reads ~34–35 °C). Emissivity correction is done in-app (camera left at ε≈1.0).
- **iPad gives 4:2:0 (`420v`), NOT lossless** like macOS (`yuvs`). The low byte (fine temp) survives at full
  res; the high byte (coarse, 4 °C steps) is vertically averaged per 2-row pair → salt-and-pepper "dots"
  where a scene straddles a 4 °C boundary. `FrameDecoder.cleanupDots` removes them (median on the high byte,
  keeping the exact low byte). Verified on a real device frame (`Tests/Fixtures/device-frame.bin`).
  Earlier experiments (vertical integration / vcol) caused vertical streaks — avoid; median cleanup wins.
- **Display**: Enhanced mode = histogram equalization (AGC) + temporal averaging (blend consecutive frames
  to kill noise/flicker). Linear mode = colour ∝ temperature. Toggle in UI; sliders in Tune. Measurements
  always read the cleaned+averaged frame so they're identical in both modes.
- **Rotation**: iOS rotates the UI with the device; the sensor has a fixed mounting offset, so
  `effectiveRotation = deviceRotation + 90` (interface-orientation based). Manual lock cycles 0/90/180/270.

## Build / test
Needs [XcodeGen]. The `.xcodeproj` is generated (gitignored); run `xcodegen` first.
```bash
xcodegen
xcodebuild -scheme OITITests -destination 'platform=macOS' test
# Device build:
xcodebuild -project OITI.xcodeproj -scheme OITI -configuration Release -destination "id=<UDID>" -allowProvisioningUpdates build
# App Store archive + export (ExportOptions.plist = app-store-connect, team 5DARBK48ZS):
xcodebuild -scheme OITI -configuration Release -destination 'generic/platform=iOS' -archivePath build/OITI.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/OITI.xcarchive -exportPath build/ipa -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates
```
- `Shared/` camera+decode+render+export · `App/` SwiftUI · `Tools/` renderproof · `Tests/` incl. real-frame regression.
- Dev team `5DARBK48ZS` (Martin Kase personal). Bundle `com.martinkase.oiti`. Marketing version 1.0, build 2 = iPad-only.
- `research/` is gitignored reverse-engineering scratch; `Tests/Fixtures/device-frame.bin` is the committed test frame.

## App Store (as of 2026-11-25)
- App Store Connect app ID **6839226290**, name **Open Infrared Thermal Imager**, **Free**, iPad-only, 4+,
  Utilities / Photo & Video, no data collected, China excluded.
- Privacy policy (public gist): https://gist.github.com/kasik96/bd83040a46c59674f4c62f2b8b339c0e
- Listing copy + screenshots: `docs/app-store/` (screenshots are iPad 13", 2048×2732, generated from real frames).
- Review note explains the hardware dependency; a demo video of the app running with the camera is required
  by App Review (hardware the reviewer lacks).
- **Git/GitHub**: repo https://github.com/kasik96/OITI . Commits carry NO "Co-Authored-By" line.

## Not done / watch out
- App Review will likely need the demo video and may still question the external-hardware requirement.
- iPad-only is deliberate; do not re-add iPhone (`1,2`) — the app genuinely does nothing on iPhone.
