#include "ESPDock.h"

#include <Arduino.h>

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

void report() {
    Serial.printf("ESPDOCK {\"project\":\"%s\",\"env\":\"%s\",\"commit\":\"%s\","
                  "\"built\":\"%s\",\"source\":\"%s\",\"uptime\":%lu}\n",
                  ESPDOCK_PROJECT, ESPDOCK_ENV, ESPDOCK_COMMIT, ESPDOCK_BUILT,
                  ESPDOCK_SOURCE, (unsigned long)millis());
}

// Polls Serial every 50 ms for a "ESPDOCK?" line. A task (rather than a hook
// in loop()) keeps the sketch unchanged apart from begin().
static void queryTask(void*) {
    String line;
    for (;;) {
        while (Serial.available()) {
            char c = (char)Serial.read();
            if (c == '\n' || c == '\r') {
                line.trim();
                if (line == "ESPDOCK?") report();
                line = "";
            } else if (line.length() < 16) {
                line += c;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

void begin() {
    report();
    xTaskCreate(queryTask, "espdock", 3072, nullptr, 1, nullptr);
}

}  // namespace ESPDock
