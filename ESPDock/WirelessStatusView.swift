import SwiftUI

/// Wi-Fi monitoring's only visible control, shown in the empty state.
///
/// Pairing happens by itself over USB (WirelessController.autoPair), and an
/// unplugged board carries on over Wi-Fi with the token from that pairing.
/// What's left is the case the Keychain makes explicit: the app started
/// without the board on USB, so the saved token has to be read from the
/// Keychain, which may show a macOS prompt. That read only happens on this
/// button, never on its own, to avoid surprise password dialogs.
/// Forgetting the pairing lives in the board card's context menu.
struct WirelessStatusView: View {
    let wireless: WirelessController

    var body: some View {
        if wireless.pairing != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wifi").foregroundStyle(.secondary)
                        }
                        Text(status).foregroundStyle(.secondary)
                        Spacer()
                        if !busy, wireless.board == nil {
                            Button("Connect over Wi-Fi") { wireless.resume(allowKeychainPrompt: true) }
                                .help("Uses the saved pairing; macOS may ask to allow Keychain access.")
                        }
                    }
                    .font(.callout)
                    // The authorization notice just restates the button.
                    if let error = wireless.error, !wireless.requiresKeychainAuthorization, !busy {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
        }
    }

    private var busy: Bool {
        wireless.waitingForKeychain || wireless.reconnecting
            || wireless.session.status == .connecting || wireless.session.status == .authenticating
    }

    private var status: String {
        if wireless.waitingForKeychain { return "Waiting for Keychain access…" }
        if wireless.reconnecting { return "Reconnecting over Wi-Fi…" }
        switch wireless.session.status {
        case .connecting, .authenticating: return "Connecting over Wi-Fi…"
        case .connected: return "Wi-Fi · \(wireless.board?.port ?? "")"
        case .failed: return "Paired board unreachable over Wi-Fi"
        case .closed: return "Paired over Wi-Fi"
        }
    }
}
