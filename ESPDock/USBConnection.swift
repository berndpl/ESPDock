import Foundation
import IOKit

/// How a board is attached: link speed, path through hubs, and power budget.
///
/// What macOS does *not* expose: live current draw. There is no per-port
/// current sensing in IOKit, so everything power-related here is the USB
/// *budget* (what the device requested / was allocated and what the port can
/// supply), not a measurement. Measuring real draw needs hardware on the board
/// side (e.g. an INA219 reporting over serial).
struct USBConnection: Equatable {
    enum Speed: Int {
        // Values of IOUSBHostFamily's "Device Speed" property.
        case low = 0, full, high, superSpeed, superSpeedPlus, superSpeedPlusBy2

        var description: String {
            switch self {
            case .low:               "USB 1.1 Low Speed · 1.5 Mbit/s"
            case .full:              "USB 1.1 Full Speed · 12 Mbit/s"
            case .high:              "USB 2.0 High Speed · 480 Mbit/s"
            case .superSpeed:        "USB 3 · 5 Gbit/s"
            case .superSpeedPlus:    "USB 3 · 10 Gbit/s"
            case .superSpeedPlusBy2: "USB 3 · 20 Gbit/s"
            }
        }
    }

    let speed: Speed?
    /// Hubs between the Mac and the board, nearest to the Mac first
    /// (e.g. ["USB2 Hub"] when plugged into a Studio Display).
    let hubs: [String]
    /// mA allocated to the device by the host (`UsbPowerSinkAllocation`).
    let allocatedMilliamps: Int?
    /// mA the upstream port can supply (`kUSBWakePortCurrentLimit` on the
    /// parent hub/controller). 500 = USB 2 default, 900 = USB 3, 1500/3000 =
    /// USB-C current advertisement.
    let portLimitMilliamps: Int?

    var pathDescription: String {
        hubs.isEmpty ? "Directly to Mac" : "Via " + hubs.reversed().joined(separator: " → ")
    }

    var powerDescription: String? {
        switch (allocatedMilliamps, portLimitMilliamps) {
        case let (a?, l?): "\(a) mA allocated · port supplies up to \(l) mA"
        case let (a?, nil): "\(a) mA allocated"
        case let (nil, l?): "Port supplies up to \(l) mA"
        default: nil
        }
    }

    /// Reads connection details for the USB device that owns `serialService`.
    static func read(forSerialService serialService: io_object_t) -> USBConnection? {
        guard let device = ancestor(of: serialService, conformingTo: "IOUSBHostDevice") else { return nil }
        defer { IOObjectRelease(device) }

        // Walk further up: every IOUSBHostDevice above the board is a hub; the
        // first parent (hub or root controller) holds the port's current limit.
        var hubs: [String] = []
        var portLimit: Int?
        var current = device
        IOObjectRetain(current)
        while let parent = parent(of: current) {
            IOObjectRelease(current)
            current = parent
            if portLimit == nil, let limit = int(current, "kUSBWakePortCurrentLimit") {
                portLimit = limit
            }
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                hubs.append(string(current, "USB Product Name") ?? "USB hub")
            }
            if IOObjectConformsTo(current, "IOUSBHostController") != 0 { break }
        }
        IOObjectRelease(current)

        return USBConnection(
            speed: int(device, "Device Speed").flatMap(Speed.init(rawValue:)),
            hubs: hubs.reversed(),
            allocatedMilliamps: int(device, "UsbPowerSinkAllocation"),
            portLimitMilliamps: portLimit)
    }

    // MARK: - IOKit helpers (returned objects are +1 retained)

    private static func parent(of entry: io_object_t) -> io_object_t? {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
              parent != 0 else { return nil }
        return parent
    }

    private static func ancestor(of entry: io_object_t, conformingTo className: String) -> io_object_t? {
        var current = entry
        IOObjectRetain(current)
        while let p = parent(of: current) {
            IOObjectRelease(current)
            current = p
            if IOObjectConformsTo(current, className) != 0 { return current }
        }
        IOObjectRelease(current)
        return nil
    }

    private static func int(_ entry: io_object_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }

    private static func string(_ entry: io_object_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
