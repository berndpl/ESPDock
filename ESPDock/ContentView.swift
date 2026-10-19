import SwiftUI

struct ContentView: View {
    let monitor: BoardMonitor
    let identities: BoardIdentities
    let projects: ProjectLinks
    let deployer: Deployer
    let firmware: FirmwareProbe
    let serial: SerialMonitor
    let wireless: WirelessController
    /// Not persisted: the window always opens without the monitor.
    @State private var showSerial = false
    /// External parts the linked project's code wires to the board.
    @State private var parts: [DetectedPart] = []

    static let width: CGFloat = 520
    static let monitorWidth: CGFloat = 440
    private var board: Board? { Board.preferred(usb: monitor.board, wireless: wireless.board) }

    var body: some View {
        let model = board.flatMap { identities.model(for: $0) }

        VStack(alignment: .leading, spacing: 12) {
            if let board {
                StatusCard(board: board, model: model,
                           since: board.transport == .usb ? monitor.since : wireless.since, identities: identities,
                           forgetWiFi: wireless.pairing == nil ? nil : { try? wireless.forget() })

                // Project first: it's what you act on; the pinout is reference.
                ProjectCard(board: board, model: model, projects: projects, deployer: deployer,
                            firmware: firmware, wifiReadiness: wireless.readiness)

                // The pinout only appears for a known board model.
                if let model {
                    SchematicCard(model: model, parts: parts,
                                  usbConnection: board.transport == .usb ? board.connection : nil)
                        .id(projects.link(for: board)?.path)
                }
            } else {
                DisconnectedStateView(otherPorts: monitor.otherPorts, blockedPorts: monitor.blockedPorts,
                                      wireless: wireless)
            }
        }
        .padding(20)
        .frame(width: Self.width)
        // Pinned top-leading in the inspector's main column: while the window
        // resizes, that column is briefly wider than the cards, which would
        // otherwise flash centered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Native trailing inspector, toggled from the toolbar. Its column
        // comes on top of the fixed 520 pt content, so the window widens while
        // the monitor shows (contentSize resizability).
        .inspector(isPresented: $showSerial) {
            // Built only while shown: a hidden inspector's content still
            // contributes its toolbar items to the window toolbar.
            if showSerial {
                SerialMonitorView(monitor: serial)
                    .inspectorColumnWidth(Self.monitorWidth)
            }
        }
        // The inspector reserves its column (and an ideal height) even while
        // hidden, which made the contentSize window ~900 pt wide and taller
        // than the cards. Pin width only; height stays user-resizable.
        .frame(width: showSerial ? Self.width + Self.monitorWidth : Self.width)
        .frame(minHeight: 480, idealHeight: 760, maxHeight: .infinity)
        .toolbar {
            // No title in the toolbar, so push the toggle to the trailing edge.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                // A Button, not a Toggle: SwiftUI toolbar toggles expose no
                // accessibility name (VoiceOver read just "toggle button").
                Button {
                    // No SwiftUI animation: the system already animates the
                    // window resize, and the inspector's own slide on top of
                    // it pushed the cards off the left edge mid-transition.
                    // The resize alone reveals/covers the column cleanly.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { showSerial.toggle() }
                } label: {
                    // One entry point; the icon says how the board is reached:
                    // a cable on USB, Wi-Fi only when there's no cable.
                    Label("Device Monitor", systemImage: board?.transport == .wifi ? "wifi" : "cable.connector")
                        // On-state cue a plain Button doesn't have: tinted
                        // while the monitor is open.
                        .foregroundStyle(showSerial ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .accessibilityAddTraits(showSerial ? .isSelected : [])
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help(board?.transport == .wifi ? "Show read-only Wi-Fi output (⇧⌘M)" : "Show live USB output (⇧⌘M)")
                // Opening needs a board's port; closing must always work (the
                // monitor stays open, "Waiting for board…", across resets).
                .disabled(board == nil && !showSerial)
            }
        }
        .onChange(of: showSerial, initial: true) { _, show in
            if show { openMonitor() }
            if !show { serial.stop() }
        }
        .onChange(of: board?.id) { _, _ in if showSerial { openMonitor() } }
        .animation(.default, value: board)
        .animation(.default, value: model)
        // Rescan the code for external parts whenever the project changes
        // (the manifest updates live via FSEvents), off the main actor.
        .task(id: wiringScanKey(model)) {
            guard let board, let model,
                  let link = projects.link(for: board) else { parts = []; return }
            let url = link.url
            parts = await Task.detached { PeripheralScanner.scan(projectAt: url, board: model) }.value
        }
        .task(id: board?.id) {
            projects.watch(board)
            // Ask the firmware what it runs (needs the ESPDock library).
            if let board, !deployer.isRunning { firmware.probe(board) }
        }
    }

    private func openMonitor() {
        guard let board else { serial.boardGone(); return }
        if board.transport == .wifi { serial.startWireless(endpoint: board.port) }
        else { serial.start(port: board.port) }
    }
}

struct SchematicCard: View {
    let model: BoardModel
    let parts: [DetectedPart]
    var usbConnection: USBConnection? = nil
    var expandPowerEstimate = false

    var body: some View {
        GroupBox {
            ScrollView {
                diagram
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 220, maxHeight: .infinity)
        }
    }

    var diagram: some View {
        VStack(spacing: 12) {
            PowerEstimateView(model: model, parts: parts, usbConnection: usbConnection,
                              initiallyExpanded: expandPowerEstimate)
                .padding(8)
            Divider()
            PinoutView(model: model, parts: parts)
                .padding(4)
        }
    }
}

extension ContentView {
    /// Changes when the linked project, its files or the board model change.
    fileprivate func wiringScanKey(_ model: BoardModel?) -> String {
        guard let board, let link = projects.link(for: board) else { return "" }
        let code = projects.watchedMAC == board.macAddress
            ? projects.currentManifest.map(CodeFingerprint.combined) ?? "" : ""
        let notes = projects.watchedMAC == board.macAddress ? projects.currentHardwareNotes : ""
        return "\(link.path)|\(code)|\(model?.id ?? "")|\(notes)"
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
    /// Set while a Wi-Fi pairing is saved; the pairing's only control.
    var forgetWiFi: (() -> Void)?

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: board.transport == .wifi ? "wifi" : "cpu")
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
                // Inline picker so the current model carries a checkmark.
                Picker("Board Model", selection: Binding(
                    get: { model },
                    set: { identities.assign($0, to: board) })) {
                    ForEach(BoardCatalog.candidates(for: board)) { c in
                        Text(c.name).tag(Optional(c))
                    }
                }
                .pickerStyle(.inline)
                if model != nil {
                    Divider()
                    Button("Forget Model") { identities.assign(nil, to: board) }
                }
            }
            if let forgetWiFi {
                Divider()
                Button("Forget Wi-Fi Pairing", action: forgetWiFi)
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
        if board.transport == .wifi { return "Wi-Fi · Read-only · \(board.port)" }
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
        if board.transport == .wifi {
            return "\(board.port)\nPaired board \(board.macAddress ?? "")\nRead-only Wi-Fi; uploads require USB."
        }
        var lines = [board.port, "\(board.vidPid) · \(board.interfaceDescription)"]
        if let mac = board.macAddress { lines.append("MAC \(mac)") }
        if let c = board.connection, let speed = c.speed { lines.append(speed.description) }
        lines.append(board.macPort.map { "Directly to Mac · \($0.name)" }
                     ?? board.connection?.pathDescription ?? "")
        if model != nil { lines.append("Right-click to change the board model") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct DisconnectedStateView: View {
    let otherPorts: [String]
    let blockedPorts: [String]
    let wireless: WirelessController

    var body: some View {
        VStack(spacing: 12) {
            EmptyState(otherPorts: otherPorts, blockedPorts: blockedPorts)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WirelessStatusView(wireless: wireless)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// No board: the system empty-state view, plus the accessory-security hint
/// when macOS is blocking a device's data connection.
private struct EmptyState: View {
    let otherPorts: [String]
    let blockedPorts: [String]
    @State private var showPorts = false

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label("No Board Connected", systemImage: "cable.connector.slash")
            } description: {
                Text("Plug in an ESP32 with a USB data cable, or connect a paired board over Wi-Fi.")
            } actions: {
                if !otherPorts.isEmpty {
                    Button("Connection details", systemImage: "info.circle") {
                        showPorts.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connection-details")
                    .popover(isPresented: $showPorts) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Detected serial ports").font(.headline)
                                ForEach(otherPorts, id: \.self) { port in
                                    Text(port).font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .textSelection(.enabled)
                            .padding(16)
                        }
                        .frame(width: 320, height: 180)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(minHeight: 260)
    }
}
