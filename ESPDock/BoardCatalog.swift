import Foundation
import Observation

/// What a pin (or one of its alternate functions) is for. Mirrors the colour
/// legend of Seeed's pinout graphics so the diagram reads the same way.
enum PinRole: String, CaseIterable {
    case power, ground, gpio, adc, touch, i2c, spi, uart, system

    var legend: String {
        switch self {
        case .power: "Power"
        case .ground: "GND"
        case .gpio: "GPIO"
        case .adc: "ADC"
        case .touch: "Touch"
        case .i2c: "I²C"
        case .spi: "SPI"
        case .uart: "UART"
        case .system: "System"
        }
    }
}

struct PinFunction: Hashable {
    let name: String
    let role: PinRole
}

struct Pin: Identifiable, Hashable {
    enum Side { case left, right }
    var id: String { label }
    let label: String          // silkscreen, e.g. "D4"
    let side: Side
    let gpio: Int?
    let functions: [PinFunction]
    var note: String? = nil    // shown as tooltip; e.g. strapping-pin warnings

    /// Role of the pin itself, for the pad colour.
    var role: PinRole {
        switch label {
        case "5V", "3V3": .power
        case "GND": .ground
        default: .gpio
        }
    }
}

struct OnboardFeature: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
}

struct BoardModel: Identifiable, Hashable {
    let id: String
    let name: String
    let chip: String
    let sizeMM: String
    /// PlatformIO `board =` id, used to pick the matching environment.
    let platformIOBoard: String
    /// Pins in physical order, top (USB end) to bottom, per side, viewed from
    /// the component side with USB-C at the top.
    let pins: [Pin]
    let features: [OnboardFeature]
    let referenceURL: URL
    let schematicURL: URL

    func pins(on side: Pin.Side) -> [Pin] { pins.filter { $0.side == side } }
}

enum BoardCatalog {
    /// Boards offered for a given USB vendor ID. Native-USB ESP32-S3 boards all
    /// enumerate as 303A:1001, so the model can't be detected — the user picks
    /// it once and it's remembered per MAC address.
    static func candidates(for board: Board) -> [BoardModel] {
        board.isCertainlyESP32 ? [xiaoESP32S3] : []
    }

    static func model(id: String) -> BoardModel? {
        [xiaoESP32S3].first { $0.id == id }
    }

    // Source: Seeed Studio wiki, "Getting Started with Seeed Studio XIAO ESP32S3"
    // pin map table + front pinout graphic (for physical order), read 2026-10-17:
    // https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/
    // https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32S3/img/XIAO_ESP32-S3_front_pinout.png
    static let xiaoESP32S3 = BoardModel(
        id: "seeed-xiao-esp32s3",
        name: "Seeed XIAO ESP32S3",
        chip: "ESP32-S3R8 · 8 MB PSRAM · 8 MB flash",
        sizeMM: "21 × 17.8 mm",
        platformIOBoard: "seeed_xiao_esp32s3",
        pins: [
            // Left side, top → bottom
            Pin(label: "D0", side: .left, gpio: 1,
                functions: [.init(name: "A0", role: .adc), .init(name: "T1", role: .touch)]),
            Pin(label: "D1", side: .left, gpio: 2,
                functions: [.init(name: "A1", role: .adc), .init(name: "T2", role: .touch)]),
            Pin(label: "D2", side: .left, gpio: 3,
                functions: [.init(name: "A2", role: .adc), .init(name: "T3", role: .touch)],
                note: "GPIO3 is a strapping pin (JTAG signal source) — avoid driving it at boot."),
            Pin(label: "D3", side: .left, gpio: 4,
                functions: [.init(name: "A3", role: .adc), .init(name: "T4", role: .touch)]),
            Pin(label: "D4", side: .left, gpio: 5,
                functions: [.init(name: "A4", role: .adc), .init(name: "T5", role: .touch),
                            .init(name: "SDA", role: .i2c)]),
            Pin(label: "D5", side: .left, gpio: 6,
                functions: [.init(name: "A5", role: .adc), .init(name: "T6", role: .touch),
                            .init(name: "SCL", role: .i2c)]),
            Pin(label: "D6", side: .left, gpio: 43,
                functions: [.init(name: "TX", role: .uart)]),
            // Right side, top → bottom
            Pin(label: "5V", side: .right, gpio: nil,
                functions: [.init(name: "VBUS", role: .power)],
                note: "USB 5 V in/out. No voltage here when running on battery. If feeding 5 V in, add a series diode (cathode toward the pin)."),
            Pin(label: "GND", side: .right, gpio: nil, functions: []),
            Pin(label: "3V3", side: .right, gpio: nil,
                functions: [.init(name: "3.3 V out", role: .power)],
                note: "Regulator output, up to 700 mA."),
            Pin(label: "D10", side: .right, gpio: 9,
                functions: [.init(name: "A10", role: .adc), .init(name: "T9", role: .touch),
                            .init(name: "MOSI", role: .spi)]),
            Pin(label: "D9", side: .right, gpio: 8,
                functions: [.init(name: "A9", role: .adc), .init(name: "T8", role: .touch),
                            .init(name: "MISO", role: .spi)]),
            Pin(label: "D8", side: .right, gpio: 7,
                functions: [.init(name: "A8", role: .adc), .init(name: "T7", role: .touch),
                            .init(name: "SCK", role: .spi)]),
            Pin(label: "D7", side: .right, gpio: 44,
                functions: [.init(name: "RX", role: .uart)]),
        ],
        features: [
            .init(name: "User LED", detail: "GPIO21 · orange · active-low (LOW = on)"),
            .init(name: "BOOT button", detail: "GPIO0 · hold while resetting to enter download mode"),
            .init(name: "RESET button", detail: "CHIP_PU"),
            .init(name: "Charge LED", detail: "Red · not on a GPIO"),
            .init(name: "Battery pads (back)", detail: "3.7 V Li-ion · negative pad is the one nearer USB"),
            .init(name: "JTAG pads (back)", detail: "MTCK GPIO39 · MTDO GPIO40 · MTDI GPIO41 · MTMS GPIO42"),
            .init(name: "Antenna", detail: "U.FL connector, bottom-left of the front"),
        ],
        referenceURL: URL(string: "https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/")!,
        schematicURL: URL(string: "https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32S3/new-res/202003751_XIAO%20ESP32S3_v1.4_SCH_260226.pdf.pdf")!)
}

/// Remembers which board model a physical board is, keyed by its MAC address
/// (ESP32 native USB serial number). UserDefaults is enough: a handful of
/// entries, personal tool. This is also where project links will live (phase 2).
@MainActor
@Observable
final class BoardIdentities {
    private static let key = "boardModelByMAC"
    private var byMAC: [String: String]

    init() {
        byMAC = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func model(for board: Board) -> BoardModel? {
        guard let mac = board.macAddress, let id = byMAC[mac] else { return nil }
        return BoardCatalog.model(id: id)
    }

    func assign(_ model: BoardModel?, to board: Board) {
        guard let mac = board.macAddress else { return }
        byMAC[mac] = model?.id
        UserDefaults.standard.set(byMAC, forKey: Self.key)
    }
}
