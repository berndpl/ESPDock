import Foundation
import Network
import Observation

struct WirelessIdentity: Codable, Equatable, Sendable {
    let version: Int
    let board: String
    let firmware: FirmwareReport
}

enum WirelessError: LocalizedError {
    case invalidAddress, invalidPort, invalidToken, invalidPairing(String), serial(String)
    /// Pairing over USB: the firmware didn't answer (no or an older ESPDock library).
    case noPairingResponse
    /// The library is current but the sketch calls begin() without `true`.
    case wifiLogsDisabled
    /// Wi-Fi logs are on, but the board hasn't joined Wi-Fi yet.
    case boardNotOnWiFi

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Use a private LAN address or a .local hostname."
        case .invalidPort: "Port must be between 1 and 65535."
        case .invalidToken: "The pairing token must contain exactly 32 hexadecimal characters."
        case .invalidPairing(let reason), .serial(let reason): reason
        case .noPairingResponse: "No Wi-Fi pairing response. Update lib/ESPDock and deploy once over USB."
        case .wifiLogsDisabled: "Call ESPDock::begin(true) in setup() and deploy once over USB."
        case .boardNotOnWiFi: "The board is not connected to Wi-Fi yet."
        }
    }
}

enum WirelessProtocol {
    static func boardID(_ text: String) -> String? {
        let upper = text.uppercased()
        guard upper.range(of: #"^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$"#, options: .regularExpression) != nil else { return nil }
        return upper
    }

    static func validate(host: String, port: UInt16, token: String) throws {
        let bytes = IPv4Address(host).map { Array($0.rawValue) }
        let privateIPv4 = bytes.map {
            $0[0] == 10 || $0[0] == 127 || ($0[0] == 192 && $0[1] == 168)
                || ($0[0] == 172 && (16...31).contains($0[1]))
                || ($0[0] == 169 && $0[1] == 254)
        } ?? false
        let localName = host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*\.local$"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
        guard privateIPv4 || localName else { throw WirelessError.invalidAddress }
        guard port > 0 else { throw WirelessError.invalidPort }
        guard token.range(of: #"^[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil else {
            throw WirelessError.invalidToken
        }
    }
}

@MainActor
@Observable
final class WirelessSession {
    enum Status: Equatable {
        case closed, connecting, authenticating, connected
        case failed(String)
    }

    private(set) var status: Status = .closed
    @ObservationIgnored var onIdentity: ((WirelessIdentity) -> Void)?
    @ObservationIgnored var onLine: ((String) -> Void)?
    @ObservationIgnored var onFailure: ((String, Bool) -> Void)?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var expectedBoardID: String?
    @ObservationIgnored private var deadline: Timer?
    @ObservationIgnored private var lastReceived = Date()
    @ObservationIgnored private var startedAt = Date()

    func connect(host: String, port: UInt16, token: String, expectedBoardID: String?) throws {
        try WirelessProtocol.validate(host: host, port: port, token: token)
        disconnect()
        self.expectedBoardID = expectedBoardID?.uppercased()
        status = .connecting
        let generation = self.generation
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.status = .authenticating
                    self.lastReceived = .now
                    connection.send(content: Data("ESPDOCK AUTH \(token.lowercased())\n".utf8),
                                    completion: .contentProcessed { [weak self] error in
                        MainActor.assumeIsolated {
                            guard let self, self.generation == generation, let error else { return }
                            self.fail("Couldn't authenticate the connection: \(error.localizedDescription)", retryable: true)
                        }
                    })
                    self.receive(generation: generation)
                case .waiting(let error), .failed(let error):
                    self.fail("Wi-Fi connection failed: \(error.localizedDescription)", retryable: true)
                default: break
                }
            }
        }
        deadline = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timeout: TimeInterval = self.status == .connected ? 15 : 5
                let activity = self.status == .connected ? self.lastReceived : self.startedAt
                if Date().timeIntervalSince(activity) > timeout {
                    self.fail("The Wi-Fi device stopped responding.", retryable: true)
                }
            }
        }
        lastReceived = .now
        startedAt = .now
        connection.start(queue: .main)
    }

    func disconnect() {
        generation = UUID()
        deadline?.invalidate()
        deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        status = .closed
    }

    private func fail(_ message: String, retryable: Bool) {
        disconnect()
        status = .failed(message)
        onFailure?(message, retryable)
    }

    private func receive(generation: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                if let data, !data.isEmpty {
                    self.lastReceived = .now
                    self.buffer.append(data)
                    self.consumeLines()
                }
                guard self.generation == generation else { return }
                if complete || error != nil {
                    self.fail("The Wi-Fi device disconnected.", retryable: true)
                } else {
                    self.receive(generation: generation)
                }
            }
        }
    }

    private func consumeLines() {
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= 4096 else {
                fail("The Wi-Fi device sent an oversized line.", retryable: false)
                return
            }
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            if line.hasPrefix("ESPDOCK ERROR ") {
                fail("Pairing was rejected. Check the token or pair again over USB.", retryable: false)
                return
            }
            if status == .authenticating {
                guard line.hasPrefix("ESPDOCK HELLO "),
                      let identity = try? JSONDecoder().decode(WirelessIdentity.self, from: Data(line.dropFirst(14).utf8)),
                      identity.version == 1, let boardID = WirelessProtocol.boardID(identity.board) else {
                    fail("The device did not send a supported ESPDock identity.", retryable: false)
                    return
                }
                guard expectedBoardID == nil || expectedBoardID == boardID else {
                    fail("This address belongs to a different board. Pair again over USB.", retryable: false)
                    return
                }
                status = .connected
                onIdentity?(identity)
            } else if status == .connected {
                if line == "ESPDOCK ALIVE" { continue }
                guard !line.hasPrefix("ESPDOCK HELLO ") else {
                    fail("The device changed identity during the session.", retryable: false)
                    return
                }
                onLine?(line)
            }
        }
        if buffer.count > 4096 { fail("The Wi-Fi device sent an oversized line.", retryable: false) }
    }
}
