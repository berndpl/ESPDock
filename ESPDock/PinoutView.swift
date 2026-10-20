import SwiftUI

/// Pinout drawn natively from `BoardModel` data, to scale.
///
/// Geometry is in millimetres and converted with one scale factor, so the board
/// keeps its real proportions (XIAO: 21 × 17.8 mm, pins on the standard
/// 2.54 mm / 0.1" pitch, from the Seeed wiki). Label rows use the same pitch,
/// so every label lines up with its pad. Only the pin name and GPIO number are
/// shown; alternate functions (ADC, touch, I²C, SPI, UART) and warnings are in
/// each pin's hover popover (PinGuide), to keep the diagram calm.
struct PinoutView: View {
    let model: BoardModel
    /// External parts found in the linked project's code (PeripheralScanner),
    /// drawn under the board with wires. Empty → the card looks as before.
    var parts: [DetectedPart] = []

    /// Points per millimetre. 11 pt/mm → 28 pt pin pitch, roomy enough for labels.
    private let scale: CGFloat = 11
    @AppStorage("boardStyle") private var style: BoardStyle = .realistic
    @State private var highlight = WireHighlight()

    var body: some View {
        let geo = BoardGeometry(model: model, scale: scale)

        VStack(spacing: 14) {
            VStack(spacing: 0) {
                // spacing 0: leaders run right up to the board edge where the pads start
                HStack(alignment: .top, spacing: 0) {
                    sideColumn(.left, geo: geo)
                    BoardBody(model: model, geo: geo, style: style) { style = style.toggled }
                    sideColumn(.right, geo: geo)
                }
                .frame(maxWidth: .infinity)
                // Room for the blueprint's dimension line under the board; kept in
                // every style so cycling doesn't shift the layout.
                .padding(.top, 28)   // clears the 1.8 mm USB-C overhang
                .padding(.bottom, 30)
                .overlay(alignment: .topTrailing) {
                    ComponentInfoButton(name: model.name, summary: "\(model.chip) · \(model.sizeMM) mm",
                                        resources: [
                                            ComponentResource(title: "Seeed Wiki", url: model.referenceURL),
                                            ComponentResource(title: "Schematic (PDF)", url: model.schematicURL, symbol: "doc"),
                                        ])
                        .padding(8)
                }
                .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["board:body"] = $1 }

                if !parts.isEmpty {
                    ForEach(parts) { part in
                        Color.clear.frame(height: CGFloat(part.connections.count) * WiresOverlay.busGap + 20)
                        PartCellView(detected: part, pitch: geo.pitch)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                if !parts.isEmpty {
                    WiresOverlay(parts: parts, anchors: anchors, model: model, highlight: $highlight)
                }
            }
            .background {
                if style == .blueprint {
                    Blueprint.Paper(mm: scale)
                        .clipShape(.rect(cornerRadius: 12))
                        .transition(.opacity)
                }
            }

            // Outside the blueprint paper, so it stays readable in every style.
            if !parts.isEmpty {
                if let (part, connection) = selectedConnection {
                    HStack {
                        Text(connection.label(destination: part, parts: parts))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear highlight", systemImage: "xmark.circle") { highlight.selectedID = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(.horizontal, 8)
                }
                DisclosureGroup("Wiring details") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(parts) { part in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(part.part.name).font(.caption.bold())
                                WiringLegend(detected: part, parts: parts, highlight: $highlight)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 8)
            }
        }
        .environment(\.boardStyle, style)
        .animation(.easeInOut(duration: 0.25), value: style)
        .animation(.default, value: parts)
        .onChange(of: parts) { highlight = WireHighlight() }
    }

    private var selectedConnection: (DetectedPart, PartConnection)? {
        for part in parts {
            if let connection = part.connections.first(where: { "\(part.id):\($0.id)" == highlight.selectedID }) {
                return (part, connection)
            }
        }
        return nil
    }

    private func sideColumn(_ side: Pin.Side, geo: BoardGeometry) -> some View {
        VStack(alignment: side == .left ? .trailing : .leading, spacing: 0) {
            Color.clear.frame(height: geo.firstPinCenter - geo.pitch / 2)
            ForEach(model.pins(on: side)) { pin in
                PinLabel(pin: pin, side: side)
                    .anchorPreference(key: WireAnchorKey.self, value: .bounds) { ["board:\(pin.label)": $0] }
                    .frame(height: geo.pitch)
            }
        }
        .frame(width: 112, alignment: side == .left ? .trailing : .leading)
    }
}

private struct PinLabel: View {
    let pin: Pin
    let side: Pin.Side
    @Environment(\.boardStyle) private var style

    var body: some View {
        HStack(spacing: 4) {
            if side == .right { Leader() }
            if side == .left, let gpio = pin.gpio { gpioText(gpio) }
            Text(pin.label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(style == .schematic ? style.ink : .white)
                .frame(minWidth: 30)
                .padding(.vertical, 2)
                .background(style == .schematic ? .clear : pin.role.color, in: .rect(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style == .schematic ? style.ink : .clear, lineWidth: 1)
                }
            if side == .right, let gpio = pin.gpio { gpioText(gpio) }
            if side == .left { Leader() }
        }
        .pinGuide(PinGuide.forPin(pin), edge: side == .left ? .leading : .trailing)
    }

    private func gpioText(_ gpio: Int) -> some View {
        Text("GPIO\(gpio)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(style.isLineDrawing ? AnyShapeStyle(style.faint) : AnyShapeStyle(.secondary))
    }
}

private struct Leader: View {
    @Environment(\.boardStyle) private var style
    var body: some View {
        Rectangle()
            .fill(style.isLineDrawing ? AnyShapeStyle(style.faint) : AnyShapeStyle(.tertiary))
            .frame(width: 16, height: 1)
    }
}

extension PinRole {
    var color: Color {
        switch self {
        case .power: .red
        case .ground: .gray
        case .gpio: .green
        case .adc: .orange
        case .touch: .mint
        case .i2c: .blue
        case .spi: .purple
        case .uart: .indigo
        case .system: .secondary
        }
    }
}

extension EnvironmentValues {
    @Entry var boardStyle: BoardStyle = .realistic
}
