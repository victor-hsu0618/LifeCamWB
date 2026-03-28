# LifeCamWB

A macOS app for controlling the Microsoft LifeCam Studio webcam's image settings (white balance, exposure, brightness, contrast, saturation, sharpness, backlight compensation, focus, and power line frequency) via CoreMediaIO.

Settings are automatically saved and restored every time you connect the camera — no need to reconfigure after each plug-in.

## Hardware

**Microsoft LifeCam Studio** (USB 2.0, UVC-compliant)

| Spec | Value |
|---|---|
| Sensor | 1/3" CMOS |
| Max Resolution | 1080p (1920×1080) @ 30 fps |
| Interface | USB 2.0 (UVC) |
| Focus | Autofocus (motorised) |
| Field of View | 75° |
| Lens | Fixed aperture (f/2.0) |

## Requirements

- macOS 13 or later
- Microsoft LifeCam Studio (USB)
- Camera permission granted to the app

## Build & Run

```bash
# Build the SwiftUI app
./build.sh
open LifeCamWB.app

# Build the CLI diagnostic tool
make
./lifecam_wb dump   # list all CMIO controls
./lifecam_wb get    # read current WB temperature
./lifecam_wb set 5500
./lifecam_wb auto 1
```

## Usage

1. Plug in the LifeCam Studio via USB
2. Launch `LifeCamWB.app`
3. The app requests camera permission on first launch — click **Allow**
4. The live preview starts automatically; controls appear in the right panel
5. Click **Connect** if the CMIO controls panel shows "Not connected"
6. Adjust any slider or toggle — settings are saved automatically
7. Next time you open the app, all settings are restored on connect

**White Balance presets** (Candle → Shade) are quick shortcuts to common colour temperatures. Selecting a preset disables Auto WB and writes the value immediately.

## Supported Controls

Controls are discovered dynamically at connect time — only what the camera firmware exposes will appear.

| Control | Range | Auto Mode | Notes |
|---|---|---|---|
| White Balance Temperature | 2500–10000 K | Yes (works) | NativeData uint16 LE via `ucwt` class |
| Exposure | 1–10000 | Yes (works) | Written via `ucea` (UVC Exposure Absolute) NativeData uint32 LE |
| Brightness | 30–255 | No | Written via `ucbt` NativeData byte; hardware clamps below 30 |
| Contrast | 0–10 | No (not functional) | CMIO AutoManual flag present but ignored by firmware |
| Saturation | 0–200 | No (not functional) | Same as above |
| Sharpness | 0–50 | No (not functional) | Same as above |
| Backlight Compensation | 0–10 | No (not functional) | Same as above |
| Focus | 0–40 | Yes (works via `ucfa`) | Auto toggle controls `ucfa` (UVC Focus Absolute) |
| Power Line Frequency | Off / 50 Hz / 60 Hz | — | Anti-flicker; set to match your local mains frequency |

### Auto Mode Details

Tested on hardware by writing an out-of-range value, re-enabling auto, and checking if the camera self-corrected:

| Control | Auto Result |
|---|---|
| White Balance | Works — camera self-corrects temperature |
| Exposure | Works — camera self-corrects to scene brightness |
| Brightness | Works — camera self-corrects |
| Focus | Works — camera autofocuses |
| Contrast | No effect — firmware ignores the AutoManual flag |
| Saturation | No effect — firmware ignores the AutoManual flag |
| Sharpness | No effect — firmware ignores the AutoManual flag |
| Backlight Comp | No effect — firmware ignores the AutoManual flag |

## Controls Not Available on LifeCam Studio

These are **not exposed by the camera firmware** and cannot be controlled regardless of software:

| Control | Reason |
|---|---|
| Gain | Not exposed by camera hardware |
| Hue | Not exposed by camera hardware |
| Gamma | Not exposed by camera hardware |
| Aperture | Fixed-aperture lens — not applicable |
| Zoom | CMIO control exists but firmware does not apply values to video output |

## Settings Persistence

All slider values and Auto toggle states are saved to `UserDefaults` automatically whenever you make a change. On the next connect, they are restored silently. This means:

- **Volatile by hardware**: The LifeCam resets all settings to default when USB power is lost (unplug, reboot). Settings stored in the camera itself are not supported.
- **Persistent via this app**: LifeCamWB re-applies your last saved settings every time it connects.
- **First launch**: No saved settings exist yet — the camera starts in its hardware default state (Auto WB, Auto Exposure, Auto Focus).

## Architecture

```
Sources/LifeCamWB/
├── LifeCamWBApp.swift     — @main SwiftUI entry point
├── ContentView.swift      — Main UI layout
├── UVCController.swift    — CMIO device/control discovery, read/write, and settings persistence
├── CameraManager.swift    — AVCaptureSession, device picker, session lifecycle
└── CameraPreview.swift    — NSViewRepresentable wrapping AVCaptureVideoPreviewLayer
```

### Why CoreMediaIO, not IOKit?

On macOS 12+, the `UVCAssistant` daemon (pid ~310) holds exclusive ownership of the USB VideoControl interface. Direct IOKit USB access returns `kIOReturnExclusiveAccess`. CoreMediaIO routes requests through `UVCAssistant` as the intended channel.

### Why NativeData for white balance?

The LifeCam Studio exposes WB temperature under CMIO class `ucwt` (not the standard `temp` class). It uses the `NativeData` property (2-byte little-endian uint16, Kelvin), not `NativeValue` (Float32). The standard `temp` control on the device reports NativeValue=0 with range [0,0] and is non-functional.

The same pattern applies to Exposure (`ucea`, 4-byte uint32 LE), Brightness (`ucbt`, 1-byte), Focus (`ucfa`, 2-byte uint16 LE). Writing to the standard CMIO NativeValue property is accepted but silently ignored by the LifeCam firmware.

### Camera Session

`AVCaptureSession.startRunning()` is called on a dedicated serial `DispatchQueue` (not the main thread and not Swift's cooperative thread pool), as required by AVFoundation. Session interruptions (camera unplug/replug) are handled via `AVCaptureSessionInterruptionEnded` and `AVCaptureSessionRuntimeError` notifications to automatically restart the session.
