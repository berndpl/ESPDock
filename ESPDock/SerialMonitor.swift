import Darwin
import Foundation
import Observation

/// Live serial console for the connected board.
///
/// Owns the port while open. Other users of the port cooperate with it:
/// - Build & Deploy calls `suspend()` (esptool needs the port exclusively) and
///   the monitor reconnects by itself once the board reappears;
/// - version queries go through `send("ESPDOCK?")` and the reply is picked out
///   of the stream (`onReport`), instead of opening the port a second time.
///
/// Opened like SerialProbe: no DTR/RTS changes, HUPCL cleared, so attaching
/// never resets the board.
@MainActor
@Observable
final class SerialMonitor {
    struct Line: Identifiable {
        let id: Int
        let time: Date
        let text: String
        let outgoing: Bool

        static let timestampFormat = Date.FormatStyle().hour().minute().second().secondFraction(.fractional(3))

        var displayText: String { outgoing ? "→ \(text)" : text }

        func formatted(showTimestamps: Bool) -> String {
            showTimestamps ? "\(time.formatted(Self.timestampFormat))\t\(displayText)" : displayText
        }
    }

    enum Status: Equatable {
        case closed
        case open(String)            // port
        case wireless(String)        // authenticated, read-only endpoint
        case waiting(String)         // board gone (reset/upload); reconnects automatically
        case failed(String)
    }

    static let baudRates = [9600, 57600, 115200, 230400, 460800, 921600]

    private(set) var lines: [Line] = []
    private(set) var status: Status = .closed
    var baud = 115200 { didSet { if case .open(let p) = status { reopen(p) } } }
    var paused = false
    /// Firmware reports seen in the stream (boot banner or query replies).
    @ObservationIgnored var onReport: ((FirmwareReport) -> Void)?

    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var source: DispatchSourceRead?
    @ObservationIgnored private var partial = Data()
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var wantedPort: String?
    @ObservationIgnored private var wirelessEndpoint: String?
    @ObservationIgnored private var pairingReply: CheckedContinuation<WirelessPairingReply, Error>?
    @ObservationIgnored private var pairingTimer: Timer?
    @ObservationIgnored private var suspended = false
    /// While waiting for the board to come back, try to reattach once a second
    /// (cheap: one failed open() on a missing path). Covers presses of RESET,
    /// which reset the board without ESPDock seeing a disconnect.
    @ObservationIgnored private var retryTimer: Timer?
    /// Keeps memory bounded; older lines scroll away.
    private let maxLines = 5000

    var isActive: Bool { wantedPort != nil || wirelessEndpoint != nil }
    var isWireless: Bool { wirelessEndpoint != nil }

    // MARK: Lifecycle

    func start(port: String) {
        guard port.hasPrefix("/dev/cu.") || port.hasPrefix("/dev/tty.") else {
            status = .failed("A USB serial port is required.")
            return
        }
        wirelessEndpoint = nil
        wantedPort = port
        suspended = false
        open(port)
    }

    func stop() {
        finishPairing(.failure(WirelessError.serial("USB pairing was interrupted.")))
        retryTimer?.invalidate()
        wantedPort = nil
        wirelessEndpoint = nil
        close()
        status = .closed
    }

    /// Release the port (for an upload) but remember to come back.
    func suspend() {
        guard wantedPort != nil else { return }
        suspended = true
        close()
        if let p = wantedPort { status = .waiting(p) }
    }

    /// Called by the app when the board (re)appears — after an upload's reset,
    /// or a replug. Reattaches if the monitor is meant to be open.
    func boardAvailable(port: String) {
        guard wantedPort != nil else { return }
        wantedPort = port
        suspended = false
        if fd < 0 { scheduleRetry() }
    }

    func boardGone() {
        if let endpoint = wirelessEndpoint {
            status = .waiting(endpoint)
            return
        }
        guard let p = wantedPort else { return }
        close()
        status = .waiting(p)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let port = self.wantedPort, !self.suspended else { return }
                if self.fd >= 0 { self.retryTimer?.invalidate(); return }
                if FileManager.default.fileExists(atPath: port) {
                    self.open(port)
                    if self.fd >= 0 { self.retryTimer?.invalidate() }
                }
            }
        }
    }

    func clear() { lines.removeAll() }

    func outputText(showTimestamps: Bool) -> String {
        lines.map { $0.formatted(showTimestamps: showTimestamps) }.joined(separator: "\n")
    }

    func startWireless(endpoint: String) {
        stop()
        wirelessEndpoint = endpoint
        status = .wireless(endpoint)
    }

    func receiveWireless(_ text: String) {
        guard wirelessEndpoint != nil else { return }
        consumeLine(text)
    }

    func requestPairing(port: String) async throws -> WirelessPairingReply {
        guard pairingReply == nil else { throw WirelessError.serial("A pairing request is already running.") }
        let temporary = !isActive
        if temporary { start(port: port) }
        defer { if temporary { stop() } }
        guard status == .open(port), !suspended else {
            throw WirelessError.serial("The USB monitor is unavailable. Finish the upload or reconnect the board.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pairingReply = continuation
            pairingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishPairing(.failure(WirelessError.noPairingResponse))
                }
            }
            let bytes = Array("\nESPDOCK WIFI?\n".utf8)
            let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if written != bytes.count {
                finishPairing(.failure(WirelessError.serial("Couldn't send the USB pairing request. Reconnect and try again.")))
            }
        }
    }

    private func finishPairing(_ result: Result<WirelessPairingReply, Error>) {
        pairingTimer?.invalidate()
        pairingTimer = nil
        let continuation = pairingReply
        pairingReply = nil
        continuation?.resume(with: result)
    }

    func send(_ text: String, echo: Bool = true) {
        guard fd >= 0 else { return }
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if echo { append(text, outgoing: true) }
    }

    // MARK: Port

    private func open(_ port: String) {
        close()
        let handle = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            status = .failed("Can't open \(port) (\(String(cString: strerror(errno))))")
            return
        }
        var t = termios()
        tcgetattr(handle, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)
        tcsetattr(handle, TCSANOW, &t)
        fd = handle

        let src = DispatchSource.makeReadSource(fileDescriptor: handle, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        src.setCancelHandler { Darwin.close(handle) }
        src.resume()
        source = src
        status = .open(port)
    }

    private func reopen(_ port: String) {
        open(port)
    }

    private func close() {
        finishPairing(.failure(WirelessError.serial("The USB connection closed during pairing.")))
        source?.cancel()      // closes the fd in its cancel handler
        source = nil
        fd = -1
        partial.removeAll()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 {
            // EOF/error: the device went away (reset, unplug).
            if n == 0 || (errno != EAGAIN && errno != EINTR) { boardGone() }
            return
        }
        partial.append(contentsOf: buffer[0..<n])
        while let nl = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            let text = String(decoding: lineData, as: UTF8.self)
            consumeLine(text)
        }
    }

    private func consumeLine(_ text: String) {
        if let prefix = text.range(of: "ESPDOCK WIFI ") {
            // A reply can follow another task's unfinished log line.
            finishPairing(Result { try WirelessPairingReply.decode(Data(text[prefix.upperBound...].utf8)) })
            return
        }
        if text.hasPrefix("ESPDOCK {"), let report = SerialProbe.parse(Data(text.utf8)) {
            onReport?(report)
        }
        if !paused { append(text, outgoing: false) }
    }

    private func append(_ text: String, outgoing: Bool) {
        lines.append(Line(id: nextID, time: .now, text: text, outgoing: outgoing))
        nextID += 1
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
