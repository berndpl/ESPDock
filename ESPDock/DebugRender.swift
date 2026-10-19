#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `ESPDock --render-pinout <out.png> [dark|light]` renders the
/// window content (live board state) to a PNG and exits. Lets the diagram be checked without Screen
/// Recording permission (used by agents iterating on the layout).
enum DebugRender {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        // Exercises real USB pairing and Wi-Fi logs without displaying secrets.
        if let i = args.firstIndex(of: "--verify-wireless"), i + 1 < args.count {
            let monitor = BoardMonitor()
            guard let board = monitor.board, board.port == args[i + 1],
                  let link = ProjectLinks().link(for: board) else {
                print("Connect the linked USB board before verifying Wi-Fi.")
                exit(1)
            }
            let wireless = WirelessController()
            let serial = SerialMonitor()
            let expectedSource = CodeFingerprint.combined(CodeFingerprint.manifest(projectAt: link.url))
            var finished = false, validIdentity = false, logLines = 0
            wireless.onIdentity = { report, localID in
                validIdentity = localID == board.macAddress && report.source == expectedSource
                print(validIdentity ? "Authenticated Wi-Fi identity matches the USB project and current source."
                      : "Wi-Fi identity does not match the USB project/current source.")
                if !validIdentity { finished = true }
            }
            wireless.onLine = { _ in
                logLines += 1
                if logLines >= 2 { finished = true }
            }
            wireless.onDisconnected = { [weak wireless] in
                if case .failed(let message)? = wireless?.session.status {
                    print(message)
                }
            }
            Task { @MainActor in
                do { try await wireless.pairUSB(board, serial: serial) }
                catch {
                    print("USB pairing failed: \(error.localizedDescription)")
                    finished = true
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while !finished, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let firstConnection = validIdentity && logLines >= 2 && !serial.isActive
            wireless.disconnect()
            let savedWireless = WirelessController()
            if firstConnection {
                finished = false
                validIdentity = false
                logLines = 0
                savedWireless.onIdentity = wireless.onIdentity
                savedWireless.onLine = wireless.onLine
                savedWireless.resume(allowKeychainPrompt: true)
                let reconnectDeadline = Date().addingTimeInterval(20)
                while !finished, Date() < reconnectDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }
            let success = firstConnection && validIdentity && logLines >= 2 && !serial.isActive
            if savedWireless.waitingForKeychain { print("Waiting for macOS Keychain approval.") }
            if let error = savedWireless.error ?? wireless.error { print(error) }
            savedWireless.disconnect()
            wireless.disconnect()
            print("Wi-Fi application log lines: \(logLines); USB monitor closed: \(!serial.isActive).")
            if success { print("Saved pairing reconnected using Keychain without another USB query.") }
            print(success ? "Live wireless verification passed." : "Live wireless verification failed or timed out.")
            exit(success ? 0 : 1)
        }
        // --probe <port>: print the firmware's ESPDock report and exit.
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            if let r = SerialProbe.query(port: args[i + 1]) {
                print(String(data: try! JSONEncoder().encode(r), encoding: .utf8)!)
            } else {
                print("no answer")
            }
            exit(0)
        }
        // --install-version-reporting <project> <env>: same installer as the button.
        if let i = args.firstIndex(of: "--install-version-reporting"), i + 2 < args.count {
            do {
                try VersionReportingInstaller.install(projectAt: URL(fileURLWithPath: args[i + 1]),
                                                      environment: args[i + 2])
                print("installed")
            } catch { print("failed: \(error)") }
            exit(0)
        }
        // --hash <project>: print CodeFingerprint.combined for comparison with the .py.
        if let i = args.firstIndex(of: "--hash"), i + 1 < args.count {
            print(CodeFingerprint.combined(CodeFingerprint.manifest(projectAt: URL(fileURLWithPath: args[i + 1]))))
            exit(0)
        }
        // --scan-wiring <project>: print the external parts and wires found in code.
        if let i = args.firstIndex(of: "--scan-wiring"), i + 1 < args.count {
            let parts = PeripheralScanner.scan(projectAt: URL(fileURLWithPath: args[i + 1]),
                                               board: BoardCatalog.xiaoESP32S3)
            if parts.isEmpty { print("no parts") }
            for p in parts {
                print("\(p.part.name) (named in code: \(p.namedInCode))")
                for c in p.connections {
                    let from: String
                    switch c.origin {
                    case let .code(file, line, expr): from = "\(file):\(line) \(expr)"
                    case let .assumed(why): from = "assumed — \(why)"
                    }
                    print("  \(c.partPin) ← \(c.end.partID.map { "\($0) " } ?? "")\(c.end.boardPin)\(c.end.gpio.map { " (GPIO\($0))" } ?? "")  \(from)")
                }
                for issue in p.issues { print("  ! \(issue)") }
            }
            exit(0)
        }
        // --render-serial <out.png> <port>: attach the monitor, query, snapshot.
        let serialMode = args.contains("--render-serial")
        // --render-guide <out.png> [dark|light] renders the D4 pin popover.
        let guideMode = args.contains("--render-guide")
        // --render-wifi <out.png> [dark|light]: the USB/manual pairing sheet.
        let wifiMode = args.contains("--render-wifi")
        // --render-disconnected <out.png> [dark|light]: the tall empty-state layout.
        let disconnectedMode = args.contains("--render-disconnected")
        // --render-wiring <out.png> [dark|light] <project> [blueprint]: the pinout
        // card with the external parts found in that project's code.
        // Add --power-details to expand its power calculation without a device.
        let wiringMode = args.contains("--render-wiring")
        guard let i = args.firstIndex(of: serialMode ? "--render-serial"
                                      : guideMode ? "--render-guide"
                                      : wifiMode ? "--render-wifi"
                                      : disconnectedMode ? "--render-disconnected"
                                      : wiringMode ? "--render-wiring" : "--render-pinout"),
              i + 1 < args.count else { return }
        let dark = !serialMode && args.count > i + 2 && args[i + 2] == "dark"
        // Whole window content with the live board + project state. `.task`
        // doesn't run in ImageRenderer, so start watching and let the async
        // code scan finish before rendering.
        let monitor = BoardMonitor()
        let projects = ProjectLinks()
        let firmware = FirmwareProbe()
        if !disconnectedMode {
            projects.watch(monitor.board)
            if let board = monitor.board { firmware.probe(board, after: .zero) }
            RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        }
        let serial = SerialMonitor()
        if serialMode, args.count > i + 2 {
            serial.start(port: args[i + 2])
            serial.send("ESPDOCK?")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        }
        if wiringMode, args.count > i + 3 {
            // Argument domain: wins over the user's setting but isn't saved.
            UserDefaults.standard.setVolatileDomain(
                ["boardStyle": args.count > i + 4 && args[i + 4] == "blueprint" ? "blueprint" : "realistic"],
                forName: UserDefaults.argumentDomain)
        }
        let wiringParts = wiringMode && args.count > i + 3
            ? PeripheralScanner.scan(projectAt: URL(fileURLWithPath: args[i + 3]), board: BoardCatalog.xiaoESP32S3)
            : []
        let content: AnyView = disconnectedMode
            ? AnyView(DisconnectedStateView(otherPorts: monitor.otherPorts, blockedPorts: monitor.blockedPorts,
                                            wireless: WirelessController())
                .padding(20).frame(width: ContentView.width, height: 1040))
            : wiringMode
            ? AnyView(GroupBox {
                SchematicCard(model: BoardCatalog.xiaoESP32S3, parts: wiringParts,
                              expandPowerEstimate: args.contains("--power-details")).diagram
            }
                .frame(width: 480).padding(20))
            : serialMode
            ? AnyView(SerialMonitorView(monitor: serial).frame(width: 440, height: 360))
            : guideMode
            ? AnyView(PinGuideView(guide: .forPin(BoardCatalog.xiaoESP32S3.pins[4])))
            : wifiMode
            ? AnyView(WirelessStatusView(wireless: WirelessController()).frame(width: 480).padding(20))
            : AnyView(ContentView(monitor: monitor, identities: BoardIdentities(),
                                  projects: projects, deployer: Deployer(), firmware: firmware,
                                  serial: SerialMonitor(), wireless: WirelessController()))
        let view = content
            .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        // Host in a real (offscreen) AppKit window and snapshot it: unlike
        // ImageRenderer, this draws AppKit-backed controls (GroupBox, buttons,
        // menus) exactly as on screen.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .init(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
        }
        exit(0)
    }
}
#endif
