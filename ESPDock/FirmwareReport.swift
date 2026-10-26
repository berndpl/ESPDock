import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation

/// What the firmware says about itself (ESPDock firmware library, see
/// FirmwareLib/ESPDock). `source` is the combined CodeFingerprint hash of the
/// code it was built from.
struct FirmwareReport: Codable, Equatable, Sendable {
    let project: String
    let env: String
    let commit: String
    let built: String
    let source: String
    let uptime: UInt64?

    var builtDate: Date? { ISO8601DateFormatter().date(from: built) }
}

extension CodeFingerprint {
    /// Single hash over a manifest — identical to espdock_version.py's
    /// source_hash(): SHA-256 of sorted "path:hash" lines joined by "\n".
    static func combined(_ manifest: [String: String]) -> String {
        let lines = manifest.keys.sorted().map { "\($0):\(manifest[$0]!)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Asks the board "ESPDOCK?" over its serial port and parses the answer.
///
/// The port is opened without touching DTR/RTS and with HUPCL cleared, so
/// opening/closing doesn't reset an ESP32-S3 on native USB (its reset is
/// triggered by a specific DTR/RTS sequence, which we never send).
enum SerialProbe {
    static func query(port: String, timeout: TimeInterval = 2.0) -> FirmwareReport? {
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return nil }
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIFLUSH)

        // Leading newline terminates any partial line the firmware buffered.
        let query = Array("\nESPDOCK?\n".utf8)
        _ = query.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if let report = parse(buffer) { return report }
            } else {
                usleep(20_000)
            }
        }
        return nil
    }

    /// Finds the last complete "ESPDOCK {…}" line in the received bytes.
    static func parse(_ data: Data) -> FirmwareReport? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let start = line.range(of: "ESPDOCK {") else { continue }
            let json = line[line.index(before: start.upperBound)...]
            if let report = try? JSONDecoder().decode(FirmwareReport.self, from: Data(json.utf8)) {
                return report
            }
        }
        return nil
    }
}

/// Holds the latest report per board and runs probes.
@MainActor
@Observable
final class FirmwareProbe {
    enum State: Equatable {
        case unknown                // not asked yet
        case probing
        case reported(FirmwareReport)
        case noAnswer               // firmware without the ESPDock library
    }

    private(set) var states: [String: State] = [:]   // by MAC
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastReceived: [String: Date] = [:]

    func state(for board: Board) -> State {
        board.macAddress.flatMap { states[$0] } ?? .unknown
    }

    func report(for board: Board) -> FirmwareReport? {
        if case let .reported(r) = state(for: board) { return r }
        return nil
    }

    /// Probe after `delay` (the board needs ~1 s after reset/connect before
    /// its USB serial answers).
    /// When the serial monitor holds the port, queries go through it.
    @ObservationIgnored weak var monitor: SerialMonitor?

    /// A report seen in the monitor's stream (boot banner or query reply).
    func receive(_ report: FirmwareReport, mac: String?) {
        guard let mac else { return }
        states[mac] = .reported(report)
        lastReceived[mac] = .now
    }

    func probe(_ board: Board, after delay: Duration = .seconds(1.5)) {
        guard board.transport == .usb, let mac = board.macAddress, !inFlight.contains(mac) else { return }
        inFlight.insert(mac)
        if states[mac] == nil || states[mac] == .noAnswer { states[mac] = .probing }
        let port = board.port
        let started = Date()
        Task {
            try? await Task.sleep(for: delay)
            if let received = lastReceived[mac], received > started {
                inFlight.remove(mac)
                return
            }
            if let monitor, case .open = monitor.status {
                // Ask through the open monitor; the reply arrives via receive().
                lastReceived[mac] = nil
                monitor.send("ESPDOCK?", echo: false)
                try? await Task.sleep(for: .seconds(2))
                inFlight.remove(mac)
                if lastReceived[mac] == nil { states[mac] = .noAnswer }
                return
            }
            let report = await Task.detached(priority: .utility) {
                // Two tries: the first can land while the sketch is still booting.
                SerialProbe.query(port: port) ?? SerialProbe.query(port: port)
            }.value
            inFlight.remove(mac)
            if let received = lastReceived[mac], received > started { return }
            states[mac] = report.map(State.reported) ?? .noAnswer
        }
    }
}

/// Adds the ESPDock firmware library to a PlatformIO project: copies
/// lib/ESPDock and registers its pre-build script in the env's extra_scripts.
/// Source code is not edited — the user adds the two lines themselves.
enum VersionReportingInstaller {
    static let scriptEntry = "pre:lib/ESPDock/espdock_version.py"
    static let snippet = "#include <ESPDock.h>\n\n// in setup(), after Serial.begin(...):\nESPDock::begin();"

    static var bundledLibrary: URL? {
        Bundle.main.url(forResource: "ESPDock", withExtension: nil, subdirectory: "FirmwareLib")
    }

    static func isInstalled(projectAt root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/ESPDock/espdock_version.py").path)
    }

    static func install(projectAt root: URL, environment: String) throws {
        guard let source = bundledLibrary else {
            throw NSError(domain: "ESPDock", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Firmware library missing from the app bundle."])
        }
        let fm = FileManager.default
        let dest = root.appendingPathComponent("lib/ESPDock")
        try fm.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)

        let iniURL = root.appendingPathComponent("platformio.ini")
        let ini = try String(contentsOf: iniURL, encoding: .utf8)
        try patch(ini, environment: environment).write(to: iniURL, atomically: true, encoding: .utf8)
    }

    /// Adds the script to `[env:NAME]`: appended to an existing single-line
    /// `extra_scripts`, otherwise inserted as a new key at the end of the
    /// section. Idempotent.
    static func patch(_ ini: String, environment: String) -> String {
        guard !ini.contains(scriptEntry) else { return ini }
        var lines = ini.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[env:\(environment)]"
        }) else { return ini }
        var end = lines.count
        for i in (header + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = i; break
        }
        if let existing = (header + 1..<end).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("extra_scripts")
        }) {
            lines[existing] += ", \(scriptEntry)"
        } else {
            // Insert after the section's last non-blank line.
            var insertAt = end
            while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert("; ESPDock: stamps project/commit/build time/source hash into the firmware", at: insertAt)
            lines.insert("extra_scripts = \(scriptEntry)", at: insertAt + 1)
        }
        return lines.joined(separator: "\n")
    }
}
