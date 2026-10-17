#pragma once
#include <Arduino.h>

namespace ESPDock {
void writeFirmwareJSON(Print& output);
namespace Wireless {
void enable();
void enqueue(const uint8_t* bytes, size_t length);
void service();
void pairingReport();
}
}
