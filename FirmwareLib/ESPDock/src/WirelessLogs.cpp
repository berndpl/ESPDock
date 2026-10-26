#include "WirelessLogs.h"

#include <Preferences.h>
#include <WiFi.h>
#include <esp_mac.h>
#include <esp_system.h>
#include <fcntl.h>
#include <lwip/sockets.h>
#include <errno.h>

namespace ESPDock { namespace Wireless {
namespace {
constexpr uint16_t port = 3232;
constexpr size_t capacity = 2048;
constexpr size_t maxLine = 512;
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
bool enabled = false, capturing = false;
uint8_t queue[capacity], line[maxLine];
size_t head = 0, tail = 0, count = 0, lineLength = 0;
bool discarding = false;
uint32_t dropped = 0;

int listener = -1, client = -1;
enum class State { authenticating, greeting, streaming, rejecting };
State state = State::authenticating;
char token[33] = {}, boardID[18] = {}, auth[96] = {}, tx[1024] = {};
size_t authLength = 0, txLength = 0, txOffset = 0;
bool tokenAttempted = false, tokenReady = false, listenAttempted = false;
uint32_t acceptedAt = 0, lastWrite = 0, lastHeartbeat = 0, listenAttempt = 0;

void capture(bool value) {
    portENTER_CRITICAL(&mux);
    capturing = value;
    head = tail = count = lineLength = dropped = 0;
    discarding = false;
    portEXIT_CRITICAL(&mux);
}

void closeClient() {
    if (client >= 0) close(client);
    client = -1;
    txLength = txOffset = authLength = 0;
    capture(false);
}

bool nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0;
}

bool initializeToken() {
    if (tokenAttempted) return tokenReady;
    tokenAttempted = true;
    Preferences preferences;
    if (!preferences.begin("espdock", false)) {
        Serial.println("ESPDock: couldn't open pairing storage; Wi-Fi logging disabled.");
        return false;
    }
    uint8_t secret[16];
    if (preferences.getBytesLength("wifi-token") == sizeof(secret)) {
        if (preferences.getBytes("wifi-token", secret, sizeof(secret)) != sizeof(secret)) {
            preferences.end();
            Serial.println("ESPDock: couldn't read pairing token; Wi-Fi logging disabled.");
            return false;
        }
    } else {
        // Called only once Wi-Fi is up, when the RNG has RF entropy.
        esp_fill_random(secret, sizeof(secret));
        if (preferences.putBytes("wifi-token", secret, sizeof(secret)) != sizeof(secret)) {
            preferences.end();
            Serial.println("ESPDock: couldn't save pairing token; Wi-Fi logging disabled.");
            return false;
        }
    }
    preferences.end();
    for (size_t i = 0; i < sizeof(secret); ++i) snprintf(token + i * 2, 3, "%02x", secret[i]);
    uint8_t mac[6];
    if (esp_efuse_mac_get_default(mac) != ESP_OK) {
        Serial.println("ESPDock: couldn't read board identity; Wi-Fi logging disabled.");
        return false;
    }
    snprintf(boardID, sizeof(boardID), "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    tokenReady = true;
    return true;
}

class BufferOutput final : public Print {
public:
    size_t length = 0;
    bool overflow = false;
    size_t write(uint8_t c) override {
        if (length < sizeof(tx)) tx[length++] = static_cast<char>(c);
        else overflow = true;
        return 1;
    }
};

void reject() {
    state = State::rejecting;
    txLength = snprintf(tx, sizeof(tx), "ESPDOCK ERROR unauthorized\n");
    txOffset = 0;
}

void authenticate() {
    constexpr char prefix[] = "ESPDOCK AUTH ";
    if (authLength != sizeof(prefix) - 1 + 32 || memcmp(auth, prefix, sizeof(prefix) - 1) != 0) {
        reject();
        return;
    }
    uint8_t difference = 0;
    for (size_t i = 0; i < 32; ++i) difference |= auth[sizeof(prefix) - 1 + i] ^ token[i];
    if (difference != 0) { reject(); return; }
    BufferOutput output;
    output.printf("ESPDOCK HELLO {\"version\":1,\"board\":\"%s\",\"firmware\":", boardID);
    writeFirmwareJSON(output);
    output.print("}\n");
    if (output.overflow) {
        Serial.println("ESPDock: firmware identity exceeds the network buffer.");
        closeClient();
        return;
    }
    txLength = output.length;
    txOffset = 0;
    state = State::greeting;
}

void startListener(uint32_t now) {
    if (listenAttempted && now - listenAttempt < 5000) return;
    listenAttempted = true;
    listenAttempt = now;
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { Serial.println("ESPDock: couldn't create the logging socket."); return; }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (!nonblocking(fd) || bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0 || listen(fd, 1) < 0) {
        close(fd);
        Serial.println("ESPDock: couldn't listen for Wi-Fi logs on port 3232.");
        return;
    }
    listener = fd;
}
}

void enable() { enabled = true; }

void enqueue(const uint8_t* bytes, size_t length) {
    portENTER_CRITICAL(&mux);
    if (!capturing) { portEXIT_CRITICAL(&mux); return; }
    for (size_t i = 0; i < length; ++i) {
        const uint8_t c = bytes[i];
        if (c == '\r') continue;
        if (c != '\n') {
            if (lineLength < maxLine - 1 && !discarding) line[lineLength++] = c;
            else discarding = true;
            continue;
        }
        if (discarding || capacity - count < lineLength + 1) {
            ++dropped;
        } else {
            for (size_t j = 0; j < lineLength; ++j) { queue[head] = line[j]; head = (head + 1) % capacity; }
            queue[head] = '\n';
            head = (head + 1) % capacity;
            count += lineLength + 1;
        }
        lineLength = 0;
        discarding = false;
    }
    portEXIT_CRITICAL(&mux);
}

void pairingReport() {
    if (!enabled) {
        Serial.println("\nESPDOCK WIFI {\"error\":\"Enable Wi-Fi logging with ESPDock::begin(true), then deploy over USB.\"}");
    } else if (WiFi.status() != WL_CONNECTED) {
        Serial.println("\nESPDOCK WIFI {\"error\":\"The board is not connected to Wi-Fi yet.\"}");
    } else if (!initializeToken()) {
        Serial.println("\nESPDOCK WIFI {\"error\":\"Pairing storage is unavailable. Check the USB log.\"}");
    } else {
        // Never send this through log(): the token is delivered over USB only.
        Serial.printf("\nESPDOCK WIFI {\"board\":\"%s\",\"host\":\"%s\",\"port\":%u,\"token\":\"%s\"}\n",
                      boardID, WiFi.localIP().toString().c_str(), port, token);
    }
}

void service() {
    if (!enabled) return;
    if (WiFi.status() != WL_CONNECTED) {
        closeClient();
        if (listener >= 0) { close(listener); listener = -1; }
        return;
    }
    if (!initializeToken()) return;
    const uint32_t now = millis();
    if (listener < 0) startListener(now);
    if (listener < 0) return;
    int incoming = accept(listener, nullptr, nullptr);
    if (incoming >= 0) {
        if (client >= 0 || !nonblocking(incoming)) close(incoming);
        else {
            client = incoming;
            state = State::authenticating;
            acceptedAt = lastWrite = lastHeartbeat = now;
            authLength = txLength = txOffset = 0;
        }
    }
    if (client < 0) return;
    uint8_t input[96];
    const int received = recv(client, input, sizeof(input), MSG_DONTWAIT);
    if (received == 0 || (received < 0 && errno != EWOULDBLOCK && errno != EAGAIN)) { closeClient(); return; }
    if (received > 0) {
        if (state != State::authenticating) { closeClient(); return; }
        for (int i = 0; i < received; ++i) {
            if (input[i] == '\r') continue;
            if (input[i] == '\n') {
                authenticate();
                // The protocol is read-only after its single authentication line.
                if (i + 1 < received) { closeClient(); return; }
                break;
            }
            if (authLength >= sizeof(auth)) { reject(); break; }
            auth[authLength++] = static_cast<char>(input[i]);
        }
    }
    if (client < 0) return;
    if (state == State::authenticating && now - acceptedAt > 3000) { closeClient(); return; }
    if (txOffset < txLength) {
        const int sent = send(client, tx + txOffset, txLength - txOffset, MSG_DONTWAIT);
        if (sent > 0) { txOffset += sent; lastWrite = now; }
        else if (sent < 0 && errno != EWOULDBLOCK && errno != EAGAIN) { closeClient(); return; }
        if (now - lastWrite > 10000) { closeClient(); return; }
        if (txOffset < txLength) return;
        txLength = txOffset = 0;
        if (state == State::rejecting) { closeClient(); return; }
        if (state == State::greeting) { state = State::streaming; capture(true); }
    }
    if (state != State::streaming) return;
    portENTER_CRITICAL(&mux);
    const uint32_t lost = dropped;
    dropped = 0;
    if (lost == 0) {
        while (count > 0 && txLength < sizeof(tx)) {
            const char c = static_cast<char>(queue[tail]);
            tx[txLength++] = c;
            tail = (tail + 1) % capacity;
            --count;
            if (c == '\n') break;
        }
    }
    portEXIT_CRITICAL(&mux);
    if (lost > 0) txLength = snprintf(tx, sizeof(tx), "ESPDock: %lu log lines dropped\n", static_cast<unsigned long>(lost));
    if (txLength == 0 && now - lastHeartbeat >= 5000) {
        txLength = snprintf(tx, sizeof(tx), "ESPDOCK ALIVE\n");
        lastHeartbeat = now;
    }
}
} }
