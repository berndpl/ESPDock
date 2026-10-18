import Foundation
import IOKit
import IOKit.serial
import Observation

/// An ESP32 reached over USB or an authenticated, paired Wi-Fi session.
struct Board: Equatable, Identifiable {
    enum Transport: Equatable { case usb, wifi }
    var id: String { port }
    let port: String          // e.g. /dev/cu.usbmodem1101
    let vendorID: Int
    let productID: Int
    let serialNumber: String? // ESP32 native USB reports the MAC address here
    let usbProductName: String?
    let usbVendorName: String?
    let connection: USBConnection?
    /// Mac port + cable; nil when behind a hub or not determinable.
    var macPort: MacPort?
    var transport: Transport = .usb
    var pairedBoardID: String?

    var supportsUpload: Bool { transport == .usb }

    static func wireless(host: String, port: UInt16, boardID: String) -> Board {
        Board(port: "\(host):\(port)", vendorID: 0, productID: 0,
              serialNumber: nil, usbProductName: nil, usbVendorName: nil,
              connection: nil, transport: .wifi, pairedBoardID: boardID)
    }

    static func preferred(usb: Board?, wireless: Board?) -> Board? { usb ?? wireless }

    var vidPid: String { String(format: "%04X:%04X", vendorID, productID) }

    /// Espressif's own USB vendor ID: the board itself speaks USB (S2/S3/C3/C6…),
    /// so this is certainly an ESP32. Bridge chips are only a strong hint.
    var isCertainlyESP32: Bool { transport == .wifi || vendorID == BoardMonitor.espressifVendorID }

    /// Human-readable description of the USB interface, from a small table of
    /// the IDs seen on common ESP32 dev boards (checked against the USB ID
    /// repository at http://www.linux-usb.org/usb.ids).
    var interfaceDescription: String {
        switch (vendorID, productID) {
        case (0x303A, 0x1001): return "ESP32 native USB (JTAG/serial) — S3, C3, C6, H2"
        case (0x303A, 0x0002): return "ESP32-S2 native USB (CDC)"
        case (0x303A, _):      return "Espressif native USB"
        case (0x10C4, 0xEA60): return "Silicon Labs CP210x USB-UART bridge"
        case (0x1A86, 0x7523): return "WCH CH340 USB-UART bridge"
        case (0x1A86, 0x55D4): return "WCH CH9102 USB-UART bridge"
        case (0x0403, _):      return "FTDI USB-UART bridge"
        default:               return usbProductName ?? "USB serial device"
        }
    }

    /// On ESP32 native USB the serial number is the factory MAC address
    /// ("AA:BB:CC:DD:EE:FF"), which uniquely identifies the board. Used later to
    /// remember which project belongs to which board.
    var macAddress: String? {
        if transport == .wifi { return pairedBoardID }
        guard isCertainlyESP32, let s = serialNumber,
              s.split(separator: ":").count == 6 else { return nil }
        return s
    }
}

/// Watches USB serial ports and publishes the first ESP32-looking board.
///
/// Uses IOKit add/remove notifications instead of polling `pio device list`:
/// PlatformIO's CLI starts a Python interpreter (~0.5 s CPU) per call and would
/// still lag behind plug events, whereas IOKit notifies instantly and costs
/// nothing while idle. On every event we simply rescan all serial ports — there
/// are only a handful, so a full rescan is cheaper than tracking deltas.
@MainActor
@Observable
final class BoardMonitor {
    typealias Snapshot = (boards: [Board], otherPorts: [String])
    nonisolated static let espressifVendorID = 0x303A

    /// Vendor IDs considered ESP32 candidates: Espressif native USB plus the
    /// USB-UART bridge chips used on most classic ESP32 dev boards.
    private static let candidateVendorIDs: Set<Int> = [
        espressifVendorID,
        0x10C4, // Silicon Labs CP210x
        0x1A86, // WCH CH340 / CH9102
        0x0403, // FTDI
    ]

    private(set) var board: Board?
    /// When the current board appeared (or disappeared, if `board` is nil).
    private(set) var since: Date = .now
    /// Other serial ports, shown so it's clear the app *sees* USB devices even
    /// when none is an ESP32.
    private(set) var otherPorts: [String] = []
    /// Mac ports with something attached whose data connection macOS hasn't
    /// authorized (see MacPort.portsWithBlockedData).
    private(set) var blockedPorts: [String] = []
    /// Called when a board appears after none was connected (not for a board
    /// already present at launch, since it's set after init's first scan).
    @ObservationIgnored var onBoardConnected: ((Board) -> Void)?
    /// Called once a disconnect is real (after the post-upload grace period).
    @ObservationIgnored var onBoardDisconnected: (() -> Void)?
    @ObservationIgnored private var disconnectPending: Task<Void, Never>?
    @ObservationIgnored private var disconnectDeadline: ContinuousClock.Instant?
    @ObservationIgnored private let scan: @MainActor () -> Snapshot?

    // nonisolated so deinit can release them; otherwise only touched on the main run loop.
    @ObservationIgnored nonisolated(unsafe) private var notifyPort: IONotificationPortRef?
    @ObservationIgnored nonisolated(unsafe) private var addedIterator: io_iterator_t = 0
    @ObservationIgnored nonisolated(unsafe) private var removedIterator: io_iterator_t = 0
    /// Polls only the cheap IORegistry port state, and only while no board is
    /// connected: a blocked accessory never creates a serial port, so the
    /// serial notifications above can't tell us about it. No process spawns.
    @ObservationIgnored nonisolated(unsafe) private var blockedPortTimer: Timer?

    init(scan: (@MainActor () -> Snapshot?)? = nil) {
        self.scan = scan ?? Self.scanPorts
        startWatching()
        rescan()
        blockedPortTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.board == nil else { return }
                let blocked = MacPort.portsWithBlockedData()
                if blocked != self.blockedPorts { self.blockedPorts = blocked }
            }
        }
    }

    deinit {
        blockedPortTimer?.invalidate()
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    // MARK: - IOKit notifications

    private func startWatching() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        // Deliver callbacks on the main run loop, so they run on the main actor.
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            BoardMonitor.drain(iterator)
            let monitor = Unmanaged<BoardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.rescan() }
        }

        // Each call consumes its matching dictionary, so create one per call.
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                         IOServiceMatching(kIOSerialBSDServiceValue),
                                         callback, context, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                         IOServiceMatching(kIOSerialBSDServiceValue),
                                         callback, context, &removedIterator)
        // Iterators must be drained once to arm the notifications.
        Self.drain(addedIterator)
        Self.drain(removedIterator)
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    // MARK: - Scanning

    #if DEBUG
    private static let auditNoBoard = CommandLine.arguments.contains("-auditNoBoard")
    #endif

    private static func scanPorts() -> Snapshot? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(kIOSerialBSDServiceValue),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var found: [Board] = []
        var others: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            #if DEBUG
            // Audit hook: `-auditNoBoard` hides every port, so the empty state
            // can be captured without unplugging the board.
            if Self.auditNoBoard { continue }
            #endif
            guard let path = Self.property(service, kIOCalloutDeviceKey) as? String else { continue }
            guard let vid = Self.usbProperty(service, "idVendor") as? Int,
                  let pid = Self.usbProperty(service, "idProduct") as? Int,
                  Self.candidateVendorIDs.contains(vid) else {
                others.append(path)
                continue
            }
            var candidate = Board(
                port: path, vendorID: vid, productID: pid,
                serialNumber: Self.usbProperty(service, "USB Serial Number") as? String
                    ?? Self.usbProperty(service, "kUSBSerialNumberString") as? String,
                usbProductName: Self.usbProperty(service, "USB Product Name") as? String
                    ?? Self.usbProperty(service, "kUSBProductString") as? String,
                usbVendorName: Self.usbProperty(service, "USB Vendor Name") as? String
                    ?? Self.usbProperty(service, "kUSBVendorString") as? String,
                connection: USBConnection.read(forSerialService: service))
            candidate.macPort = MacPort.find(vendorID: vid, productID: pid,
                                             serialNumber: candidate.serialNumber)
            found.append(candidate)
        }
        return (found, others)
    }

    func rescan() {
        guard let (found, others) = scan() else { return }
        // One board at a time (PRD non-goal): prefer a certain ESP32 over a bridge.
        let newBoard = found.sorted { $0.isCertainlyESP32 && !$1.isCertainlyESP32 }.first
        // Grace period: an upload ends with a hard reset that drops USB for
        // ~0.5 s. Only treat a disconnect as real if it lasts 2 s, so the
        // window doesn't flash "No board" (and lose the deploy UI) mid-upload.
        if newBoard == nil, board != nil {
            if disconnectPending == nil {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                disconnectDeadline = deadline
                disconnectPending = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard let self, !Task.isCancelled else { return }
                    self.rescan()
                }
            }
            if let deadline = disconnectDeadline, ContinuousClock.now < deadline {
                otherPorts = others.sorted()
                return
            }
        }
        disconnectPending?.cancel()
        disconnectPending = nil
        disconnectDeadline = nil

        if newBoard != board {
            let wasConnected = board != nil
            board = newBoard
            since = .now
            if !wasConnected, let newBoard { onBoardConnected?(newBoard) }
            if wasConnected, newBoard == nil { onBoardDisconnected?() }
        }
        otherPorts = others.sorted()
        blockedPorts = newBoard == nil ? MacPort.portsWithBlockedData() : []
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// USB descriptor properties live on the USB device node, several levels
    /// above the serial port node, so search up through the parents.
    private static func usbProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                        kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}
