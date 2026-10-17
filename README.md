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
- **Serial monitor** that shares the port with probes and uploads. **Copy Output**
  copies all buffered logs to the clipboard, respecting the timestamp toggle.
- **Paired Wi-Fi monitoring**: the same board, project, wiring and firmware
  identity without a USB cable, with read-only live logs. USB takes priority;
  uploads remain USB-only.
- **Project wiring diagram** for a MAX98357A I²S amplifier and volume buttons,
  with source locations and shared-pin warnings. Speaker wiring and switch
  return wires are shown dashed as assumptions, not detected hardware. Hover
  a wire to trace it; click to keep it highlighted while checking the hardware.
  Click it again, press Escape, or use Clear highlight to clear the selection.
  Wiring-details rows support the same selection.
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
xcodebuild -project ESPDock.xcodeproj -scheme ESPDock -configuration Release \
  -derivedDataPath .build-local build
```

Or open `ESPDock.xcodeproj` in Xcode and run. The project signs ad hoc for
local use; pick a Team in Xcode to sign with your own identity.

The app uses an Icon Composer package, not static PNG icon slots. The root
`AppIcon.icon` is the editable master; its identical copy at
`ESPDock/Assets.xcassets/AppIcon.icon` is explicitly listed as a target resource
so Xcode compiles it. After updating that copy, regenerate with
`xcodegen generate` and clean-build to refresh the icon.

Run the scanner, layout and wireless connection tests with:

```bash
xcodebuild -project ESPDock.xcodeproj -scheme ESPDock -destination 'platform=macOS' \
  -derivedDataPath .build-local test
```

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

## Wi-Fi monitoring

This is an optional **read-only TCP log stream**, not JTAG debugging or OTA.
The sketch must already connect to Wi-Fi. There is no discovery, cloud,
HTTP server, extra firmware task or remote command execution.

1. Open the toolbar's **Wi-Fi Monitoring** button. With the board connected
   over USB and its project linked, use **Update Library** if needed.
2. Enable the sender in the sketch and route the logs you want to monitor:

   ```cpp
   #include <ESPDock.h>

   void setup() {
       Serial.begin(115200);
       ESPDock::begin(true); // begin() without true remains USB-only
       // Configure/connect Wi-Fi as usual; ESPDock does not own your network.
   }

   void loop() {
       // Keep the application's normal work here.
       // Example log (emit at the application's normal logging cadence):
       // ESPDock::log().printf("Volume: %d\n", currentVolume);
   }
   ```

3. **Build & Deploy over USB once**, wait for Wi-Fi, then select **Pair
   Connected USB Board**. ESPDock reads the LAN address and a generated token
   through USB, authenticates the network identity, stores the token in macOS
   Keychain, and remembers the endpoint separately. Pairing responses are
   consumed before monitor logging; the token is never added to normal logs.
4. Remove USB while keeping the board powered. The same model/project key is
   retained, with a **Wi-Fi · Read-only** status. Open the device monitor with
   ⇧⌘M. Baud and send controls are disabled; cable/power facts are not invented.

Remembered connections retry after transient loss. A changed board identity or
rejected token requires reconnecting/pairing rather than silently trusting the
new device. **Disconnect** stops retries; **Forget** removes the saved token
and endpoint. If DHCP changes the address, pair again over USB, or manually
enter the current private IPv4 address / `.local` hostname, port and token.
Manual pairing preserves an earlier USB association only when the authenticated
board has already been paired. macOS may request Local Network or Keychain access.

On each app launch, choose **Allow Wi-Fi** in Wi-Fi Monitoring to authorize use
of the saved token. Keychain reads happen only after this explicit action, never
from startup or automatic retries. The authorized token is reused in memory for
the app session; **Forget** clears it as well as the saved pairing. This avoids
password-dialog loops during development without weakening Keychain protection.
Ad-hoc rebuilds change the app's signing identity, so macOS can require fresh
approval even after Always Allow. Choose your own Team in Xcode if you want a
stable signing identity; ESPDock does not change that selection.

**Trusted LAN only:** traffic and the token are **not encrypted**. Do not
forward TCP port **3232**, expose it to the internet, or use an untrusted/shared
network. Anyone who captures the token can read logs or impersonate the device.
The board generates a random 128-bit token once Wi-Fi is active and persists
it in NVS; it is not embedded in source or a firmware version report. Forgetting
on the Mac does not rotate the board's token. Erasing its `espdock` NVS namespace
causes regeneration, after which every viewer must pair again.

### Protocol and overhead

- One viewer on TCP 3232; additional clients are closed.
- Client sends `ESPDOCK AUTH <32 lowercase hex characters>\n` within 3 seconds.
  On success the board sends
  `ESPDOCK HELLO {"version":1,"board":"<factory MAC>","firmware":{...}}\n`.
  Then it sends newline-delimited logs and an `ESPDOCK ALIVE` heartbeat during
  quiet periods (5 seconds). Authentication failure sends
  `ESPDOCK ERROR unauthorized\n`; **no post-authentication commands** are accepted.
- `ESPDOCK WIFI?` is a **USB-only** query returning `ESPDOCK WIFI` plus JSON
  containing `board`, `host`, `port`, `token`, or an explicit `error`. The
  factory MAC is validated separately from the original USB descriptor/project
  key; Wi-Fi station and USB MACs need not match.
- The existing reporting task services non-blocking sockets every 50 ms. The
  sender uses a 2 KiB ring, a 512-byte line buffer (511 bytes plus newline),
  and a 1 KiB transmit buffer. Full/overlong lines are dropped and counted;
  a stalled viewer is disconnected rather than delaying audio. No Wi-Fi log
  backlog is retained without an authenticated viewer.
- Wi-Fi mode uses a 6 KiB task stack (USB-only uses 3 KiB), plus the fixed
  buffers, RTOS/lwIP allocations and socket buffers. Actual heap/CPU and audio
  impact depend on the sketch and have not been profiled. `ESPDock::log()` also
  writes only currently available USB space, dropping excess rather than
  waiting for a disconnected or slow host.
- The Mac bounds each line at 4 KiB and keeps the monitor's newest 5,000 lines.
  An identity must arrive within 5 seconds; 15 seconds without traffic causes
  reconnect. Unsupported identities and oversized lines fail explicitly.

Early boot, crashes before Wi-Fi, library output written directly to `Serial`,
and overflowed logs still require USB. Local builds remain available in the
editor/PlatformIO, but ESPDock's combined **Build & Deploy** is disabled on
Wi-Fi and its deployer independently rejects wireless uploads. OTA is not included.
The project card's USB-deployment reminder appears only when code changes are detected.

For a live-board smoke check in a Debug build:

```bash
.build-local/Build/Products/Debug/ESPDock.app/Contents/MacOS/ESPDock \
  --verify-wireless /dev/cu.usbmodem1101
```

Quit the GUI first. The check pairs the linked USB board (saving its token in
Keychain), checks the firmware source hash, receives application logs with the
USB monitor closed, then reconnects using the saved token without another USB
query. It exits unsuccessfully on a mismatch or timeout and never prints tokens.
This checks transport and reported firmware, not audible speaker output.

## Radio wiring

For projects such as [ESP-Radio](https://github.com/berndpl/ESP-Radio), ESPDock
recognises amplifier pin setup and volume inputs named with `VOL` and `UP` or
`DOWN`, configured with `pinMode` and read with `digitalRead`. For example:

```cpp
constexpr int BTN_VOL_UP_PIN = D4;
pinMode(BTN_VOL_UP_PIN, INPUT_PULLUP);
if (digitalRead(BTN_VOL_UP_PIN) == LOW) { /* raise volume */ }
```

`INPUT_PULLUP` suggests a switch to GND; `INPUT_PULLDOWN` suggests 3V3.
Plain `INPUT` requires an external pull resistor and doesn't imply a return
wire. A passive speaker is shown on amplifier OUT+/OUT−, never on ESP32 pins
or ground. Its presence, model, impedance and physical wiring cannot be
established from code; verify them before connecting hardware.

Each external component has its own vertically stacked cell. Wires run beside
the cells to their destination contacts; expand **Wiring details** for source
locations and warnings. The diagram describes the **linked local folder**, not
another repository with the same name—an LED-only sketch won't imply a radio's
amplifier or controls.
Every component has a top-right info button with model information and the
available guide, schematic, datasheet or product reference. Reference breakout
schematics are labelled as such; no schematic is invented for passive parts.
Hardware names in source comments, `README.md`, `WIRING.md` or `brief-radio.md`
identify the Dayton Audio PC83-8 and NuPhy switches without inventing pin
assignments or changing the firmware fingerprint. NuPhy's exact switch variant
remains unspecified.

The window is vertically resizable. Only the schematic card scrolls, keeping
board status and project actions visible above it.

## Design notes

[PRD.md](PRD.md) records the problem, scope, decisions and trade-offs.
