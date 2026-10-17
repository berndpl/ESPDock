import SwiftUI

struct ContentView: View {
    let monitor: BoardMonitor
    let identities: BoardIdentities
    let projects: ProjectLinks
    let deployer: Deployer
    let firmware: FirmwareProbe
    let serial: SerialMonitor
    /// Not persisted: the window always opens tight; it widens only while the
    /// monitor is shown.
    @State private var showSerial = false

    static let width: CGFloat = 520
    static let monitorWidth: CGFloat = 440

    var body: some View {
        let model = monitor.board.flatMap { identities.model(for: $0) }

        VStack(alignment: .leading, spacing: 12) {
            if let board = monitor.board {
                StatusCard(board: board, model: model, since: monitor.since, identities: identities,
                           showSerial: $showSerial)

                // Project first: it's what you act on; the pinout is reference.
                ProjectCard(board: board, model: model, projects: projects, deployer: deployer,
                            firmware: firmware)

                // The pinout only appears for a known board model.
                if let model {
                    GroupBox {
                        VStack(spacing: 10) {
                            PinoutView(model: model)
                            HStack(spacing: 16) {
                                Link("Seeed Wiki", destination: model.referenceURL)
                                Link("Schematic (PDF)", destination: model.schematicURL)
                            }
                        }
                        .padding(4)
                    }
                }
            } else {
                EmptyState(otherPorts: monitor.otherPorts, blockedPorts: monitor.blockedPorts)
            }
        }
        .padding(20)
        .padding(.top, 10)   // clear the floating traffic-light buttons
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Monitor panel on the right. Not `.inspector`: it reserves its column
        // even when hidden, so the window could never shrink back. As an
        // overlay on a widened frame, the panel takes exactly the main
        // content's height and the window (contentSize resizability) is 520 pt
        // wide by default, 960 pt only while the monitor shows.
        .frame(width: showSerial ? Self.width + Self.monitorWidth : Self.width, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showSerial {
                HStack(spacing: 0) {
                    Divider()
                    SerialMonitorView(monitor: serial)
                }
                .frame(width: Self.monitorWidth)
                .background(.background)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: showSerial, initial: true) { _, show in
            if show, let board = monitor.board { serial.start(port: board.port) }
            if !show { serial.stop() }
        }
        .animation(.smooth(duration: 0.25), value: showSerial)
        .animation(.default, value: monitor.board)
        .animation(.default, value: model)
        .task(id: monitor.board?.macAddress) {
            projects.watch(monitor.board)
            // Ask the firmware what it runs (needs the ESPDock library).
            if let board = monitor.board, !deployer.isRunning { firmware.probe(board) }
        }
    }
}

/// The board: name, connected time, cable and power budget. Technical
/// identifiers (port, USB ID, MAC) live in the tooltip; the model can be
/// changed from the context menu, so neither needs permanent space.
private struct StatusCard: View {
    let board: Board
    let model: BoardModel?
    let since: Date
    let identities: BoardIdentities
    @Binding var showSerial: Bool

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: board.id)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    // Relative time keeps itself up to date without a timer.
                    Text("Connected \(since, style: .relative) ago")
                        .foregroundStyle(.secondary)
                    if let connectionLine {
                        Text(connectionLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(isOn: $showSerial) {
                    Label("Serial Monitor", systemImage: "apple.terminal")
                }
                .toggleStyle(.button)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help("Show live serial output (⇧⌘M)")
                if model == nil, board.macAddress != nil, !BoardCatalog.candidates(for: board).isEmpty {
                    Menu("Identify") {
                        ForEach(BoardCatalog.candidates(for: board)) { c in
                            Button(c.name) { identities.assign(c, to: board) }
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(4)
        }
        .help(tooltip)
        .contextMenu {
            if board.macAddress != nil {
                ForEach(BoardCatalog.candidates(for: board)) { c in
                    Button(c.name) { identities.assign(c, to: board) }
                }
                if model != nil { Button("Forget Model") { identities.assign(nil, to: board) } }
            }
        }
    }

    private var title: String {
        if let model { return model.name }
        return board.isCertainlyESP32 ? "ESP32 Connected" : "Possible ESP32 Connected"
    }

    /// "Passive cable · 500 of 3000 mA" — the two connection facts worth
    /// seeing at a glance.
    private var connectionLine: String? {
        var parts: [String] = []
        switch board.macPort?.cable {
        case .passiveUnmarked?: parts.append("Passive cable")
        case let .marked(type, _, amps)?: parts.append(amps.map { "\(type) · \($0) A" } ?? type)
        case nil: if let hubs = board.connection?.hubs, !hubs.isEmpty { parts.append("Via hub") }
        }
        if let c = board.connection {
            switch (c.allocatedMilliamps, c.portLimitMilliamps) {
            case let (a?, l?): parts.append("\(a) of \(l) mA")
            case let (a?, nil): parts.append("\(a) mA")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var tooltip: String {
        var lines = [board.port, "\(board.vidPid) · \(board.interfaceDescription)"]
        if let mac = board.macAddress { lines.append("MAC \(mac)") }
        if let c = board.connection, let speed = c.speed { lines.append(speed.description) }
        lines.append(board.macPort.map { "Directly to Mac · \($0.name)" }
                     ?? board.connection?.pathDescription ?? "")
        if model != nil { lines.append("Right-click to change the board model") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// No board: the system empty-state view, plus the accessory-security hint
/// when macOS is blocking a device's data connection.
private struct EmptyState: View {
    let otherPorts: [String]
    let blockedPorts: [String]

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("No Board Connected", systemImage: "cable.connector.slash")
            } description: {
                Text("Plug in an ESP32 over USB. Use a data cable — many charge-only cables look identical.")
            }
            if !blockedPorts.isEmpty {
                GroupBox {
                    Label {
                        Text("Something is attached to \(blockedPorts.joined(separator: ", ")), but macOS hasn't allowed its data connection. If it's your board, unplug and replug it while the Mac is unlocked, and click Allow if asked.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    }
                    .padding(4)
                }
            }
            if !otherPorts.isEmpty {
                Text("Other serial ports: \(otherPorts.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 260)
    }
}

