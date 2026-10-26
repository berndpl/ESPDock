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
        case "Vin", "5V", "3V3", "BAT+": .red
        case "SCK": .orange
        case "MOSI": .green
        case "CS": .purple
        case "DC": .blue
        case "RST": .teal
        case "BUSY": .pink
        case "FPC", "B2B": .indigo
        case "GND", "BAT-", "-": .gray
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
                .foregroundStyle(style.isLineDrawing ? AnyShapeStyle(style.ink) : AnyShapeStyle(.secondary))
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
            case "volume-up", "volume-down":
                VolumeButtonView(detected: detected)
            default:
                DocumentedPartView(detected: detected)
            }
        }
        .padding(.vertical, 24)
        .frame(width: 330)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(style.isLineDrawing ? style.paper : Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style.isLineDrawing ? style.faint.opacity(0.5) : Color.primary.opacity(0.1),
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
                    : "Identity comes from project source, notes or hardware.json. Physical wiring is not detected.")
                .padding(6)
        }
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):cell"] = $1 }
    }
}

struct DocumentedPartView: View {
    let detected: DetectedPart
    @Environment(\.boardStyle) private var style

    var body: some View {
        VStack(spacing: 10) {
            DocumentedPartIllustration(kind: detected.part.kind)
                .accessibilityHidden(true)
            Text(detected.part.name).font(.caption.bold()).multilineTextAlignment(.center)
            Text(detected.part.summary)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !detected.part.pins.isEmpty {
                Text("Functional terminals · not physical pin order")
                    .font(.system(size: 9))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(Array(detected.part.pins.enumerated()), id: \.element.name) { index, pin in
                        HStack(spacing: 6) {
                            if index.isMultiple(of: 2) { terminal(pin) }
                            else { Spacer(minLength: 0) }
                            Text(pin.name).font(.system(size: 10, design: .monospaced))
                            if index.isMultiple(of: 2) { Spacer(minLength: 0) }
                            else { terminal(pin) }
                        }
                        .help(pin.detail)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .foregroundStyle(style.isLineDrawing ? AnyShapeStyle(style.ink) : AnyShapeStyle(.primary))
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):body"] = $1 }
        .accessibilityElement(children: .contain)
    }

    private func terminal(_ pin: PartPin) -> some View {
        Circle().strokeBorder(lineWidth: 1.5).frame(width: 12, height: 12)
            .anchorPreference(key: WireAnchorKey.self, value: .bounds) {
                ["part:\(detected.id):\(pin.name)": $0]
            }
    }
}

/// Reusable silhouettes, not model-specific dimensions or connector placement.
private struct DocumentedPartIllustration: View {
    let kind: PartModel.Kind
    @Environment(\.boardStyle) private var style

    var body: some View {
        if kind == .carrier || kind == .generic {
            Image(systemName: kind == .carrier ? "cpu" : "square.stack.3d.up")
                .font(.system(size: 30))
        } else {
            Canvas { context, _ in
                let ink = style.isLineDrawing ? style.ink : Color.primary.opacity(0.75)
                let metal = style.isLineDrawing ? style.paper : Color.gray.opacity(0.2)
                let pcb = style.isLineDrawing ? style.paper : Color(red: 0.12, green: 0.35, blue: 0.27)
                func panel(_ rect: CGRect, radius: CGFloat = 3, fill: Color) {
                    let path = Path(roundedRect: rect, cornerSize: CGSize(width: radius, height: radius))
                    context.fill(path, with: .color(fill))
                    context.stroke(path, with: .color(ink), lineWidth: 1.5)
                }
                func line(_ points: [CGPoint], color: Color, width: CGFloat = 1.5) {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                switch kind {
                case .display:
                    panel(CGRect(x: 124, y: 80, width: 32, height: 25), fill: metal)
                    for x in stride(from: 129, through: 152, by: 5) {
                        line([CGPoint(x: x, y: 93), CGPoint(x: x, y: 103)], color: ink.opacity(0.6), width: 1)
                    }
                    panel(CGRect(x: 13, y: 8, width: 170, height: 80), radius: 5, fill: metal)
                    panel(CGRect(x: 21, y: 16, width: 154, height: 64), radius: 1,
                          fill: style.isLineDrawing ? style.paper : Color(white: 0.9))
                    line([CGPoint(x: 35, y: 35), CGPoint(x: 99, y: 35)], color: ink, width: 3)
                    line([CGPoint(x: 35, y: 49), CGPoint(x: 146, y: 49)], color: ink.opacity(0.4))
                    line([CGPoint(x: 35, y: 59), CGPoint(x: 121, y: 59)], color: ink.opacity(0.4))
                case .camera:
                    panel(CGRect(x: 81, y: 79, width: 34, height: 26), fill: metal)
                    panel(CGRect(x: 41, y: 9, width: 114, height: 80), radius: 5, fill: pcb)
                    for x in [49.0, 147.0] {
                        for y in [17.0, 81.0] {
                            context.stroke(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                                           with: .color(ink), lineWidth: 1)
                        }
                    }
                    panel(CGRect(x: 72, y: 23, width: 52, height: 52), radius: 5, fill: metal)
                    context.fill(Path(ellipseIn: CGRect(x: 77, y: 28, width: 42, height: 42)),
                                 with: .color(style.isLineDrawing ? style.paper : Color(white: 0.12)))
                    context.stroke(Path(ellipseIn: CGRect(x: 77, y: 28, width: 42, height: 42)),
                                   with: .color(ink), lineWidth: 2)
                    context.stroke(Path(ellipseIn: CGRect(x: 86, y: 37, width: 24, height: 24)),
                                   with: .color(style.isLineDrawing ? ink : .gray), lineWidth: 2)
                case .battery:
                    panel(CGRect(x: 22, y: 24, width: 117, height: 67), radius: 5, fill: metal)
                    panel(CGRect(x: 28, y: 29, width: 105, height: 57), radius: 3, fill: metal)
                    line([CGPoint(x: 139, y: 43), CGPoint(x: 156, y: 43), CGPoint(x: 166, y: 61),
                          CGPoint(x: 179, y: 61)], color: style.isLineDrawing ? ink : .red, width: 2)
                    line([CGPoint(x: 139, y: 52), CGPoint(x: 151, y: 52), CGPoint(x: 163, y: 70),
                          CGPoint(x: 179, y: 70)], color: style.isLineDrawing ? ink.opacity(0.65) : .gray, width: 2)
                    panel(CGRect(x: 177, y: 57, width: 13, height: 18), radius: 2, fill: metal)
                case .carrier, .generic:
                    break
                }
            }
            .frame(width: 196, height: 112)
            .help("Illustrative component shape; dimensions and connector positions are not verified.")
        }
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
            if style.isLineDrawing {
                shape.stroke(style.ink, lineWidth: 1.2)
            } else {
                shape.fill(pcb).shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
        .transformAnchorPreference(key: WireAnchorKey.self, value: .bounds) { $0["part:\(detected.id):body"] = $1 }
    }

    private var ink: Color { style.isLineDrawing ? style.ink : .white }

    private func pad(highlighted: Bool) -> some View {
        ZStack {
            Circle().fill(style.isLineDrawing ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(red: 0.85, green: 0.68, blue: 0.3)))
            Circle().strokeBorder(style.isLineDrawing ? style.ink : .clear, lineWidth: 1)
            Circle().fill(style.isLineDrawing ? style.ink.opacity(0.4) : .black.opacity(0.85))
                .padding(4)
        }
        .frame(width: 15, height: 15)
        .opacity(highlighted ? 1 : 0.55)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(style.isLineDrawing ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.black.opacity(0.85)))
            .overlay { RoundedRectangle(cornerRadius: 2).stroke(style.isLineDrawing ? style.ink : .gray.opacity(0.5), lineWidth: 0.8) }
            .frame(width: 22, height: 22)
    }

    /// Two-way screw terminal for the speaker.
    private var speakerTerminal: some View {
        HStack(spacing: 2) {
            ForEach(["+", "−"], id: \.self) { sign in
                VStack(spacing: 1) {
                    Circle().stroke(style.isLineDrawing ? style.ink : .black.opacity(0.6), lineWidth: 1)
                        .frame(width: 9, height: 9)
                    Text(sign).font(.system(size: 8, weight: .bold)).foregroundStyle(ink)
                }
                .frame(width: 16, height: 26)
                .background(style.isLineDrawing ? AnyShapeStyle(.clear) : AnyShapeStyle(Color(red: 0.25, green: 0.55, blue: 0.95)),
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
                .background(style == .schematic ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: 6))
            Text(detected.part.name)
                .font(.system(size: 10, weight: .semibold))
            if let model = detected.part.modelName {
                Text(model).font(.system(size: 9))
            }
        }
        .padding(.vertical, 8)
        .frame(width: 150)
        .foregroundStyle(style.isLineDrawing ? AnyShapeStyle(style.ink) : AnyShapeStyle(.primary))
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
        .foregroundStyle(style.isLineDrawing ? AnyShapeStyle(style.ink) : AnyShapeStyle(.primary))
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
    @Environment(\.boardStyle) private var style

    private let laneGap: CGFloat = 6
    static let busGap: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let routes = routes(proxy)
            ZStack {
                ForEach(routes, id: \.id) { r in
                    let active = highlight.activeID == r.id
                    let color = style == .schematic ? style.ink : r.connection.color
                    ZStack {
                        r.path.stroke(color,
                                      style: StrokeStyle(lineWidth: active ? 4 : 2, lineCap: .round, lineJoin: .round,
                                                         dash: r.connection.isAssumed ? [5, 4] : []))
                        Circle().fill(color).frame(width: active ? 10 : 6, height: active ? 10 : 6).position(r.start)
                        Circle().fill(color).frame(width: active ? 10 : 6, height: active ? 10 : 6).position(r.end)
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
                      let label = rect("board:\(c.end.boardPin)"), let pad = rect("part:\(part.id):\(c.partPin)"),
                      let cell = rect("part:\(part.id):cell") else { return nil }
                let side = model.pins.first(where: { $0.label == c.end.boardPin })?.side ?? .right
                return Wire(id: "\(part.id):\(c.id)", c: c, part: part, label: label, pad: pad, cell: cell, side: side, index: index)
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
            if case .documented = w.c.origin {
                let entry = end.x < w.cell.midX ? w.cell.minX - 9 - CGFloat(w.index) * 3
                                              : w.cell.maxX + 9 + CGFloat(w.index) * 3
                result.append(Route(
                    id: w.id, connection: w.c, label: w.c.label(destination: w.part, parts: parts),
                    start: start, bends: [CGPoint(x: lane, y: start.y), CGPoint(x: lane, y: busY),
                                          CGPoint(x: entry, y: busY), CGPoint(x: entry, y: end.y)], end: end))
                continue
            }
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
                if case .documented = c.origin {
                    let sourceLane = start.x < sourceCell.midX ? sourceCell.minX - 9 - CGFloat(index) * 3
                                                              : sourceCell.maxX + 9 + CGFloat(index) * 3
                    let entryLane = end.x < destinationCell.midX ? destinationCell.minX - 9 - CGFloat(index) * 3
                                                               : destinationCell.maxX + 9 + CGFloat(index) * 3
                    let bridgeY = destinationCell.minY - 12 - CGFloat(index) * Self.busGap
                    result.append(Route(
                        id: "\(part.id):\(c.id)", connection: c, label: c.label(destination: part, parts: parts),
                        start: start, bends: [CGPoint(x: sourceLane, y: start.y), CGPoint(x: sourceLane, y: bridgeY),
                                              CGPoint(x: entryLane, y: bridgeY), CGPoint(x: entryLane, y: end.y)], end: end))
                    continue
                }
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
        case let .documented(file, _): file
        case .assumed: "assumed"
        }
    }

    private func help(_ c: PartConnection) -> String {
        let pin = detected.part.pins.first { $0.name == c.partPin }?.detail ?? ""
        switch c.origin {
        case let .code(file, line, expr): return "\(pin)\n\(expr) — \(file):\(line)"
        case let .documented(file, note): return "\(pin)\n\(note) — \(file). Documented, not electrically verified."
        case let .assumed(why): return "\(pin)\n\(why)"
        }
    }
}
