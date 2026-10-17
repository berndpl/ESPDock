import SwiftUI

struct WirelessSetupView: View {
    let wireless: WirelessController
    let usb: Board?
    let serial: SerialMonitor
    let projects: ProjectLinks
    let deploying: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "3232"
    @State private var token = ""
    @State private var pairingUSB = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Wi-Fi Monitoring", systemImage: "wifi").font(.title2.bold())
            Text("Read-only logs and firmware identity on your trusted LAN. USB is preferred when attached. Uploads and serial commands still require USB.")
                .foregroundStyle(.secondary)
            Label("TCP is not encrypted. Do not use public Wi-Fi, forward the port, or share the pairing token.",
                  systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout).foregroundStyle(.orange)

            Form {
                Section("Pair over USB (recommended)") {
                    Text("Deploy the updated ESPDock library once. In setup(), call ESPDock::begin(true); use ESPDock::log().println(...) for logs. Wi-Fi must already be configured by your sketch.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(pairingUSB ? "Reading USB Pairing…" : "Pair Connected USB Board") {
                            guard let usb else { return }
                            pairingUSB = true
                            error = nil
                            Task {
                                defer { pairingUSB = false }
                                do { try await wireless.pairUSB(usb, serial: serial) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(usb?.macAddress == nil || deploying || pairingUSB)
                        if let usb, let link = projects.link(for: usb) {
                            Button("Update Library") {
                                do {
                                    try VersionReportingInstaller.install(projectAt: link.url, environment: link.environment)
                                    projects.rescan()
                                } catch { self.error = error.localizedDescription }
                            }
                            .disabled(deploying || pairingUSB)
                            .help("Update lib/ESPDock in the linked project. Deploy over USB afterwards.")
                        }
                    }
                }
                Section("Or enter pairing details") {
                    TextField("LAN address", text: $host, prompt: Text("192.168.1.20 or radio.local"))
                    TextField("TCP port", text: $port)
                    SecureField("Pairing token", text: $token)
                    Text("Get these with ESPDOCK WIFI? over USB. Manual pairing cannot recover an older USB project association unless this board was paired before.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Connect & Remember") {
                        error = nil
                        do {
                            guard let value = UInt16(port), value > 0 else { throw WirelessError.invalidPort }
                            try wireless.connect(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 port: value, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                            token = ""
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(host.isEmpty || token.isEmpty || pairingUSB || connecting)
                }
            }
            .formStyle(.grouped)

            WirelessStatusView(wireless: wireless)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 650)
        .onChange(of: wireless.board) { _, board in if board != nil { dismiss() } }
    }

    private var connecting: Bool {
        wireless.waitingForKeychain || wireless.session.status == .connecting || wireless.session.status == .authenticating
    }
}

struct WirelessStatusView: View {
    let wireless: WirelessController
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(status, systemImage: "wifi")
                    .foregroundStyle(wireless.board == nil ? Color.secondary : .green)
                Spacer()
                if wireless.pairing != nil {
                    if wireless.waitingForKeychain {
                        Button("Cancel") { wireless.disconnect() }
                    } else if wireless.requiresKeychainAuthorization {
                        Button("Allow Wi-Fi") { wireless.resume(allowKeychainPrompt: true) }
                    } else if wireless.session.status == .closed || isFailed {
                        Button("Reconnect") { wireless.resume(allowKeychainPrompt: true) }
                    } else {
                        Button("Disconnect") { wireless.disconnect() }
                    }
                }
                if wireless.pairing != nil || wireless.error != nil {
                    Button("Forget") {
                        do { try wireless.forget() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .font(.callout)
            if let error = error ?? wireless.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = wireless.session.status { return true }
        return false
    }

    private var status: String {
        if wireless.waitingForKeychain { return "Waiting for Keychain access…" }
        if wireless.requiresKeychainAuthorization { return "Wi-Fi needs approval" }
        if wireless.reconnecting { return "Reconnecting to Wi-Fi…" }
        switch wireless.session.status {
        case .closed: return wireless.pairing == nil ? "Not paired" : "Wi-Fi disconnected"
        case .connecting: return "Connecting over Wi-Fi…"
        case .authenticating: return "Checking pairing…"
        case .connected: return "Wi-Fi · \(wireless.board?.port ?? "")"
        case .failed: return "Wi-Fi unavailable"
        }
    }
}
