import Network
import Synchronization
import XCTest
@testable import ESPDock

@MainActor
final class WirelessSessionTests: XCTestCase {
    func testAutomaticReconnectDoesNotRequestKeychainConsent() throws {
        let store = TestWirelessCredentials()
        let suite = "ESPDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = WirelessPairing(id: "test-pairing", host: "127.0.0.1", port: 3232,
                                      boardID: "AA:BB:CC:DD:EE:FF", localBoardID: "USB-ID")
        defaults.set(try JSONEncoder().encode(pairing), forKey: "wirelessPairing")
        let controller = WirelessController(defaults: defaults, credentials: store)
        defer { controller.disconnect() }
        controller.resume()
        XCTAssertEqual(store.readCount, 0)
        XCTAssertTrue(controller.requiresKeychainAuthorization)
        XCTAssertNotNil(controller.error)
        XCTAssertNil(controller.board)
        XCTAssertFalse(controller.waitingForKeychain)
        XCTAssertEqual(controller.session.status, .closed)
    }

    func testAuthorizedTokenIsReusedAfterTransientNetworkLoss() async throws {
        let peer = try WirelessTestPeer()
        try await peer.start()
        defer { peer.stop() }
        let store = TestWirelessCredentials()
        let suite = "ESPDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = WirelessPairing(id: "test-pairing", host: "127.0.0.1", port: peer.port,
                                      boardID: "AA:BB:CC:DD:EE:FF", localBoardID: "USB-ID")
        defaults.set(try JSONEncoder().encode(pairing), forKey: "wirelessPairing")
        let controller = WirelessController(defaults: defaults, credentials: store)
        defer { controller.disconnect() }
        let connected = expectation(description: "First authenticated connection")
        controller.onConnected = { connected.fulfill() }
        controller.resume(allowKeychainPrompt: true)
        await fulfillment(of: [connected], timeout: 3)
        let reconnected = expectation(description: "Automatic reconnect with the already-authorized token")
        controller.onConnected = { reconnected.fulfill() }
        peer.connection?.cancel()
        await fulfillment(of: [reconnected], timeout: 6)
        XCTAssertEqual(store.readCount, 1, "Transient retries must not read Keychain again.")
        XCTAssertEqual(controller.board?.macAddress, "USB-ID")
    }

    func testExplicitConsentIsReusedUntilPairingIsForgotten() async throws {
        let peer = try WirelessTestPeer()
        try await peer.start()
        defer { peer.stop() }
        let store = TestWirelessCredentials()
        let suite = "ESPDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = WirelessPairing(id: "test-pairing", host: "127.0.0.1", port: peer.port,
                                      boardID: "AA:BB:CC:DD:EE:FF", localBoardID: "USB-ID")
        defaults.set(try JSONEncoder().encode(pairing), forKey: "wirelessPairing")
        let controller = WirelessController(defaults: defaults, credentials: store)
        defer { controller.disconnect() }
        controller.resume()
        XCTAssertTrue(controller.requiresKeychainAuthorization)
        let connected = expectation(description: "Explicit authorization connects")
        controller.onConnected = { connected.fulfill() }
        controller.resume(allowKeychainPrompt: true)
        await fulfillment(of: [connected], timeout: 3)
        XCTAssertFalse(controller.requiresKeychainAuthorization)
        controller.disconnect()
        let reconnected = expectation(description: "Manual reconnect reuses the authorized token")
        controller.onConnected = { reconnected.fulfill() }
        controller.resume()
        await fulfillment(of: [reconnected], timeout: 3)
        XCTAssertEqual(store.readCount, 1)
        try controller.forget()
        XCTAssertNil(controller.pairing)
        XCTAssertNil(defaults.data(forKey: "wirelessPairing"))
        controller.resume(allowKeychainPrompt: true)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertNil(controller.board)
    }

    func testWirelessDeploymentIsRejectedBeforeTakingAnyPort() {
        let deployer = Deployer()
        var tookPort = false
        deployer.willUsePort = { tookPort = true }
        let board = Board.wireless(host: "192.168.1.20", port: 3232, boardID: "AA:BB:CC:DD:EE:FF")
        let missingProject = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        deployer.deploy(ProjectLink(path: missingProject.path, environment: "radio"), to: board) {
            XCTFail("A network-only board must never be uploaded to.")
        }
        XCTAssertEqual(deployer.phase, .failed("Connect the board over USB to deploy. Wi-Fi monitoring is read-only."))
        XCTAssertFalse(tookPort)
        XCTAssertFalse(deployer.isRunning)
    }

    private final class TestWirelessCredentials: WirelessCredentials {
        private struct State {
            var readCount = 0
        }
        private let state = Mutex(State())
        var readCount: Int { state.withLock { $0.readCount } }

        func token(id: String) throws -> String {
            state.withLock { $0.readCount += 1 }
            return "00112233445566778899aabbccddeeff"
        }

        func save(_ token: String, id: String) throws {}
        func remove(id: String) throws {}
    }

    func testUSBIsPreferredWithoutDuplicatingThePairedDevice() {
        let usb = Board(port: "/dev/cu.usbmodem1", vendorID: 0x303A, productID: 0x1001,
                        serialNumber: "AA:BB:CC:DD:EE:FF", usbProductName: nil,
                        usbVendorName: nil, connection: nil)
        let wifi = Board.wireless(host: "192.168.1.20", port: 3232, boardID: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(Board.preferred(usb: usb, wireless: wifi), usb)
        XCTAssertEqual(Board.preferred(usb: nil, wireless: wifi)?.macAddress, usb.macAddress)
        XCTAssertNil(wifi.connection)
        XCTAssertNil(wifi.macPort)
        XCTAssertFalse(wifi.supportsUpload)
    }

    func testAuthenticatedSessionDeliversIdentityAndLogs() async throws {
        let peer = try WirelessTestPeer()
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let identity = expectation(description: "Authenticated firmware identity")
        let log = expectation(description: "Wireless log line")
        session.onIdentity = { value in
            XCTAssertEqual(value.board, "AA:BB:CC:DD:EE:FF")
            XCTAssertEqual(value.firmware.project, "radio")
            identity.fulfill()
        }
        session.onLine = { line in
            XCTAssertEqual(line, "Playing | Volume: 12/21")
            log.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: "AA:BB:CC:DD:EE:FF")
        await fulfillment(of: [identity, log], timeout: 3)
        XCTAssertEqual(session.status, .connected)
        XCTAssertEqual(peer.received, "ESPDOCK AUTH \(WirelessTestPeer.token)\n")
    }

    func testRejectedPairingNeverPublishesIdentityOrLogs() async throws {
        let peer = try WirelessTestPeer()
        peer.reply = "ESPDOCK ERROR unauthorized\n"
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let rejected = expectation(description: "Pairing rejected without automatic retry")
        session.onIdentity = { _ in XCTFail("Rejected pairing must not expose a device.") }
        session.onLine = { _ in XCTFail("Rejected pairing must not expose logs.") }
        session.onFailure = { _, retryable in
            XCTAssertFalse(retryable)
            rejected.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port,
                            token: String(repeating: "f", count: 32), expectedBoardID: nil)
        await fulfillment(of: [rejected], timeout: 3)
        guard case .failed = session.status else { return XCTFail("Pairing should fail.") }
    }

    func testChangedBoardAtRememberedAddressIsRejected() async throws {
        let peer = try WirelessTestPeer()
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let rejected = expectation(description: "Different board rejected")
        session.onIdentity = { _ in XCTFail("A different board must never inherit the pairing.") }
        session.onLine = { _ in XCTFail("Logs must wait for a matching identity.") }
        session.onFailure = { _, retryable in
            XCTAssertFalse(retryable)
            rejected.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: "11:22:33:44:55:66")
        await fulfillment(of: [rejected], timeout: 3)
    }

    func testOversizedInputDisconnectsWithoutDeliveringAnUnboundedLine() async throws {
        let peer = try WirelessTestPeer()
        peer.reply = WirelessTestPeer.hello + String(repeating: "x", count: 4097)
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let rejected = expectation(description: "Oversized stream rejected")
        session.onLine = { _ in XCTFail("An oversized line must not reach the monitor.") }
        session.onFailure = { _, retryable in
            XCTAssertFalse(retryable)
            rejected.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: nil)
        await fulfillment(of: [rejected], timeout: 3)
    }

    func testFragmentedUTF8AndHeartbeatPreserveLogLines() async throws {
        let peer = try WirelessTestPeer()
        let payload = Data((WirelessTestPeer.hello + "ESPDOCK ALIVE\nPlaying café 🎵\r\n").utf8)
        peer.fragments = payload.map { Data([$0]) }
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let line = expectation(description: "Complete UTF-8 line, without protocol heartbeats")
        session.onLine = { text in
            XCTAssertEqual(text, "Playing café 🎵")
            line.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: nil)
        await fulfillment(of: [line], timeout: 5)
    }

    func testSessionCanReconnectAfterConnectionLoss() async throws {
        let peer = try WirelessTestPeer()
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let first = expectation(description: "First connection authenticated")
        let disconnected = expectation(description: "Connection loss reported")
        let second = expectation(description: "New connection authenticated")
        var identities = 0
        session.onIdentity = { _ in
            identities += 1
            if identities == 1 { first.fulfill() }
            else { second.fulfill() }
        }
        session.onFailure = { _, retryable in
            XCTAssertTrue(retryable)
            disconnected.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: nil)
        await fulfillment(of: [first], timeout: 3)
        peer.connection?.cancel()
        await fulfillment(of: [disconnected], timeout: 3)
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: "AA:BB:CC:DD:EE:FF")
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(session.status, .connected)
        session.disconnect()
        XCTAssertEqual(session.status, .closed)
    }

    func testOnlyLANAddressesAndValidTokensCanConnect() {
        let session = WirelessSession()
        XCTAssertThrowsError(try session.connect(host: "8.8.8.8", port: 3232,
                                                token: WirelessTestPeer.token, expectedBoardID: nil))
        XCTAssertThrowsError(try session.connect(host: "radio.local", port: 0,
                                                token: WirelessTestPeer.token, expectedBoardID: nil))
        XCTAssertThrowsError(try session.connect(host: "192.168.1.20", port: 3232,
                                                token: "not-a-token\n", expectedBoardID: nil))
        XCTAssertEqual(session.status, .closed)
    }

    func testSilentPeerTimesOutBeforeExposingADevice() async throws {
        let peer = try WirelessTestPeer()
        peer.reply = ""
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let timeout = expectation(description: "Silent peer times out")
        session.onIdentity = { _ in XCTFail("A silent peer cannot identify a board.") }
        session.onFailure = { _, retryable in
            XCTAssertTrue(retryable)
            timeout.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: nil)
        await fulfillment(of: [timeout], timeout: 8)
    }

    func testIdentityDeadlineCannotBeExtendedByPartialInput() async throws {
        let peer = try WirelessTestPeer()
        peer.fragments = Array(repeating: Data("E".utf8), count: 12)
        peer.fragmentDelay = .seconds(1)
        try await peer.start()
        defer { peer.stop() }
        let session = WirelessSession()
        defer { session.disconnect() }
        let timeout = expectation(description: "Partial input cannot keep authentication pending")
        session.onIdentity = { _ in XCTFail("A partial greeting is not an identity.") }
        session.onFailure = { _, retryable in
            XCTAssertTrue(retryable)
            timeout.fulfill()
        }
        try session.connect(host: "127.0.0.1", port: peer.port, token: WirelessTestPeer.token,
                            expectedBoardID: nil)
        await fulfillment(of: [timeout], timeout: 8)
    }

    func testWirelessMonitorCannotSendOrExposePairingSecrets() {
        let monitor = SerialMonitor()
        monitor.startWireless(endpoint: "192.168.1.20:3232")
        defer { monitor.stop() }
        monitor.receiveWireless("Playing")
        monitor.receiveWireless("ESPDOCK WIFI {\"token\":\"fixture-secret\"}")
        monitor.receiveWireless("partial logESPDOCK WIFI {\"token\":\"fixture-secret\"}")
        monitor.send("ESPDOCK WIFI?")
        XCTAssertTrue(monitor.isWireless)
        XCTAssertEqual(monitor.status, .wireless("192.168.1.20:3232"))
        XCTAssertEqual(monitor.lines.map(\.text), ["Playing"])
        monitor.boardGone()
        XCTAssertEqual(monitor.status, .waiting("192.168.1.20:3232"))
    }
}

@MainActor
final class WirelessTestPeer {
    static let token = "00112233445566778899aabbccddeeff"
    static let hello = """
    ESPDOCK HELLO {"version":1,"board":"AA:BB:CC:DD:EE:FF","firmware":{"project":"radio","env":"xiaoesp32s3","commit":"abc123","built":"2026-10-18T00:00:00Z","source":"source-hash","uptime":100}}

    """
    let listener: NWListener
    var connection: NWConnection?
    var received = ""
    var reply = hello + "Playing | Volume: 12/21\n"
    var fragments: [Data]?
    var fragmentDelay: Duration = .milliseconds(2)
    var sender: Task<Void, Never>?
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        let ready = XCTestExpectation(description: "Loopback listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connection = connection
                self.received = ""
                connection.start(queue: .main)
                self.receive(connection)
            }
        }
        listener.start(queue: .main)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.received += String(decoding: data, as: UTF8.self) }
                if self.received.contains("\n") {
                    if let fragments = self.fragments {
                        let delay = self.fragmentDelay
                        self.sender = Task {
                            for fragment in fragments {
                                if Task.isCancelled { return }
                                connection.send(content: fragment, completion: .contentProcessed { _ in })
                                do { try await Task.sleep(for: delay) }
                                catch { return }
                            }
                        }
                    } else {
                        connection.send(content: Data(self.reply.utf8), completion: .contentProcessed { _ in })
                    }
                } else {
                    self.receive(connection)
                }
            }
        }
    }

    func stop() {
        sender?.cancel()
        connection?.cancel()
        listener.cancel()
    }
}
