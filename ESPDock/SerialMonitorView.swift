import SwiftUI

/// Inspector content: the board's live output. Deliberately few controls
/// (baud, pause, clear, copy, all in the toolbar): no timestamps (firmware
/// logs carry their own), no send field, and no autoscroll switch. Output
/// follows new lines while you're at the bottom and stops following when
/// you scroll up to read, like Console and Terminal.
struct SerialMonitorView: View {
    let monitor: SerialMonitor
    @State private var copyFailed = false
    /// True while the view is scrolled to the bottom.
    @State private var following = true

    /// Bottom-ness plus content height, so a change caused by new output
    /// (height grows) can be told apart from the user scrolling.
    private struct ScrollState: Equatable {
        var atBottom: Bool
        var contentHeight: CGFloat
    }

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
                .onScrollGeometryChange(for: ScrollState.self) { g in
                    ScrollState(atBottom: g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24,
                                contentHeight: g.contentSize.height)
                } action: { old, new in
                    // Only the user's own scrolling changes following; growth
                    // from new output must not switch it off.
                    if old.contentHeight == new.contentHeight { following = new.atBottom }
                }
                .onChange(of: monitor.lines.last?.id) { _, last in
                    if following, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
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
                Button { monitor.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Clear output")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    copyFailed = !copyOutput(showTimestamps: false)   // copy what's shown
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
        Text(line.displayText)
            .foregroundStyle(line.outgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .font(.system(size: 11, design: .monospaced))
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
