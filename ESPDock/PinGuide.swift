import Foundation

/// "How do I use this pin?" content for the hover popover.
///
/// Generated from a pin's functions rather than written per pin, so every
/// board in the catalog gets guides for free. Snippets are Arduino-ESP32
/// (core 3.x), which is what PlatformIO's `framework = arduino` uses; the
/// D/A pin names come from the XIAO ESP32S3 board variant.
///
/// Electrical facts are from the ESP32-S3 datasheet (Espressif, v1.9, §5
/// "Electrical Characteristics"): 3.3 V I/O, not 5 V tolerant, default drive
/// ~20 mA, internal pull-up/down ~45 kΩ. ADC facts: GPIO1–10 are on ADC1,
/// which keeps working while Wi-Fi is on (ADC2 does not).
struct PinGuide {
    struct Use: Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let code: String
    }

    let title: String
    let subtitle: String
    let functions: [PinFunction]
    let uses: [Use]
    let cautions: [String]

    // MARK: - Edge pins

    static func forPin(_ pin: Pin) -> PinGuide {
        switch pin.label {
        case "5V": return fiveVolt(pin)
        case "3V3": return threeVolt(pin)
        case "GND": return ground(pin)
        default: return gpio(pin)
        }
    }

    private static func gpio(_ pin: Pin) -> PinGuide {
        let p = pin.label                       // Arduino constant, e.g. D4
        let roles = Set(pin.functions.map(\.role))
        var uses: [Use] = []
        if roles.contains(.adc), let a = pin.functions.first(where: { $0.role == .adc })?.name {
            uses.append(Use(
                title: "Analog input",
                detail: "Measure 0–3.3 V, e.g. a potentiometer or sensor. 12-bit; ADC1, so it works with Wi-Fi on.",
                code: "int raw = analogRead(\(a));  // 0–4095\nint mv = analogReadMilliVolts(\(a));"))
        }
        if roles.contains(.touch) {
            uses.append(Use(
                title: "Capacitive touch",
                detail: "Touch a wire or pad directly — no button needed. On the S3 the value rises when touched; calibrate a threshold.",
                code: "// setup(): base = touchRead(\(p));\nbool touched = touchRead(\(p)) > base * 1.2;"))
        }
        if let f = pin.functions.first(where: { $0.role == .i2c }) {
            uses.append(Use(
                title: "I²C \(f.name)",
                detail: "Default I²C bus: SDA = D4, SCL = D5. Most I²C breakouts include pull-ups; add 4.7 kΩ to 3V3 if not.",
                code: "#include <Wire.h>\nWire.begin();   // SDA=D4, SCL=D5"))
        }
        if let f = pin.functions.first(where: { $0.role == .spi }) {
            uses.append(Use(
                title: "SPI \(f.name)",
                detail: "Default SPI bus: SCK = D8, MISO = D9, MOSI = D10. Pick any free GPIO as chip-select.",
                code: "#include <SPI.h>\nSPI.begin();   // SCK=D8, MISO=D9, MOSI=D10"))
        }
        if let f = pin.functions.first(where: { $0.role == .uart }) {
            uses.append(Use(
                title: "UART \(f.name)",
                detail: "Hardware serial on D6 (TX) / D7 (RX). Cross the wires: TX → other device's RX. USB serial (Serial) stays free.",
                code: "Serial1.begin(115200, SERIAL_8N1, D7, D6); // RX, TX\nSerial1.println(\"hello\");"))
        }

        // Generic GPIO use last: the pin's special functions are why you'd
        // look it up; every GPIO can do these.
        uses.append(Use(
            title: "Digital I/O & PWM",
            detail: "Output HIGH = 3.3 V; input with pull-up reads LOW when a button to GND is pressed. Any GPIO can do PWM.",
            code: "pinMode(\(p), OUTPUT); digitalWrite(\(p), HIGH);\npinMode(\(p), INPUT_PULLUP); digitalRead(\(p));\nanalogWrite(\(p), 128);  // PWM 0–255"))

        var cautions = ["3.3 V logic — not 5 V tolerant. Use a level shifter or divider for 5 V signals.",
                        "Keep load ≤ 20 mA; use a transistor/MOSFET for motors, relays or LED strips."]
        if let note = pin.note { cautions.insert(note, at: 0) }

        return PinGuide(title: pin.label,
                        subtitle: pin.gpio.map { "GPIO\($0)" } ?? "",
                        functions: pin.functions, uses: uses, cautions: cautions)
    }

    private static func fiveVolt(_ pin: Pin) -> PinGuide {
        PinGuide(
            title: "5V", subtitle: "VBUS", functions: pin.functions,
            uses: [
                Use(title: "Power 5 V parts from USB",
                    detail: "Passes USB 5 V straight through — for servos, 5 V LED strips or sensors that need 5 V. Limited by the USB port.",
                    code: "// no code: wire 5V → device VCC, GND → GND"),
                Use(title: "Power the board from 5 V",
                    detail: "Feed 5 V here when not on USB. Put a diode in series (cathode toward the pin) so it can't back-feed your USB port.",
                    code: "// external 5 V → diode → 5V pin"),
            ],
            cautions: ["No voltage here when running on battery.",
                       "Never connect a 5 V signal back into a GPIO."])
    }

    private static func threeVolt(_ pin: Pin) -> PinGuide {
        PinGuide(
            title: "3V3", subtitle: "Regulator output", functions: pin.functions,
            uses: [
                Use(title: "Power 3.3 V sensors",
                    detail: "Clean 3.3 V from the onboard regulator — the right supply for most I²C/SPI breakouts and for pull-up resistors.",
                    code: "// wire 3V3 → sensor VCC, GND → GND"),
            ],
            cautions: ["Up to 700 mA total, shared with the ESP32-S3 itself (Wi-Fi peaks ~350 mA).",
                       "Don't feed power into this pin while USB or battery is connected."])
    }

    private static func ground(_ pin: Pin) -> PinGuide {
        PinGuide(
            title: "GND", subtitle: "Ground", functions: [],
            uses: [
                Use(title: "Common ground",
                    detail: "Every external part and every other power supply must share this ground, or signals won't be read correctly.",
                    code: "// connect all GNDs together"),
            ],
            cautions: [])
    }

    // MARK: - Onboard parts

    static let userLED = PinGuide(
        title: "User LED", subtitle: "GPIO21 · orange", functions: [],
        uses: [
            Use(title: "Blink",
                detail: "Active-low: writing LOW turns it on.",
                code: "pinMode(LED_BUILTIN, OUTPUT);\ndigitalWrite(LED_BUILTIN, LOW);  // on"),
        ],
        cautions: ["On the XIAO ESP32S3 Sense, GPIO21 is also the SD card chip-select."])

    static let chargeLED = PinGuide(
        title: "Charge LED", subtitle: "red · hardware only", functions: [],
        uses: [
            Use(title: "Battery charging status",
                detail: "Driven by the charger chip, not a GPIO. Lights while a battery on the back pads is charging from USB; off when full. It may flicker with no battery attached.",
                code: "// not controllable from code"),
        ],
        cautions: [])

    static let b2bConnector = PinGuide(
        title: "B2B connector", subtitle: "expansion board", functions: [],
        uses: [
            Use(title: "Sense expansion board",
                detail: "Board-to-board connector for the XIAO ESP32S3 Sense camera + microSD board. It also carries D11 (GPIO42) and D12 (GPIO41), used by the Sense microphone.",
                code: "// press the Sense board on until it clicks; no wiring"),
        ],
        cautions: ["D11/D12 (GPIO41/42) have no working ADC despite older pin tables saying so."])

    static let bootButton = PinGuide(
        title: "BOOT", subtitle: "GPIO0", functions: [],
        uses: [
            Use(title: "Enter download mode",
                detail: "If upload can't find the board: hold BOOT, tap RESET, release BOOT, then upload.",
                code: "// hardware: hold B, tap R, release B"),
            Use(title: "Use as a button",
                detail: "Usable as an input after boot; reads LOW while pressed.",
                code: "pinMode(0, INPUT_PULLUP);\nbool pressed = digitalRead(0) == LOW;"),
        ],
        cautions: ["Strapping pin: it must not be held LOW at power-up, or the chip starts in download mode."])

    static let resetButton = PinGuide(
        title: "RESET", subtitle: "CHIP_PU", functions: [],
        uses: [
            Use(title: "Restart",
                detail: "Restarts your sketch from setup(). Uploaded code stays.",
                code: "ESP.restart();   // same thing from code"),
        ],
        cautions: [])

    static let antenna = PinGuide(
        title: "U.FL antenna", subtitle: "Wi-Fi / Bluetooth", functions: [],
        uses: [
            Use(title: "Attach the antenna",
                detail: "The XIAO ESP32S3 has no PCB antenna — Wi-Fi and Bluetooth need the supplied external antenna clicked in here.",
                code: "// press the U.FL plug straight down until it clicks"),
        ],
        cautions: ["U.FL connectors survive only ~30 connect cycles; leave it attached."])
}
