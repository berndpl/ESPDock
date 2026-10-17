// ESPDock version reporting.
//
// Lets the ESPDock Mac app see exactly which code is on this board, even when
// it was uploaded from VS Code. Usage — after Serial.begin(...) in setup():
//
//   #include <ESPDock.h>
//   ESPDock::begin();
//
// The board then prints one identity line at boot and answers "ESPDOCK?" on
// Serial with:  ESPDOCK {"project":…,"env":…,"commit":…,"built":…,"source":…}
//
// Note: a small background task reads Serial input to catch the query. If your
// sketch reads Serial itself, both compete for incoming bytes; in that case
// skip begin() and call ESPDock::report() when your code sees "ESPDOCK?".
#pragma once

#include <Arduino.h>

namespace ESPDock {
// Opt in to one-client, read-only Wi-Fi logging on TCP port 3232.
// Query "ESPDOCK WIFI?" over USB to obtain the address and pairing token.
void begin(bool wifiLogs = false);
void report();
// Writes to USB as before; complete lines are also queued for Wi-Fi.
// Wi-Fi never waits for a slow viewer. Overlong/full-buffer lines are dropped.
Print& log();
}
