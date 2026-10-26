#include "ESPDock.h"

#include <Arduino.h>
#include "WirelessLogs.h"

#if __has_include("espdock_build_info.h")
#include "espdock_build_info.h"
#else
// espdock_version.py isn't in extra_scripts: report what we can.
#define ESPDOCK_PROJECT ""
#define ESPDOCK_ENV ""
#define ESPDOCK_COMMIT ""
#define ESPDOCK_BUILT ""
#define ESPDOCK_SOURCE ""
#endif

namespace ESPDock {

static void jsonString(Print& output, const char* text) {
    output.write('"');
    for (; *text; ++text) {
        const uint8_t c = static_cast<uint8_t>(*text);
        if (c == '"' || c == '\\') { output.write('\\'); output.write(c); }
        else if (c < 32) { output.printf("\\u%04x", c); }
        else { output.write(c); }
    }
    output.write('"');
}

void writeFirmwareJSON(Print& output) {
    output.print("{\"project\":"); jsonString(output, ESPDOCK_PROJECT);
    output.print(",\"env\":"); jsonString(output, ESPDOCK_ENV);
    output.print(",\"commit\":"); jsonString(output, ESPDOCK_COMMIT);
    output.print(",\"built\":"); jsonString(output, ESPDOCK_BUILT);
    output.print(",\"source\":"); jsonString(output, ESPDOCK_SOURCE);
    output.printf(",\"uptime\":%lu}", static_cast<unsigned long>(millis()));
}

void report() {
    if (!Serial) return;
    Serial.print("ESPDOCK ");
    writeFirmwareJSON(Serial);
    Serial.println();
}

class LogOutput final : public Print {
public:
    size_t write(uint8_t c) override { return write(&c, 1); }
    size_t write(const uint8_t* bytes, size_t length) override {
        // Native USB can block when its host disappears. Only write the space
        // already available; neither output is allowed to hold up audio.
        if (Serial) {
            const int available = Serial.availableForWrite();
            if (available > 0) Serial.write(bytes, min(length, static_cast<size_t>(available)));
        }
        Wireless::enqueue(bytes, length);
        return length;
    }
};

Print& log() {
    static LogOutput output;
    return output;
}

// Polls Serial every 50 ms for a "ESPDOCK?" line. A task (rather than a hook
// in loop()) keeps the sketch unchanged apart from begin().
static void queryTask(void*) {
    String line;
    for (;;) {
        Wireless::service();
        while (Serial.available()) {
            char c = (char)Serial.read();
            if (c == '\n' || c == '\r') {
                line.trim();
                if (line == "ESPDOCK?") report();
                else if (line == "ESPDOCK WIFI?") Wireless::pairingReport();
                line = "";
            } else if (line.length() < 16) {
                line += c;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

void begin(bool wifiLogs) {
    static bool started = false;
    if (wifiLogs) Wireless::enable();
    if (started) return;
    started = true;
    report();
    if (xTaskCreate(queryTask, "espdock", wifiLogs ? 6144 : 3072, nullptr, 1, nullptr) != pdPASS) {
        started = false;
        Serial.println("ESPDock: couldn't start the reporting task.");
    }
}

}  // namespace ESPDock
