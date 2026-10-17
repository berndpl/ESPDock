# ESPDock

A small native macOS companion for ESP32 boards. Plug a board in and ESPDock
shows what's connected, what firmware it runs, and how to wire it — then
builds and uploads your PlatformIO project to it.

![ESPDock window](docs/window-light.png)

## Features

- **Live board detection** via IOKit notifications (no polling): port,
  USB VID:PID, serial number / MAC, which Mac port it's on, cable e-marker,
  link speed and USB power budget. Hints when macOS accessory security blocks
  a board's data connection.
- **Pinout diagram** (XIAO ESP32S3) drawn to scale, in realistic and blueprint
  styles, with per-pin popovers showing Arduino snippets.
- **Linked PlatformIO project** per board: open it in VS Code, see when source
  files changed, and **Build & Deploy** via `pio` with live progress.
- **Firmware version reporting**: an optional firmware library makes the board
  report project, commit and a source hash, so "up to date" is exact even for
  uploads made outside ESPDock.
- **Serial monitor** that shares the port with probes and uploads.
- **Background mode**: keeps running off the Dock and reopens when a board
  connects.

| Realistic | Blueprint | Serial monitor |
|---|---|---|
| ![](docs/style-realistic.png) | ![](docs/style-blueprint.png) | ![](docs/serial-monitor.png) |

## Requirements

- macOS 26 or later, Xcode 26+
- [PlatformIO Core](https://platformio.org/install/cli) installed at
  `~/.platformio/penv/bin/pio` (for Build & Deploy)
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the
  project from `project.yml`

## Build

```bash
xcodebuild -project ESPDock.xcodeproj -scheme ESPDock -configuration Release build
```

Or open `ESPDock.xcodeproj` in Xcode and run. The project signs ad hoc for
local use; pick a Team in Xcode to sign with your own identity.

The app runs without App Sandbox and Hardened Runtime because it reads IOKit
serial devices and launches the local PlatformIO CLI.

## Firmware version reporting

Use **Add Version Reporting…** in the project card to copy `FirmwareLib/ESPDock`
into a PlatformIO project's `lib/` and add its pre-build script. Then, after
`Serial.begin(...)` in `setup()`:

```cpp
#include <ESPDock.h>
ESPDock::begin();
```

The board prints its identity at boot and answers `ESPDOCK?` over serial.
See `FirmwareLib/ESPDock/src/ESPDock.h` for details.

## Design notes

[PRD.md](PRD.md) records the problem, scope, decisions and trade-offs.
