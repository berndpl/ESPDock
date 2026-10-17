import SwiftUI

/// Inspector content: live serial output with send field. Stock controls only.
struct SerialMonitorView: View {
    let monitor: SerialMonitor
    @State private var input = ""
    @State private var autoscroll = true
    @State private var copyFailed = false
    @AppStorage("serialShowTimestamps") private var showTimestamps = true

    var body: some View {
        @Bindable var monitor = monitor
        VStack(spacing: 0) {
            HStack {
                statusLabel
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(monitor.lines) { line in
                            row(line).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
                }
                .overlay {
                    if monitor.lines.isEmpty { emptyState }
                }
                .onChange(of: monitor.lines.last?.id) { _, last in
                    if autoscroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(monitor.isWireless ? "Wi-Fi monitoring is read-only" : "Send to board", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .disabled(!isOpen)
                Toggle("Autoscroll", isOn: $autoscroll)
                    .toggleStyle(.checkbox)
            }
            .padding(10)
        }
        // Controls go in the window toolbar, above the inspector column.
        .toolbar {
            ToolbarItemGroup {
                Picker("Baud", selection: $monitor.baud) {
                    ForEach(SerialMonitor.baudRates, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .help("Baud rate (ignored by native-USB boards like the ESP32-S3)")
                .disabled(monitor.isWireless)
                Toggle(isOn: $monitor.paused) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .help("Pause incoming output")
                Toggle(isOn: $showTimestamps) {
                    Label("Timestamps", systemImage: "clock")
                }
                .help("Show timestamps")
                Button { monitor.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear output")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    copyFailed = !copyOutput(showTimestamps: showTimestamps)
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }
                .help("Copy all buffered output to the clipboard")
                .accessibilityIdentifier("copy-monitor-output")
                .disabled(monitor.lines.isEmpty)
            }
        }
        .alert("Couldn't Copy Output", isPresented: $copyFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard couldn't be updated. Please try again.")
        }
    }

    func copyOutput(showTimestamps: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        let output = monitor.outputText(showTimestamps: showTimestamps)
        pasteboard.clearContents()
        return pasteboard.setString(output, forType: .string)
    }

    private func row(_ line: SerialMonitor.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTimestamps {
                Text(line.time, format: SerialMonitor.Line.timestampFormat)
                    .foregroundStyle(.tertiary)
            }
            Text(line.displayText)
                .foregroundStyle(line.outgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var isOpen: Bool {
        if case .open = monitor.status { return true }
        return false
    }

    @ViewBuilder private var statusLabel: some View {
        switch monitor.status {
        case .open(let port):
            Label((port as NSString).lastPathComponent, systemImage: "circle.fill")
                .labelStyle(StatusDot(color: .green))
        case .wireless(let endpoint):
            Label("Wi-Fi · \(endpoint) · Read-only", systemImage: "circle.fill")
                .labelStyle(StatusDot(color: .green))
        case .waiting:
            Label("Waiting for board…", systemImage: "circle.fill")
                .labelStyle(StatusDot(color: .orange))
        case .failed(let message):
            Label(message, systemImage: "circle.fill")
                .labelStyle(StatusDot(color: .red))
                .lineLimit(1)
        case .closed:
            Label("Closed", systemImage: "circle.fill")
                .labelStyle(StatusDot(color: .secondary))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Output Yet", systemImage: "apple.terminal")
        } description: {
            Text(monitor.isWireless
                 ? "ESPDock::log() output appears here after Wi-Fi connects. Early boot and dropped lines require USB."
                 : "Serial.print() output from the board appears here.")
        }
    }

    private func send() {
        guard !input.isEmpty else { return }
        monitor.send(input)
        input = ""
    }
}

/// Small coloured status dot before the text.
private struct StatusDot: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.font(.callout)
        }
    }
}
