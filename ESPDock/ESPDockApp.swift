import SwiftUI

@main
struct ESPDockApp: App {
    // Long-lived state lives in the delegate so it survives closing the window
    // (background mode, see BackgroundMode.swift).
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        AppSettings.registerDefaults()
        #if DEBUG
        DebugRender.runIfRequested()
        #endif
    }

    var body: some Scene {
        // Window (not WindowGroup): one board at a time, so one window.
        Window("ESPDock", id: "main") {
            MainWindowContent(appDelegate: appDelegate)
        }
        .windowResizability(.contentSize)
        // Modern chrome: no title bar strip; traffic lights float over the
        // content, which is padded to clear them (ContentView).
        .windowStyle(.hiddenTitleBar)
        // Stock behaviour: drag the window by its background (title bar is hidden).
        .windowBackgroundDragBehavior(.enabled)
        // Don't restore a widened (monitor-open) size at launch: start tight.
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ESPDock") { BuildInfo.showAboutPanel() }
            }
            SelfEditCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Hands the window's openWindow action to the delegate, so it can reopen the
/// window from the background when a board connects.
private struct MainWindowContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(monitor: appDelegate.monitor, identities: appDelegate.identities,
                    projects: appDelegate.projects, deployer: appDelegate.deployer,
                    firmware: appDelegate.firmware, serial: appDelegate.serial)
            .onAppear {
                appDelegate.openMainWindow = { openWindow(id: "main") }
                NSApp.setActivationPolicy(.regular)
            }
    }
}
