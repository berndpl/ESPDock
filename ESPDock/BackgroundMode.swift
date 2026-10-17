import AppKit
import SwiftUI

/// User settings for background behaviour (stored in UserDefaults).
enum AppSettings {
    static let runInBackgroundKey = "runInBackground"
    static let bringToFrontKey = "bringToFrontOnConnect"

    /// Defaults: both on — watching for boards is the app's main job.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [runInBackgroundKey: true, bringToFrontKey: true])
    }

    static var runInBackground: Bool { UserDefaults.standard.bool(forKey: runInBackgroundKey) }
    static var bringToFront: Bool { UserDefaults.standard.bool(forKey: bringToFrontKey) }
}

/// Owns the long-lived state (board monitor, identities) so it survives the
/// window being closed, and implements background mode:
/// - window closed + "Run in background" → app stays alive, leaves the Dock
///   (activation policy .accessory) so it doesn't look like a stuck app;
/// - board connects + "Bring to front" → window reopens and comes forward.
///
/// Cost while in background: none beyond what the window already did. Board
/// detection is IOKit-notification driven; the only timer is the 3 s
/// IORegistry check for blocked ports, which runs only while no board is
/// connected and spawns no processes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = BoardMonitor()
    let identities = BoardIdentities()
    let projects = ProjectLinks()
    let deployer = Deployer()
    let firmware = FirmwareProbe()
    let serial = SerialMonitor()
    let wireless = WirelessController()
    /// Captured from the main window's environment. SwiftUI's OpenWindowAction
    /// is app-scoped, so it stays usable after that window has closed.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onBoardConnected = { [weak self] board in
            self?.serial.boardAvailable(port: board.port)
            guard AppSettings.bringToFront else { return }
            self?.showMainWindow()
        }
        // Serial monitor ⇄ firmware probe ⇄ deployer share one port.
        firmware.monitor = serial
        serial.onReport = { [weak self] report in
            guard let self else { return }
            self.firmware.receive(report, mac: Board.preferred(usb: self.monitor.board, wireless: self.wireless.board)?.macAddress)
        }
        wireless.onIdentity = { [weak self] report, mac in self?.firmware.receive(report, mac: mac) }
        wireless.onLine = { [weak self] line in
            guard let self, self.monitor.board == nil else { return }
            self.serial.receiveWireless(line)
        }
        wireless.onConnected = { [weak self] in
            guard let self, self.monitor.board == nil else { return }
            if self.serial.isWireless, let board = self.wireless.board {
                self.serial.startWireless(endpoint: board.port)
            }
            wireless.onDisconnected = { [weak self] in
                guard let self, self.monitor.board == nil, self.serial.isWireless else { return }
                self.serial.boardGone()
            }
            if AppSettings.bringToFront { self.showMainWindow() }
        }
        wireless.resume()
        deployer.willUsePort = { [weak self] in self?.serial.suspend() }
        deployer.didReleasePort = { [weak self] port in self?.serial.boardAvailable(port: port) }
        #if DEBUG
        // Test hook: simulate a board connecting without replugging hardware.
        // Trigger: swift -e 'import Foundation; DistributedNotificationCenter.default()
        //   .postNotificationName(.init("de.plontsch.ESPDock.debugSimulateConnect"),
        //   object: nil, deliverImmediately: true)'
        DistributedNotificationCenter.default().addObserver(
            forName: .init("de.plontsch.ESPDock.debugSimulateConnect"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AppSettings.bringToFront else { return }
                self?.showMainWindow()
            }
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.runInBackground
    }

    /// Relaunching the app (Finder/Spotlight) while it runs in the background
    /// lands here: bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            // Cooperative activation (macOS 14+) may decline to steal focus
            // from the app you're typing in; ordering front regardless still
            // makes the window visible on top.
            window.orderFrontRegardless()
        } else {
            openMainWindow?()
            // The new window exists only after this run-loop turn; then put it
            // on top. (orderFrontRegardless shows it above other apps' windows
            // even when macOS declines to hand us keyboard focus.)
            DispatchQueue.main.async { [weak self] in
                self?.mainWindow?.orderFrontRegardless()
            }
        }
        // macOS 14+ activation is cooperative: the system may keep focus with
        // the app you're typing in. That's by design and can't be overridden
        // (activate(ignoringOtherApps:) is deprecated and behaves the same).
        NSApp.activate()
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard window?.identifier?.rawValue.hasPrefix("main") == true, AppSettings.runInBackground else { return }
        // Leave the Dock once the last regular window is gone.
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.runInBackgroundKey) private var runInBackground = true
    @AppStorage(AppSettings.bringToFrontKey) private var bringToFront = true

    var body: some View {
        Form {
            Section {
                Toggle("Run in background", isOn: $runInBackground)
                Text("Keeps watching for boards after you close the window. ESPDock leaves the Dock until the window is back. Open ESPDock again to show it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bring to front when a board connects", isOn: $bringToFront)
                Text("Opens the window and brings it forward when an ESP32 is plugged in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
