# ESPDock — PRD

## Problem
Working with ESP32 boards means juggling VS Code, PlatformIO's toolbar, and
`ls /dev/cu.*` to answer basic questions: *Is my board plugged in? Which port?
Which project is on it, and is that the version I think it is?* ESPDock is a
small native Mac app that answers those at a glance and lets me build/upload a
chosen PlatformIO project to the connected board.

## Audience
Just me, on my Mac. Not distributed, no App Store, no App Sandbox — the app
may run the local PlatformIO CLI (`~/.platformio/penv/bin/pio`) directly.

## Form
- Single main **window** (no menu bar extra).
- macOS 26+, SwiftUI, Liquid Glass / system styling.

## Features (phased)
1. **Board connection status** *(phase 1 — now)*
   - Live connected / not connected, updating instantly on plug/unplug.
   - Show port (`/dev/cu.usbmodem…`), USB VID:PID, chip/adapter description,
     serial number (on ESP32-S3 native USB this is the MAC address).
2. **Project ↔ board** *(done)*
   - Pick a PlatformIO project folder (has `platformio.ini`) and environment,
     remember it for the board.
   - Build and Upload buttons with live log output.
3. **Installed version** *(done)*
   - Firmware built via ESPDock embeds project name, git commit and build time.
   - Board reports it over serial on request; ESPDock shows it next to the
     local project's current version (match / outdated).
4. **Serial monitor** *(done)* — toggle in the board card (⇧⌘M), panel on the right.
5. **Connection & power details** *(phase 1b — done)*
   - Link speed, Mac USB-C port (or hub path), cable (passive vs e-marked,
     rated current), USB power budget (allocated / port limit).
   - Hint when a Mac port has something attached whose data link macOS's
     accessory security hasn't authorized (board powered but invisible).

## Success criteria
- Plugging/unplugging the XIAO ESP32S3 updates the window within ~1 s.
- (Phase 2–3) One click builds + uploads the selected project; the window then
  shows the version the board reports and that it matches the local build.

## Non-goals
- No code editor — editing stays in VS Code.
- One board at a time (if several are attached, show the first; no multi-board UI).
- Not a general PlatformIO replacement (no library manager, no board creation).

## Decisions
- **Detection via IOKit notifications, not polling `pio device list`.**
  Spawning PlatformIO's Python every few seconds costs ~0.5 s CPU per call and
  still lags; IOKit add/remove notifications are instant and free when idle.
  PlatformIO is used only for build/upload.
- **ESP32 recognition by USB vendor ID**: Espressif native USB (0x303A) plus
  common USB-UART bridges on dev boards (Silicon Labs CP210x 0x10C4, WCH CH34x
  0x1A86, FTDI 0x0403). Bridges are labelled "possible ESP32", since they are
  also used by non-ESP boards.
- **Version via firmware self-report** (chosen over flash-hash comparison):
  exact and human-readable, at the cost of only working for firmware built
  through ESPDock.
- **No live power draw.** macOS has no per-port current measurement; only
  the USB power *budget* is shown, labelled as such. Real draw would need a
  sensor on the board (e.g. INA219) reporting over serial.
- **Board → Mac port mapping via IOPort transport metadata** (vendor/product
  ID + serial number on the port's USB2/USB3 node), not controller numbering,
  which isn't documented. The IOPort plane itself is undocumented (it's what
  System Information reads), so this may need adjusting on future macOS.
- **Accessory-security hint**: found on 2026-10-17 when the XIAO had power on
  USB-C port 2 but its USB2 transport was "Unauthorized"; replugging while
  unlocked fixed it. Detected by a 3 s IORegistry poll only while no board is
  connected (no process spawns).
- **Background mode** (setting, default on): closing the window keeps the app
  alive off the Dock (`.accessory` policy); reopening the app restores it.
  "Bring to front when a board connects" (setting, default on) reopens the
  window *above* other windows. It can't take keyboard focus: macOS 14+
  activation is cooperative by design. Launch-at-login is not done yet.
- **Pin guides**: hover popover per pin (click to keep open) with Arduino
  snippets, generated from pin functions, not hand-written per pin.
- **Project link** is stored per board MAC (UserDefaults JSON): folder +
  PlatformIO env (auto-picked by `board =` match, then `default_envs`).
- **"Code changed"** = per-file SHA-256 of platformio.ini, root *.csv, src/,
  include/, lib/ vs. the snapshot taken when ESPDock last deployed. Watched
  live with FSEvents (1 s latency, .pio/ and .git/ ignored). Limitation: an
  upload from VS Code isn't seen — phase 3 (firmware self-report) fixes that.
- **Build & Deploy** runs `~/.platformio/penv/bin/pio run -e ENV -t upload
  --upload-port PORT`; progress parsed from esptool "Writing at … (N %)".
  Disconnects get a 2 s grace period so the post-upload reset doesn't flash
  "No board".
- **Firmware version report**: `lib/ESPDock` (installed by "Add Version
  Reporting…") + pre-build script stamping project/env/commit/build time/
  source hash; `ESPDock::begin()` prints it at boot and answers `ESPDOCK?`.
  The source hash uses the same algorithm as the app's CodeFingerprint, so
  "up to date" is exact for uploads from anywhere (verified: CLI upload,
  board hash == folder hash). Port opened without DTR/RTS changes → no reset.
- **Serial monitor** owns the port while shown; version queries go through
  it; Build & Deploy suspends it and it reattaches after the reset. Panel is
  a native `.inspector`, toggled from the window toolbar (⇧⌘M); its controls
  (baud, pause, timestamps, clear) sit in the toolbar above the column. The
  inspector reserves its column even while hidden, so the outer frame is
  pinned explicitly (520 pt closed, 960 pt open; height = measured cards).
  Not persisted: the window always opens without the monitor.
