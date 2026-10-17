import Foundation
import IOKit

/// The Mac's physical port a board is plugged into, and the cable in it.
///
/// Source: the IOPort registry plane (Apple Silicon USB-C port controllers,
/// "AppleHPMInterface…"). It's undocumented but is what System Information
/// reads; property names below were taken from `ioreg -p IOPort -l` on
/// macOS 26/27. Each port has per-transport child nodes (USB2, USB3, …) whose
/// "Metadata" lists the attached device's vendor/product ID and serial number,
/// which is how a board is matched to its port without guessing from
/// controller numbering.
struct MacPort: Equatable {
    let name: String              // "USB-C port 2"
    let negotiatedRate: String?   // "12 Mbps (Full Speed)"
    let cable: Cable

    enum Cable: Equatable {
        /// No e-marker chip answered. Normal for USB 2.0 / 3 A cables, which
        /// aren't required to have one; such cables don't identify themselves.
        case passiveUnmarked
        /// An e-marked cable reported its identity (USB PD "SOP'" discovery).
        case marked(type: String, vendorID: Int, maxAmps: Int?)

        var description: String {
            switch self {
            case .passiveUnmarked:
                return "Passive, no e-marker (USB 2.0 · up to 3 A)"
            case let .marked(type, vendorID, maxAmps):
                var parts = [type, String(format: "e-marker vendor 0x%04X", vendorID)]
                if let maxAmps { parts.append("rated \(maxAmps) A") }
                return parts.joined(separator: " · ")
            }
        }
    }

    /// Finds the Mac port whose USB transport currently carries this device.
    /// Returns nil when the board is behind a hub/display (only the hub is on
    /// the Mac port then) or on Macs without IOPort data.
    static func find(vendorID: Int, productID: Int, serialNumber: String?) -> MacPort? {
        for className in ["IOPortTransportStateUSB2", "IOPortTransportStateUSB3"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let transport = IOIteratorNext(iterator), transport != 0 {
                defer { IOObjectRelease(transport) }
                guard bool(transport, "Active") == true,
                      let meta = property(transport, "Metadata") as? [String: Any],
                      meta["Vendor ID"] as? Int == vendorID,
                      meta["Product ID"] as? Int == productID,
                      serialNumber == nil || meta["Serial Number"] as? String == serialNumber,
                      let port = parentInPortPlane(transport) else { continue }
                defer { IOObjectRelease(port) }
                return MacPort(name: displayName(port),
                               negotiatedRate: property(transport, "DataRateDescription") as? String,
                               cable: cable(of: port))
            }
        }
        return nil
    }

    /// Ports where something is physically attached (USB-C CC line active) but
    /// macOS's accessory security hasn't authorized a data connection. This is
    /// exactly the "board gets power but never shows up" situation; replugging
    /// while the Mac is unlocked lets macOS authorize it.
    static func portsWithBlockedData() -> [String] {
        var result: Set<String> = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateUSB2"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let transport = IOIteratorNext(iterator), transport != 0 {
            defer { IOObjectRelease(transport) }
            guard bool(transport, "Active") != true,
                  property(transport, "AuthorizationStatusDescription") as? String == "Unauthorized",
                  let port = parentInPortPlane(transport) else { continue }
            defer { IOObjectRelease(port) }
            let active = property(port, "TransportsActive") as? [String] ?? []
            if bool(port, "ConnectionActive") == true, active == ["CC"] {
                result.insert(displayName(port))
            }
        }
        return result.sorted()
    }

    // MARK: - Cable

    private static func cable(of port: io_object_t) -> Cable {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(port, "IOPort", IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return .passiveUnmarked }
        defer { IOObjectRelease(iterator) }
        while case let node = IOIteratorNext(iterator), node != 0 {
            defer { IOObjectRelease(node) }
            // "SOP'" = the USB PD message target for the cable's e-marker.
            guard IOObjectConformsTo(node, "IOPortTransportComponentCCUSBPDSOPp") != 0,
                  let meta = property(node, "Metadata") as? [String: Any],
                  let vendorID = meta["Vendor ID"] as? Int else { continue }
            let type = meta["Product Type Description"] as? String ?? "E-marked cable"
            return .marked(type: type, vendorID: vendorID, maxAmps: maxAmps(fromVDOs: meta["VDOs"]))
        }
        return .passiveUnmarked
    }

    /// Decodes the VBUS current rating from the cable VDO (4th VDO of the
    /// Discover Identity response: ID Header, Cert Stat, Product, Cable).
    /// Bits 6:5 — 01 = 3 A, 10 = 5 A (USB PD 3.1 spec, §6.4.4.3.1.6/7).
    /// VDOs arrive as little-endian 4-byte Data, verified by the ID Header's
    /// low 16 bits matching the reported vendor ID.
    private static func maxAmps(fromVDOs raw: Any?) -> Int? {
        guard let vdos = raw as? [Data], vdos.count >= 4, vdos[3].count == 4 else { return nil }
        let cableVDO = vdos[3].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        switch (cableVDO >> 5) & 0b11 {
        case 0b01: return 3
        case 0b10: return 5
        default: return nil
        }
    }

    // MARK: - Helpers

    /// "Port-USB-C@2" → "USB-C port 2". macOS numbers ports but doesn't say
    /// which physical side they're on, so the number is all we can show.
    private static func displayName(_ port: io_object_t) -> String {
        let raw = property(port, "PortDescription") as? String ?? "Port"
        guard raw.hasPrefix("Port-"), let at = raw.lastIndex(of: "@") else { return raw }
        let kind = raw[raw.index(raw.startIndex, offsetBy: 5)..<at]
        return "\(kind) port \(raw[raw.index(after: at)...])"
    }

    private static func parentInPortPlane(_ entry: io_object_t) -> io_object_t? {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(entry, "IOPort", &parent) == KERN_SUCCESS,
              parent != 0 else { return nil }
        return parent
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func bool(_ entry: io_object_t, _ key: String) -> Bool? {
        property(entry, key) as? Bool
    }
}
