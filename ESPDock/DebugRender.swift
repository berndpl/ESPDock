#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `ESPDock --render-pinout <out.png> [dark|light]` renders the
/// window content (live board state) to a PNG and exits. Lets the diagram be checked without Screen
/// Recording permission (used by agents iterating on the layout).
enum DebugRender {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
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
        // --render-serial <out.png> <port>: attach the monitor, query, snapshot.
        let serialMode = args.contains("--render-serial")
        // --render-guide <out.png> [dark|light] renders the D4 pin popover.
        let guideMode = args.contains("--render-guide")
        guard let i = args.firstIndex(of: serialMode ? "--render-serial"
                                      : guideMode ? "--render-guide" : "--render-pinout"),
              i + 1 < args.count else { return }
        let dark = !serialMode && args.count > i + 2 && args[i + 2] == "dark"
        // Whole window content with the live board + project state. `.task`
        // doesn't run in ImageRenderer, so start watching and let the async
        // code scan finish before rendering.
        let monitor = BoardMonitor()
        let projects = ProjectLinks()
        let firmware = FirmwareProbe()
        projects.watch(monitor.board)
        if let board = monitor.board { firmware.probe(board, after: .zero) }
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        let serial = SerialMonitor()
        if serialMode, args.count > i + 2 {
            serial.start(port: args[i + 2])
            serial.send("ESPDOCK?")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        }
        let content: AnyView = serialMode
            ? AnyView(SerialMonitorView(monitor: serial).frame(width: 440, height: 360))
            : guideMode
            ? AnyView(PinGuideView(guide: .forPin(BoardCatalog.xiaoESP32S3.pins[4])))
            : AnyView(ContentView(monitor: monitor, identities: BoardIdentities(),
                                  projects: projects, deployer: Deployer(), firmware: firmware,
                                  serial: SerialMonitor()))
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
