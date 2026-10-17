import SwiftUI

/// Inspector content: live serial output with send field. Stock controls only.
struct SerialMonitorView: View {
    let monitor: SerialMonitor
    @State private var input = ""
    @State private var autoscroll = true
    @AppStorage("serialShowTimestamps") private var showTimestamps = true

    var body: some View {
        @Bindable var monitor = monitor
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                statusLabel
                Spacer()
                Picker("Baud", selection: $monitor.baud) {
                    ForEach(SerialMonitor.baudRates, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Baud rate (ignored by native-USB boards like the ESP32-S3)")
                Toggle(isOn: $monitor.paused) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Pause incoming output")
                Toggle(isOn: $showTimestamps) {
                    Label("Timestamps", systemImage: "clock")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Show timestamps")
                Button { monitor.clear() } label: { Label("Clear", systemImage: "trash") }
                    .labelStyle(.iconOnly)
                    .help("Clear output")
            }
            .padding(10)

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
                TextField("Send to board", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .disabled(!isOpen)
                Toggle("Autoscroll", isOn: $autoscroll)
                    .toggleStyle(.checkbox)
            }
            .padding(10)
        }
    }

    private func row(_ line: SerialMonitor.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTimestamps {
                Text(line.time, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .foregroundStyle(.tertiary)
            }
            Text(line.outgoing ? "→ \(line.text)" : line.text)
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
            Text("Serial.print() output from the board appears here.")
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
