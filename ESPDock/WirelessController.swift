import Foundation
import Observation
import Security

struct WirelessPairingReply: Decodable {
    let board: String
    let host: String
    let port: UInt16
    let token: String

    static func decode(_ data: Data) throws -> Self {
        struct Rejection: Decodable { let error: String }
        if let rejection = try? JSONDecoder().decode(Rejection.self, from: data) {
            // The firmware's error strings (FirmwareLib WirelessLogs.cpp
            // pairingReport) map to the cases auto-pairing acts on.
            if rejection.error.contains("begin(true)") { throw WirelessError.wifiLogsDisabled }
            if rejection.error.contains("not connected to Wi-Fi") { throw WirelessError.boardNotOnWiFi }
            throw WirelessError.invalidPairing(rejection.error)
        }
        guard let reply = try? JSONDecoder().decode(Self.self, from: data),
              WirelessProtocol.boardID(reply.board) != nil else {
            throw WirelessError.invalidPairing("The USB device sent an invalid pairing response.")
        }
        try WirelessProtocol.validate(host: reply.host, port: reply.port, token: reply.token)
        return reply
    }
}

struct WirelessPairing: Codable, Equatable, Sendable {
    let id: String
    let host: String
    let port: UInt16
    /// Authenticated firmware identity, which can differ from the USB descriptor.
    let boardID: String
    /// Existing project/model key. Pairing over USB preserves it unchanged.
    let localBoardID: String
}

protocol WirelessCredentials: Sendable {
    func token(id: String) throws -> String
    func save(_ token: String, id: String) throws
    func remove(id: String) throws
}

enum WirelessCredentialError: LocalizedError {
    case authorizationRequired

    var errorDescription: String? {
        "Choose Connect over Wi-Fi to use the saved pairing for this app session."
    }
}

private struct PairingKeychain: WirelessCredentials {
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.plontsch.ESPDock.wifi",
         kSecAttrAccount as String: id]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                            "Pairing Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "operation failed")"])
        }
    }

    func save(_ token: String, id: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query(id) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(update) }
    }

    func token(id: String) throws -> String {
        var item = query(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &value)
        if status == errSecInteractionNotAllowed { throw WirelessCredentialError.authorizationRequired }
        try check(status)
        guard let data = value as? Data, let token = String(data: data, encoding: .utf8) else {
            throw WirelessError.invalidPairing("The saved token is invalid. Pair again over USB.")
        }
        return token
    }

    func remove(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

@MainActor
@Observable
final class WirelessController {
    let session = WirelessSession()
    private(set) var pairing: WirelessPairing?
    private(set) var board: Board?
    private(set) var since = Date()
    private(set) var error: String?
    private(set) var reconnecting = false
    private(set) var waitingForKeychain = false
    private(set) var requiresKeychainAuthorization = false

    /// What automatic USB pairing learned about the connected board's firmware.
    /// Drives the single hint in the project card; nothing else is shown.
    enum Readiness: Equatable {
        case unknown
        /// No answer to the pairing query: no or an older ESPDock library.
        case needsLibraryUpdate
        /// Current library, but setup() calls ESPDock::begin() without `true`.
        case needsWiFiLogs
        /// Wi-Fi logs are on, but the board never joined Wi-Fi while on USB.
        case boardOffWiFi
        case paired
    }
    private(set) var readiness: Readiness = .unknown
    @ObservationIgnored var onIdentity: ((FirmwareReport, String) -> Void)?
    @ObservationIgnored var onLine: ((String) -> Void)?
    @ObservationIgnored var onConnected: (() -> Void)?
    @ObservationIgnored var onDisconnected: (() -> Void)?
    @ObservationIgnored private var pending: (host: String, port: UInt16, token: String, localID: String?)?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var keychainRead: Task<Void, Never>?
    @ObservationIgnored private var autoPairTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var automatic = false
    @ObservationIgnored private var authorizedToken: (id: String, token: String)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any WirelessCredentials
    private static let key = "wirelessPairing"

    init(defaults: UserDefaults = .standard, credentials: (any WirelessCredentials)? = nil) {
        self.defaults = defaults
        self.credentials = credentials ?? PairingKeychain()
        if let data = defaults.data(forKey: Self.key) {
            do { pairing = try JSONDecoder().decode(WirelessPairing.self, from: data) }
            catch { self.error = "Couldn't read the saved pairing. Forget it and pair again." }
        }
        session.onIdentity = { [weak self] identity in self?.authenticated(identity) }
        session.onLine = { [weak self] line in self?.onLine?(line) }
        session.onFailure = { [weak self] message, retryable in
            guard let self else { return }
            self.board = nil
            self.onDisconnected?()
            self.error = message
            self.pending = nil
            if !retryable { self.authorizedToken = nil }
            if retryable, self.automatic, self.pairing != nil {
                self.reconnecting = true
                self.retry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch is CancellationError { return }
                    catch { self?.error = error.localizedDescription; return }
                    guard let self, !Task.isCancelled else { return }
                    self.resume()
                }
            }
        }
    }

    func connect(host: String, port: UInt16, token: String, localID: String? = nil,
                 expectedBoardID: String? = nil) throws {
        try WirelessProtocol.validate(host: host, port: port, token: token)
        disconnect()
        error = nil
        pending = (host, port, token.lowercased(), localID)
        try session.connect(host: host, port: port, token: token, expectedBoardID: expectedBoardID)
    }

    func pairUSB(_ usb: Board, serial: SerialMonitor) async throws {
        guard usb.transport == .usb, let localID = usb.macAddress else {
            throw WirelessError.invalidPairing("Pair using a native USB board with a stable identity.")
        }
        let reply = try await serial.requestPairing(port: usb.port)
        try connect(host: reply.host, port: reply.port, token: reply.token,
                    localID: localID, expectedBoardID: reply.board)
    }

    /// Pairs the USB board in the background, so Wi-Fi monitoring needs no
    /// setup UI: called when a USB board appears and after each deploy.
    /// Pairing over USB hands the token over in memory, so it never reads the
    /// Keychain (no prompt). Retries while the board is still joining Wi-Fi
    /// (it boots before its Wi-Fi connects) and while the port is busy.
    func autoPair(_ usb: Board, serial: SerialMonitor, portBusy: @escaping @MainActor () -> Bool) {
        autoPairTask?.cancel()
        guard usb.transport == .usb, let localID = usb.macAddress else { return }
        // Already streaming from this board over Wi-Fi: nothing to do.
        if board != nil, pairing?.localBoardID == localID { readiness = .paired; return }
        readiness = .unknown
        autoPairTask = Task { [weak self] in
            // First attempt after the firmware probe (1.5 s) has released the
            // port; later ones give the board time to join Wi-Fi.
            for delay in [4, 6, 10, 20, 30] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if portBusy() { continue }
                do {
                    try await self.pairUSB(usb, serial: serial)
                    self.readiness = .paired
                    return
                } catch WirelessError.noPairingResponse {
                    self.readiness = .needsLibraryUpdate; return
                } catch WirelessError.wifiLogsDisabled {
                    self.readiness = .needsWiFiLogs; return
                } catch WirelessError.boardNotOnWiFi {
                    self.readiness = .boardOffWiFi   // keep trying
                } catch {
                    continue   // port busy or a transient serial error
                }
            }
        }
    }

    /// The USB board went away: stop pairing attempts and, if this session
    /// already holds the token (it paired over USB), carry on over Wi-Fi
    /// without asking. Otherwise the empty state offers Connect over Wi-Fi.
    func usbDisconnected() {
        autoPairTask?.cancel()
        autoPairTask = nil
        readiness = .unknown
        if board == nil, pairing != nil, authorizedToken != nil { resume() }
    }

    func resume(allowKeychainPrompt: Bool = false) {
        guard let pairing else { return }
        disconnect()
        let generation = self.generation
        let cachedToken = authorizedToken.flatMap { $0.id == pairing.id ? $0.token : nil }
        guard cachedToken != nil || allowKeychainPrompt else {
            requiresKeychainAuthorization = true
            error = WirelessCredentialError.authorizationRequired.localizedDescription
            return
        }
        waitingForKeychain = cachedToken == nil
        automatic = true
        let credentials = self.credentials
        keychainRead = Task { [weak self] in
            do {
                let token: String
                if let cachedToken {
                    token = cachedToken
                } else {
                    // Only an explicit user action can open a Keychain dialog.
                    // Keep that potentially blocking OS operation off the UI.
                    token = try await Task.detached(priority: .utility) {
                        try credentials.token(id: pairing.id)
                    }.value
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.keychainRead = nil
                self.waitingForKeychain = false
                self.authorizedToken = (pairing.id, token)
                try self.session.connect(host: pairing.host, port: pairing.port, token: token,
                                         expectedBoardID: pairing.boardID)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.keychainRead = nil
                self.waitingForKeychain = false
                self.automatic = false
                self.error = error.localizedDescription
            }
        }
    }

    func disconnect() {
        generation = UUID()
        keychainRead?.cancel()
        keychainRead = nil
        waitingForKeychain = false
        requiresKeychainAuthorization = false
        automatic = false
        retry?.cancel()
        retry = nil
        reconnecting = false
        pending = nil
        board = nil
        error = nil
        session.disconnect()
        onDisconnected?()
    }

    func forget() throws {
        autoPairTask?.cancel()
        autoPairTask = nil
        readiness = .unknown
        if let pairing { try credentials.remove(id: pairing.id) }
        disconnect()
        authorizedToken = nil
        pairing = nil
        error = nil
        defaults.removeObject(forKey: Self.key)
    }

    private func authenticated(_ identity: WirelessIdentity) {
        do {
            if let pending {
                // A manual re-pair of the same firmware identity keeps the
                // original USB project key, even when its MAC differs.
                let previous = pairing?.boardID == identity.board.uppercased() ? pairing : nil
                let saved = WirelessPairing(id: pairing?.id ?? UUID().uuidString,
                                           host: pending.host, port: pending.port,
                                           boardID: identity.board.uppercased(),
                                           localBoardID: pending.localID ?? previous?.localBoardID ?? identity.board.uppercased())
                let data = try JSONEncoder().encode(saved)
                try credentials.save(pending.token, id: saved.id)
                defaults.set(data, forKey: Self.key)
                pairing = saved
                authorizedToken = (saved.id, pending.token)
                self.pending = nil
            }
            guard let pairing else { throw WirelessError.invalidPairing("No pairing belongs to this connection.") }
            board = .wireless(host: pairing.host, port: pairing.port, boardID: pairing.localBoardID)
            since = .now
            error = nil
            automatic = true
            reconnecting = false
            onIdentity?(identity.firmware, pairing.localBoardID)
            onConnected?()
        } catch {
            disconnect()
            self.error = error.localizedDescription
        }
    }
}
