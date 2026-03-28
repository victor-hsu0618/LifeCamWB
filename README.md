# LifeCamWB

**English** | [中文](#中文說明)

A macOS app for controlling the Microsoft LifeCam Studio webcam's image settings (white balance, exposure, brightness, contrast, saturation, sharpness, backlight compensation, focus, and power line frequency) via CoreMediaIO.

Settings are automatically saved and restored every time you connect the camera — no need to reconfigure after each plug-in.

---

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
- Xcode Command Line Tools (for building from source)

## Install

### Option 1: Homebrew (recommended)

```bash
brew tap victor-hsu0618/tap
brew install --cask lifecamwb
```

### Option 2: Manual Download

Go to [Releases](https://github.com/victor-hsu0618/LifeCamWB/releases) and download the latest `LifeCamWB-vX.X.zip`.

1. Unzip and move `LifeCamWB.app` to `/Applications`
2. **Right-click → Open** on first launch (ad-hoc signed, not notarized — macOS will warn)
3. Grant camera permission when prompted

> The pre-built binary is a Universal Binary (x86_64 + arm64), runs on both Intel and Apple Silicon Macs.

## Build from Source

```bash
# 1. Install Xcode Command Line Tools (if not already installed)
xcode-select --install

# 2. Clone the repository
git clone https://github.com/victor-hsu0618/LifeCamWB.git
cd LifeCamWB

# 3. Build the SwiftUI app (Universal Binary)
./build.sh
open LifeCamWB.app

# 4. (Optional) Build the CLI diagnostic tool
make
./lifecam_wb dump      # list all CMIO controls on connected camera
./lifecam_wb get       # read current WB temperature
./lifecam_wb set 5500
./lifecam_wb auto 1
```

The build script compiles for both `arm64` and `x86_64` and produces a Universal Binary.

## Usage

1. Plug in the LifeCam Studio via USB
2. Launch `LifeCamWB.app`
3. The app requests camera permission on first launch — click **Allow**
4. The live preview starts automatically; controls appear in the right panel
5. Click **Connect** if the CMIO controls panel shows "Not connected"
6. Adjust any slider or toggle — settings are saved automatically
7. Next time you open the app, all settings are restored on connect

**White Balance presets** (Candle → Shade) are quick shortcuts to common colour temperatures.

**Startup section** (bottom of control panel):
- *Launch at Login* — app starts automatically on boot
- *Minimize after connect* — window minimizes to Dock after applying settings (useful with Launch at Login)

## Supported Controls

| Control | Range | Auto Mode | Notes |
|---|---|---|---|
| White Balance Temperature | 2500–10000 K | Yes (works) | Written via `ucwt` NativeData uint16 LE |
| Exposure | 1–10000 | Yes (works) | Written via `ucea` NativeData uint32 LE |
| Brightness | 30–255 | No | Written via `ucbt` NativeData byte |
| Contrast | 0–10 | No (not functional) | AutoManual flag ignored by firmware |
| Saturation | 0–200 | No (not functional) | AutoManual flag ignored by firmware |
| Sharpness | 0–50 | No (not functional) | AutoManual flag ignored by firmware |
| Backlight Compensation | 0–10 | No (not functional) | AutoManual flag ignored by firmware |
| Focus | 0–40 | Yes (works via `ucfa`) | Auto toggle controls UVC Focus Absolute |
| Power Line Frequency | Off / 50 Hz / 60 Hz | — | Set to match your local mains frequency |

## Controls Not Available on LifeCam Studio

| Control | Reason |
|---|---|
| Gain | Not exposed by camera hardware |
| Hue | Not exposed by camera hardware |
| Gamma | Not exposed by camera hardware |
| Aperture | Fixed-aperture lens — not applicable |
| Zoom | CMIO control exists but firmware ignores writes |

## Settings Persistence

All slider values and Auto toggle states are saved to `UserDefaults` automatically. On the next connect, they are restored silently.

- **Volatile by hardware**: The LifeCam resets all settings when USB power is lost. Settings are not stored in the camera itself.
- **Persistent via this app**: LifeCamWB re-applies your last saved settings every time it connects.
- **First launch**: No saved settings yet — the camera starts in its hardware default state (Auto WB, Auto Exposure, Auto Focus).

## Architecture

```
Sources/LifeCamWB/
├── LifeCamWBApp.swift     — @main entry point, login-item registration, minimize-on-connect
├── ContentView.swift      — Main UI layout
├── UVCController.swift    — CMIO device/control discovery, read/write, settings persistence
├── CameraManager.swift    — AVCaptureSession lifecycle, device picker, session queue
└── CameraPreview.swift    — NSViewRepresentable wrapping AVCaptureVideoPreviewLayer
```

### Why CoreMediaIO, not IOKit?

On macOS 12+, the `UVCAssistant` daemon holds exclusive ownership of the USB VideoControl interface. Direct IOKit USB access returns `kIOReturnExclusiveAccess`. CoreMediaIO routes requests through `UVCAssistant` as the intended channel.

### Why NativeData instead of NativeValue?

The LifeCam firmware ignores standard CMIO `NativeValue` (Float32) writes. Actual control requires writing raw UVC bytes via `NativeData`:

| Control | CMIO Class | Format |
|---|---|---|
| White Balance | `ucwt` | 2-byte uint16 LE (Kelvin) |
| Exposure | `ucea` | 4-byte uint32 LE |
| Brightness | `ucbt` | 1 byte |
| Focus | `ucfa` | 2-byte uint16 LE |

---

## 中文說明

[English](#lifecamwb) | **中文**

這是一個 macOS app，透過 CoreMediaIO 控制 Microsoft LifeCam Studio USB 網路攝影機的影像設定（白平衡、曝光、亮度、對比、飽和度、銳利度、背光補償、對焦、電源線頻率）。

設定會在每次連上相機時自動儲存並還原，不需要每次插上相機都重新設定。

---

## 硬體規格

**Microsoft LifeCam Studio**（USB 2.0，UVC 標準相容）

| 規格 | 數值 |
|---|---|
| 感光元件 | 1/3" CMOS |
| 最高解析度 | 1080p（1920×1080）@ 30 fps |
| 介面 | USB 2.0（UVC） |
| 對焦 | 自動對焦（馬達驅動） |
| 視角 | 75° |
| 鏡頭 | 固定光圈（f/2.0） |

## 系統需求

- macOS 13 或更新版本
- Microsoft LifeCam Studio（USB）
- 允許 app 存取相機權限
- Xcode Command Line Tools（從原始碼 build 時需要）

## 安裝方式

### 方法一：Homebrew（建議）

```bash
brew tap victor-hsu0618/tap
brew install --cask lifecamwb
```

### 方法二：手動下載

前往 [Releases](https://github.com/victor-hsu0618/LifeCamWB/releases) 下載最新的 `LifeCamWB-vX.X.zip`。

1. 解壓縮，將 `LifeCamWB.app` 移到 `/Applications`
2. **第一次開啟請用右鍵 → 開啟**（非 Apple 公證版本，macOS 會跳出警告）
3. 允許相機存取權限

> 預編譯版本為 Universal Binary（x86_64 + arm64），Intel 和 Apple Silicon Mac 皆可執行。

## 從原始碼 Build

```bash
# 1. 安裝 Xcode Command Line Tools（尚未安裝的話）
xcode-select --install

# 2. 下載原始碼
git clone https://github.com/victor-hsu0618/LifeCamWB.git
cd LifeCamWB

# 3. 編譯 SwiftUI app（Universal Binary）
./build.sh
open LifeCamWB.app

# 4.（選用）編譯 CLI 診斷工具
make
./lifecam_wb dump      # 列出相機所有 CMIO 控制項
./lifecam_wb get       # 讀取目前白平衡色溫
./lifecam_wb set 5500  # 設定色溫為 5500K
./lifecam_wb auto 1    # 開啟自動白平衡
```

Build script 會同時編譯 `arm64` 和 `x86_64`，產生 Universal Binary。

## 使用方法

1. 將 LifeCam Studio 插上 USB
2. 開啟 `LifeCamWB.app`
3. 第一次啟動時，點選「允許」相機存取權限
4. 即時預覽畫面自動啟動，右側面板顯示各項控制
5. 若 CMIO 控制區顯示「Not connected」，點選 **Connect**
6. 調整任何 slider 或 Auto 開關，設定自動儲存
7. 下次開啟 app 連上相機時，所有設定自動還原

**白平衡預設值**（燭光 → 陰影）可快速套用常用色溫。

**Startup 區塊**（控制面板最下方）：
- *Launch at Login* — 開機時自動啟動 app
- *Minimize after connect* — 套用設定後自動縮到 Dock（搭配開機啟動使用）

## 支援的控制項

| 控制項 | 範圍 | Auto 模式 | 說明 |
|---|---|---|---|
| 白平衡色溫 | 2500–10000 K | 有效 | 透過 `ucwt` NativeData uint16 LE 寫入 |
| 曝光 | 1–10000 | 有效 | 透過 `ucea` NativeData uint32 LE 寫入 |
| 亮度 | 30–255 | 無 | 透過 `ucbt` NativeData byte 寫入 |
| 對比 | 0–10 | 無效 | Firmware 忽略 AutoManual 旗標 |
| 飽和度 | 0–200 | 無效 | Firmware 忽略 AutoManual 旗標 |
| 銳利度 | 0–50 | 無效 | Firmware 忽略 AutoManual 旗標 |
| 背光補償 | 0–10 | 無效 | Firmware 忽略 AutoManual 旗標 |
| 對焦 | 0–40 | 有效（透過 `ucfa`） | Auto 開關控制 UVC Focus Absolute |
| 電源線頻率 | 關 / 50 Hz / 60 Hz | — | 依所在地區電源頻率設定（台灣：60 Hz） |

## LifeCam Studio 不支援的功能

| 功能 | 原因 |
|---|---|
| Gain（增益） | 相機硬體未開放 |
| Hue（色相） | 相機硬體未開放 |
| Gamma（伽瑪） | 相機硬體未開放 |
| 光圈 | 固定光圈鏡頭，無法調整 |
| 縮放（Zoom） | CMIO 控制項存在，但 Firmware 忽略寫入值 |

## 設定持久化說明

所有 slider 數值和 Auto 開關狀態會自動存入 `UserDefaults`，下次連線時靜默還原。

- **硬體特性（揮發性）**：LifeCam 拔除 USB 或重開機後，相機會重置所有設定。設定無法儲存在相機本身。
- **透過此 App 持久化**：LifeCamWB 每次連上相機時自動套用上次儲存的設定。
- **首次使用**：尚無儲存設定，相機維持硬體預設狀態（自動白平衡、自動曝光、自動對焦）。

## 技術架構

### 為何使用 CoreMediaIO 而非 IOKit？

macOS 12 起，`UVCAssistant` 系統程序獨佔 USB VideoControl 介面的存取權。直接透過 IOKit 存取 USB 會收到 `kIOReturnExclusiveAccess` 錯誤。CoreMediaIO 透過 `UVCAssistant` 作為正確的通訊管道。

### 為何使用 NativeData 而非 NativeValue？

LifeCam Firmware 忽略標準 CMIO `NativeValue`（Float32）的寫入。實際控制需透過 `NativeData` 寫入原始 UVC 位元組：

| 控制項 | CMIO Class | 格式 |
|---|---|---|
| 白平衡 | `ucwt` | 2 bytes uint16 LE（Kelvin） |
| 曝光 | `ucea` | 4 bytes uint32 LE |
| 亮度 | `ucbt` | 1 byte |
| 對焦 | `ucfa` | 2 bytes uint16 LE |
