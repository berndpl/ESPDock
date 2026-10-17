import SwiftUI

/// Anchors of everything a wire attaches to, keyed "board:<pin label>",
/// "board:body", "part:<pin name>" and "part:body". Published by the pin
/// labels (PinoutView) and the part's header pads, read by `WiresOverlay`.
struct WireAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension PartConnection {
    /// One colour per signal, so a wire can be followed and matched to the
    /// legend. Power red and ground neutral, as on a breadboard.
    var color: Color {
        switch partPin {
        case "BCLK": .orange
        case "LRC": .blue
        case "DIN": .green
        case "SD": .purple
        case "GAIN": .brown
        case "Vin": .red
        default: .primary   // GND
        }
    }
}

// MARK: - Part board

/// The external part drawn as a breakout board: header pads along the top
/// edge (in the part's physical order) with the silkscreen names under them.
/// Schematic-style, not to scale — a to-scale MAX98357A breakout would make
/// the card twice as tall for no debugging benefit.
struct PartBoardView: View {
    let detected: DetectedPart
    let pitch: CGFloat
    @Environment(\.boardStyle) private var style

    private let pcb = Color(red: 0.16, green: 0.15, blue: 0.42)   // breakout blue-violet

    var body: some View {
        let connected = Set(detected.connections.map(\.partPin))
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(detected.part.pins, id: \.name) { pin in
                    VStack(spacing: 3) {
                        pad(highlighted: connected.contains(pin.name))
                            .anchorPreference(key: WireAnchorKey.self, value: .bounds) { ["part:\(pin.name)": $0] }
                        Text(pin.name)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ink.opacity(connected.contains(pin.name) ? 1 : 0.6))
                    }
                    .frame(width: pitch)
                    .help("\(pin.name): \(pin.detail)")
                }
            }
            HStack(spacing: 14) {
                chip
                VStack(alignment: .leading, spacing: 1) {
                    Text(detected.part.name)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text("I²S amp")
                        .font(.system(size: 9, design: .monospaced))
                        .opacity(0.7)
                }
                .foregroundStyle(ink)
                Spacer(minLength: 0)
                speakerTerminal
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: pitch * CGFloat(detected.part.pins.count) + 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8)
            if style == .blueprint {
                shape.stroke(Blueprint.ink, lineWidth: 1.2)
            } else {
                shape.fill(pcb).shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:body"] = $1 }
    }

    private var ink: Color { style == .blueprint ? Blueprint.ink : .white }

    private func pad(highlighted: Bool) -> some View {
        ZStack {
            Circle().fill(style == .blueprint ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(red: 0.85, green: 0.68, blue: 0.3)))
            Circle().strokeBorder(style == .blueprint ? Blueprint.ink : .clear, lineWidth: 1)
            Circle().fill(style == .blueprint ? Blueprint.ink.opacity(0.4) : .black.opacity(0.85))
                .padding(4)
        }
        .frame(width: 15, height: 15)
        .opacity(highlighted ? 1 : 0.55)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(style == .blueprint ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.black.opacity(0.85)))
            .overlay { RoundedRectangle(cornerRadius: 2).stroke(style == .blueprint ? Blueprint.ink : .gray.opacity(0.5), lineWidth: 0.8) }
            .frame(width: 22, height: 22)
    }

    /// Two-way screw terminal for the speaker.
    private var speakerTerminal: some View {
        HStack(spacing: 2) {
            ForEach(["+", "−"], id: \.self) { sign in
                VStack(spacing: 1) {
                    Circle().stroke(style == .blueprint ? Blueprint.ink : .black.opacity(0.6), lineWidth: 1)
                        .frame(width: 9, height: 9)
                    Text(sign).font(.system(size: 8, weight: .bold)).foregroundStyle(ink)
                }
                .frame(width: 16, height: 26)
                .background(style == .blueprint ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(red: 0.25, green: 0.55, blue: 0.95)),
                            in: .rect(cornerRadius: 2))
            }
        }
        .help("Speaker: 4–8 Ω")
    }
}

// MARK: - Wires

/// Draws every connection as an orthogonal wire: out from the pin label to a
/// lane beside the diagram, down into the bus area under the XIAO, across to
/// the part pin, and down onto its pad. Lane order: the higher a pin sits on
/// the board, the further out its lane and the lower its bus level. Then no
/// wire crosses another next to the pin labels (the busiest spot); crossings
/// that the pin order makes unavoidable land in the open bus area instead.
struct WiresOverlay: View {
    let detected: DetectedPart
    let anchors: [String: Anchor<CGRect>]
    let model: BoardModel

    private let laneGap: CGFloat = 6
    static let busGap: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let routes = routes(proxy)
            ZStack {
                ForEach(routes, id: \.connection.partPin) { r in
                    r.path.stroke(r.connection.color.opacity(0.9),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round,
                                                     dash: r.connection.isAssumed ? [5, 4] : []))
                    Circle().fill(r.connection.color).frame(width: 6, height: 6).position(r.start)
                    Circle().fill(r.connection.color).frame(width: 6, height: 6).position(r.end)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the legend carries the same information as text
    }

    private struct Route {
        let connection: PartConnection
        let path: Path
        let start: CGPoint
        let end: CGPoint
    }

    private func routes(_ proxy: GeometryProxy) -> [Route] {
        func rect(_ key: String) -> CGRect? { anchors[key].map { proxy[$0] } }
        guard let boardBody = rect("board:body"), let partBody = rect("part:body") else { return [] }

        let leftLabels = model.pins(on: .left).compactMap { rect("board:\($0.label)") }
        let rightLabels = model.pins(on: .right).compactMap { rect("board:\($0.label)") }
        let leftEdge = (leftLabels.map(\.minX).min() ?? boardBody.minX) - laneGap - 3
        let rightEdge = (rightLabels.map(\.maxX).max() ?? boardBody.maxX) + laneGap + 3

        struct Wire { let c: PartConnection; let label: CGRect; let pad: CGRect; let side: Pin.Side }
        let wires: [Wire] = detected.connections.compactMap { c in
            guard let pin = model.pins.first(where: { $0.label == c.end.boardPin }),
                  let label = rect("board:\(pin.label)"), let pad = rect("part:\(c.partPin)") else { return nil }
            return Wire(c: c, label: label, pad: pad, side: pin.side)
        }
        // Lowest pin first → inner lane, highest bus level.
        let left = wires.filter { $0.side == .left }.sorted { $0.label.midY > $1.label.midY }
        let right = wires.filter { $0.side == .right }.sorted { $0.label.midY > $1.label.midY }

        var result: [Route] = []
        let busTop = boardBody.maxY + 10
        for (k, w) in (left + right).enumerated() {
            let isLeft = w.side == .left
            let lane = isLeft ? leftEdge - CGFloat(k) * laneGap
                              : rightEdge + CGFloat(k - left.count) * laneGap
            let busY = min(busTop + CGFloat(k) * Self.busGap, partBody.minY - 6)
            // Start just outside the label text, not on it.
            let start = CGPoint(x: isLeft ? w.label.minX - 3 : w.label.maxX + 3, y: w.label.midY)
            let end = CGPoint(x: w.pad.midX, y: w.pad.midY)
            var p = Path()
            p.move(to: start)
            p.addLine(to: CGPoint(x: lane, y: start.y))
            p.addLine(to: CGPoint(x: lane, y: busY))
            p.addLine(to: CGPoint(x: end.x, y: busY))
            p.addLine(to: end)
            result.append(Route(connection: w.c, path: p, start: start, end: end))
        }
        return result
    }
}

// MARK: - Legend

/// The wiring as text: what goes where and which line of code says so, plus
/// anything that would stop the part from working. This is the part to read
/// when debugging; the drawing is for orientation.
struct WiringLegend: View {
    let detected: DetectedPart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(detected.connections) { c in
                HStack(spacing: 6) {
                    Capsule().fill(c.color).frame(width: 14, height: 4)
                    Text("\(c.partPin)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 36, alignment: .leading)
                    Text("← \(c.end.boardPin)\(c.end.gpio.map { " · GPIO\($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 110, alignment: .leading)
                    Text(source(c))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(help(c))
            }
            if !detected.namedInCode {
                Label("Inferred from an I²S output in the code; MAX98357A is the only I²S part ESPDock knows.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detected.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func source(_ c: PartConnection) -> String {
        switch c.origin {
        case let .code(file, line, _): "\((file as NSString).lastPathComponent):\(line)"
        case .assumed: "assumed"
        }
    }

    private func help(_ c: PartConnection) -> String {
        let pin = detected.part.pins.first { $0.name == c.partPin }?.detail ?? ""
        switch c.origin {
        case let .code(file, line, expr): return "\(pin)\n\(expr) — \(file):\(line)"
        case let .assumed(why): return "\(pin)\n\(why)"
        }
    }
}
