import AppKit
import XCTest
@testable import ESPDock

@MainActor
final class SerialMonitorOutputTests: XCTestCase {
    func testCopyWritesAllBufferedOutputWithoutPairingSecrets() {
        let monitor = SerialMonitor()
        monitor.startWireless(endpoint: "192.168.1.20:3232")
        defer { monitor.stop() }
        monitor.receiveWireless("Playing caf\u{00e9}")
        monitor.receiveWireless("ESPDOCK WIFI {\"token\":\"fixture-secret\"}")
        monitor.receiveWireless("Volume: 12/21")
        let pasteboard = NSPasteboard(name: .init("ESPDockTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Previous clipboard content", forType: .string)

        XCTAssertTrue(SerialMonitorView(monitor: monitor).copyOutput(showTimestamps: false, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Playing caf\u{00e9}\nVolume: 12/21")
        XCTAssertEqual(monitor.lines.count, 2)
    }

    func testCopyRespectsTimestampSettingAndWorksAfterDisconnect() throws {
        let monitor = SerialMonitor()
        monitor.startWireless(endpoint: "192.168.1.20:3232")
        monitor.receiveWireless("Playing")
        monitor.stop()
        let line = try XCTUnwrap(monitor.lines.first)
        let pasteboard = NSPasteboard(name: .init("ESPDockTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(SerialMonitorView(monitor: monitor).copyOutput(showTimestamps: true, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(line.time.formatted(SerialMonitor.Line.timestampFormat))\tPlaying")
        monitor.clear()
        XCTAssertEqual(monitor.outputText(showTimestamps: true), "")
    }

    func testOutgoingCommandsKeepTheirDirectionMarker() {
        let line = SerialMonitor.Line(id: 0, time: Date(timeIntervalSince1970: 0),
                                      text: "ESPDOCK?", outgoing: true)
        XCTAssertEqual(line.formatted(showTimestamps: false), "\u{2192} ESPDOCK?")
        XCTAssertEqual(line.formatted(showTimestamps: true),
                       "\(line.time.formatted(SerialMonitor.Line.timestampFormat))\t\u{2192} ESPDOCK?")
    }
}
