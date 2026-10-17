import SwiftUI

/// Anchors of everything a wire attaches to, keyed "board:<pin label>",
/// "board:body", "part:<id>:<pin name>" and "part:<id>:body". Published by the pin
/// labels (PinoutView) and the part's header pads, read by `WiresOverlay`.
struct WireAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension PartConnection {
    func sourceLabel(parts: [DetectedPart]) -> String {
        if let id = end.partID {
            return "\(parts.first(where: { $0.id == id })?.part.name ?? id) \(end.boardPin)"
        }
        return "\(end.boardPin)\(end.gpio.map { " · GPIO\($0)" } ?? "")"
    }

    func label(destination: DetectedPart, parts: [DetectedPart]) -> String {
        "\(sourceLabel(parts: parts)) → \(destination.part.name) \(partPin)"
    }

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
        case "+": .red
        case "−": .blue
        case "1": .teal
        case "2": end.boardPin == "GND" ? .gray : .red
        default: .primary   // GND
        }
    }
}

// MARK: - Part board

struct ComponentInfoButton: View {
    let name: String
    let summary: String
    let resources: [ComponentResource]
    var note: String? = nil
    @State private var isPresented = false
    @Environment(\.boardStyle) private var style

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(style == .blueprint ? AnyShapeStyle(Blueprint.ink) : AnyShapeStyle(.secondary))
                .padding(4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(name)")
        .accessibilityIdentifier("component-info-\(name)")
        .help("Component information and documentation")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(name).font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
                ForEach(resources) { resource in
                    Link(destination: resource.url) {
                        Label(resource.title, systemImage: resource.symbol)
                    }
                }
                if resources.isEmpty {
                    Text("No wiki or schematic is catalogued for this component.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(width: 300, alignment: .leading)
        }
    }
}

struct PartCellView: View {
    let detected: DetectedPart
    let pitch: CGFloat
    @Environment(\.boardStyle) private var style

    var body: some View {
        Group {
            switch detected.id {
            case PartModel.max98357a.id:
                PartBoardView(detected: detected, pitch: pitch)
            case PartModel.speaker.id:
                SpeakerPartView(detected: detected)
            default:
                VolumeButtonView(detected: detected)
            }
        }
        .padding(.vertical, 24)
        .frame(width: 330)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(style == .blueprint ? Blueprint.paper : Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style == .blueprint ? Blueprint.faint.opacity(0.5) : Color.primary.opacity(0.1),
                                      lineWidth: 1)
                }
        }
        .overlay(alignment: .topTrailing) {
            ComponentInfoButton(
                name: detected.part.modelName.map { "\(detected.part.name) · \($0)" } ?? detected.part.name,
                summary: detected.part.summary,
                resources: detected.part.resources,
                note: detected.id == PartModel.max98357a.id
                    ? "The schematic is an Adafruit reference design; your breakout may differ."
                    : "Identity comes from project source or notes. Physical wiring is not detected.")
                .padding(6)
        }
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):cell"] = $1 }
    }
}

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
                            .anchorPreference(key: WireAnchorKey.self, value: .bounds) { ["part:\(detected.id):\(pin.name)": $0] }
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
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):body"] = $1 }
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
                .anchorPreference(key: WireAnchorKey.self, value: .bounds) {
                    ["part:\(detected.id):OUT\(sign)": $0]
                }
            }
        }
        .help("Speaker: 4–8 Ω")
    }
}

struct VolumeButtonView: View {
    let detected: DetectedPart
    @Environment(\.boardStyle) private var style

    var body: some View {
        VStack(spacing: 6) {
            PartContacts(detected: detected)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(lineWidth: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(lineWidth: 1)
                        .padding(7)
                }
                .frame(width: 44, height: 34)
                .background(.quaternary, in: .rect(cornerRadius: 6))
            Text(detected.part.name)
                .font(.system(size: 10, weight: .semibold))
            if let model = detected.part.modelName {
                Text(model).font(.system(size: 9))
            }
        }
        .padding(.vertical, 8)
        .frame(width: 150)
        .foregroundStyle(style == .blueprint ? AnyShapeStyle(Blueprint.ink) : AnyShapeStyle(.primary))
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):body"] = $1 }
        .accessibilityElement(children: .combine)
    }
}

struct SpeakerPartView: View {
    let detected: DetectedPart
    @Environment(\.boardStyle) private var style

    var body: some View {
        VStack(spacing: 6) {
            PartContacts(detected: detected)
            Image(systemName: "hifispeaker")
                .font(.system(size: 30))
            Text(detected.part.name).font(.caption)
            if detected.part == .daytonPC83 {
                Text(detected.part.summary).font(.system(size: 10))
            }
            Text("Wiring assumed · OUT− is not GND")
                .font(.system(size: 9))
        }
        .padding(10)
        .foregroundStyle(style == .blueprint ? AnyShapeStyle(Blueprint.ink) : AnyShapeStyle(.primary))
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):body"] = $1 }
        .accessibilityElement(children: .combine)
    }
}

private struct PartContacts: View {
    let detected: DetectedPart

    var body: some View {
        HStack(spacing: 16) {
            ForEach(detected.part.pins, id: \.name) { pin in
                VStack(spacing: 2) {
                    Circle().strokeBorder(lineWidth: 1.5).frame(width: 12, height: 12)
                        .anchorPreference(key: WireAnchorKey.self, value: .bounds) {
                            ["part:\(detected.id):\(pin.name)": $0]
                        }
                    Text(pin.name).font(.system(size: 9, design: .monospaced))
                }
                .help(pin.detail)
            }
        }
    }
}

// MARK: - Wires

struct WireHighlight {
    var hoveredID: String?
    var selectedID: String?
    var activeID: String? { hoveredID ?? selectedID }

    mutating func toggle(_ id: String) {
        selectedID = selectedID == id ? nil : id
    }
}

/// Draws every connection as an orthogonal wire: out from the pin label to a
/// lane beside the diagram, down to the destination cell, then onto its pad.
/// Long runs stay outside the stacked cells so they don't cross other parts.
struct WiresOverlay: View {
    let parts: [DetectedPart]
    let anchors: [String: Anchor<CGRect>]
    let model: BoardModel
    @Binding var highlight: WireHighlight

    private let laneGap: CGFloat = 6
    static let busGap: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let routes = routes(proxy)
            ZStack {
                ForEach(routes, id: \.id) { r in
                    let active = highlight.activeID == r.id
                    ZStack {
                        r.path.stroke(r.connection.color,
                                      style: StrokeStyle(lineWidth: active ? 4 : 2, lineCap: .round, lineJoin: .round,
                                                         dash: r.connection.isAssumed ? [5, 4] : []))
                        Circle().fill(r.connection.color).frame(width: active ? 10 : 6, height: active ? 10 : 6).position(r.start)
                        Circle().fill(r.connection.color).frame(width: active ? 10 : 6, height: active ? 10 : 6).position(r.end)
                    }
                    .opacity(highlight.activeID == nil || active ? 0.95 : 0.18)
                    .zIndex(active ? 1 : 0)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(r.label)
                    .accessibilityValue(highlight.selectedID == r.id ? "Selected" : "Not selected")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { highlight.toggle(r.id) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Path { shape in
                for route in routes {
                    shape.addPath(route.path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round)))
                }
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): highlight.hoveredID = Self.closestRoute(to: point, in: routes)?.id
                case .ended: highlight.hoveredID = nil
                }
            }
            .onTapGesture { point in
                if let route = Self.closestRoute(to: point, in: routes) { highlight.toggle(route.id) }
            }
            .help(routes.first(where: { $0.id == highlight.activeID })?.label ?? "Hover to trace a wire; click to keep it highlighted.")
            .onDisappear { highlight.hoveredID = nil }
        }
    }

    struct Route {
        let id: String
        let connection: PartConnection
        let label: String
        let start: CGPoint
        let bends: [CGPoint]
        let end: CGPoint

        var path: Path {
            Path { path in
                path.move(to: start)
                for point in bends { path.addLine(to: point) }
                path.addLine(to: end)
            }
        }

        func distance(to point: CGPoint) -> CGFloat {
            zip([start] + bends, bends + [end]).map { a, b in
                let dx = b.x - a.x, dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
                return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
            }.min() ?? .infinity
        }
    }

    static func closestRoute(to point: CGPoint, in routes: [Route]) -> Route? {
        guard let nearest = routes.min(by: { $0.distance(to: point) < $1.distance(to: point) }),
              nearest.distance(to: point) <= 8 else { return nil }
        return nearest
    }

    private func routes(_ proxy: GeometryProxy) -> [Route] {
        func rect(_ key: String) -> CGRect? { anchors[key].map { proxy[$0] } }
        guard let boardBody = rect("board:body") else { return [] }

        let leftLabels = model.pins(on: .left).compactMap { rect("board:\($0.label)") }
        let rightLabels = model.pins(on: .right).compactMap { rect("board:\($0.label)") }
        let leftEdge = (leftLabels.map(\.minX).min() ?? boardBody.minX) - laneGap - 3
        let rightEdge = (rightLabels.map(\.maxX).max() ?? boardBody.maxX) + laneGap + 3

        struct Wire {
            let id: String
            let c: PartConnection
            let part: DetectedPart
            let label: CGRect
            let pad: CGRect
            let cell: CGRect
            let side: Pin.Side
            let index: Int
        }
        let wires: [Wire] = parts.flatMap { part in
            part.connections.enumerated().compactMap { index, c -> Wire? in
                guard c.end.partID == nil,
                      let pin = model.pins.first(where: { $0.label == c.end.boardPin }),
                      let label = rect("board:\(pin.label)"), let pad = rect("part:\(part.id):\(c.partPin)"),
                      let cell = rect("part:\(part.id):cell") else { return nil }
                return Wire(id: "\(part.id):\(c.id)", c: c, part: part, label: label, pad: pad, cell: cell, side: pin.side, index: index)
            }
        }
        // Lowest pin first → inner lane, highest bus level.
        let left = wires.filter { $0.side == .left }.sorted { $0.label.midY > $1.label.midY }
        let right = wires.filter { $0.side == .right }.sorted { $0.label.midY > $1.label.midY }

        var result: [Route] = []
        for (k, w) in (left + right).enumerated() {
            let isLeft = w.side == .left
            let lane = isLeft ? leftEdge - CGFloat(k) * laneGap
                              : rightEdge + CGFloat(k - left.count) * laneGap
            let busY = w.cell.minY - 12 - CGFloat(w.index) * Self.busGap
            // Start just outside the label text, not on it.
            let start = CGPoint(x: isLeft ? w.label.minX - 3 : w.label.maxX + 3, y: w.label.midY)
            let end = CGPoint(x: w.pad.midX, y: w.pad.midY)
            result.append(Route(id: w.id, connection: w.c, label: w.c.label(destination: w.part, parts: parts),
                                start: start, bends: [CGPoint(x: lane, y: start.y), CGPoint(x: lane, y: busY),
                                                      CGPoint(x: end.x, y: busY)], end: end))
        }
        for part in parts {
            for (index, c) in part.connections.enumerated() {
                guard let sourceID = c.end.partID,
                      let source = rect("part:\(sourceID):\(c.end.boardPin)"),
                      let sourceCell = rect("part:\(sourceID):cell"),
                      let destinationCell = rect("part:\(part.id):cell"),
                      let destination = rect("part:\(part.id):\(c.partPin)") else { continue }
                let start = CGPoint(x: source.midX, y: source.maxY)
                let end = CGPoint(x: destination.midX, y: destination.midY)
                let lane = sourceCell.maxX + 9 + CGFloat(index) * Self.busGap
                let exitY = source.maxY + 8 + CGFloat(index) * Self.busGap
                let busY = destinationCell.minY - 12 - CGFloat(index) * Self.busGap
                result.append(Route(id: "\(part.id):\(c.id)", connection: c, label: c.label(destination: part, parts: parts),
                                    start: start, bends: [CGPoint(x: start.x, y: exitY), CGPoint(x: lane, y: exitY),
                                                          CGPoint(x: lane, y: busY), CGPoint(x: end.x, y: busY)], end: end))
            }
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
    let parts: [DetectedPart]
    @Binding var highlight: WireHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(detected.connections) { c in
                let id = "\(detected.id):\(c.id)"
                Button { highlight.toggle(id) } label: {
                    HStack(spacing: 6) {
                        Capsule().fill(c.color).frame(width: 14, height: 4)
                        Text("\(c.partPin)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 36, alignment: .leading)
                        Text("← \(c.sourceLabel(parts: parts))")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: c.end.partID == nil ? 110 : 180, alignment: .leading)
                        Text(source(c))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(highlight.activeID == id ? c.color.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
                .onHover { hovering in
                    if hovering { highlight.hoveredID = id }
                    else if highlight.hoveredID == id { highlight.hoveredID = nil }
                }
                .accessibilityLabel(c.label(destination: detected, parts: parts))
                .accessibilityValue(highlight.selectedID == id ? "Selected" : "Not selected")
                .help(help(c))
            }
            if detected.id == PartModel.max98357a.id && !detected.namedInCode {
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
