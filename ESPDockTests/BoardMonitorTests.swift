import XCTest
@testable import ESPDock

@MainActor
final class BoardMonitorTests: XCTestCase {
    private let usb = Board(port: "/dev/cu.usbmodem-test", vendorID: 0x303A, productID: 0x1001,
                            serialNumber: "AA:BB:CC:DD:EE:FF", usbProductName: nil,
                            usbVendorName: nil, connection: nil)

    func testUnplugClearsConnectedBoardAfterUploadGracePeriod() async throws {
        let usb = self.usb
        let ports = PortSnapshot(boards: [usb])
        let monitor = BoardMonitor(scan: { ports.value })
        XCTAssertEqual(monitor.board, usb)

        ports.boards = []
        monitor.rescan()
        XCTAssertEqual(monitor.board, usb, "Keep the device briefly during firmware resets.")
        try await Task.sleep(for: .milliseconds(2200))

        XCTAssertNil(monitor.board, "A real unplug must not remain connected indefinitely.")
        XCTAssertNil(Board.preferred(usb: monitor.board, wireless: nil))
        let wifi = Board.wireless(host: "192.168.1.20", port: 3232, boardID: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(Board.preferred(usb: monitor.board, wireless: wifi), wifi)
    }

    func testRepeatedRemovalNotificationsDoNotShortenOrRestartGrace() async throws {
        let ports = PortSnapshot(boards: [usb])
        let monitor = BoardMonitor(scan: { ports.value })
        ports.boards = []
        monitor.rescan()
        try await Task.sleep(for: .seconds(1))
        monitor.rescan()
        XCTAssertEqual(monitor.board, usb, "Duplicate removal events must still allow a short reset.")

        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNil(monitor.board, "Duplicate events must not restart the original deadline.")
    }

    func testFirmwareResetCancelsGraceAndNextUnplugGetsAFreshDeadline() async throws {
        let ports = PortSnapshot(boards: [usb])
        let monitor = BoardMonitor(scan: { ports.value })
        let since = monitor.since
        var newConnections = 0
        monitor.onBoardConnected = { _ in newConnections += 1 }

        ports.boards = []
        monitor.rescan()
        try await Task.sleep(for: .milliseconds(100))
        ports.boards = [usb]
        monitor.rescan()
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(monitor.board, usb)
        XCTAssertEqual(monitor.since, since)
        XCTAssertEqual(newConnections, 0)

        ports.boards = []
        monitor.rescan()
        XCTAssertEqual(monitor.board, usb, "A later unplug must get its own grace period.")
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertNil(monitor.board)
    }

    @MainActor
    private final class PortSnapshot {
        var boards: [Board]
        var value: BoardMonitor.Snapshot { (boards, []) }

        init(boards: [Board]) { self.boards = boards }
    }
}
