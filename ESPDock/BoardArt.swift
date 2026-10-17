import SwiftUI

/// How the board is drawn. Toggled by clicking the board; remembered in
/// UserDefaults ("boardStyle").
enum BoardStyle: String {
    case realistic, blueprint
    var toggled: BoardStyle { self == .realistic ? .blueprint : .realistic }
}

/// Real-world dimensions of the board, scaled to points.
struct BoardGeometry {
    let width: CGFloat
    let height: CGFloat
    let pitch: CGFloat
    let firstPinCenter: CGFloat
    let rows: Int
    let mm: CGFloat

    init(model: BoardModel, scale: CGFloat) {
        // XIAO form factor (all XIAO boards share it): 17.8 mm wide, 21 mm
        // long along the USB axis, 7 pins per side on a 2.54 mm pitch,
        // vertically centred.
        mm = scale
        width = 17.8 * scale
        height = 21 * scale
        pitch = 2.54 * scale
        rows = max(model.pins(on: .left).count, model.pins(on: .right).count)
        firstPinCenter = (height - CGFloat(rows - 1) * pitch) / 2
    }
}

/// Blueprint palette: classic white line work on cyanotype blue.
enum Blueprint {
    static let paper = Color(red: 0.11, green: 0.29, blue: 0.53)
    static let grid = Color.white.opacity(0.09)
    static let ink = Color.white.opacity(0.92)
    static let faint = Color.white.opacity(0.55)

    /// 1 mm grid with a stronger line every 5 mm, like engineering paper.
    struct Paper: View {
        let mm: CGFloat
        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Blueprint.paper))
                var minor = Path(), major = Path()
                func line(_ from: CGPoint, _ to: CGPoint, major isMajor: Bool) {
                    if isMajor { major.move(to: from); major.addLine(to: to) }
                    else { minor.move(to: from); minor.addLine(to: to) }
                }
                var i = 0
                var x: CGFloat = 0
                while x <= size.width {
                    line(.init(x: x, y: 0), .init(x: x, y: size.height), major: i % 5 == 0)
                    x += mm; i += 1
                }
                i = 0
                var y: CGFloat = 0
                while y <= size.height {
                    line(.init(x: 0, y: y), .init(x: size.width, y: y), major: i % 5 == 0)
                    y += mm; i += 1
                }
                ctx.stroke(minor, with: .color(Blueprint.grid), lineWidth: 0.5)
                ctx.stroke(major, with: .color(Blueprint.grid.opacity(2)), lineWidth: 0.75)
            }
        }
    }
}

/// Top view of the board at true proportions. Every part is a separate view
/// so each can carry its hover guide; positions are in millimetres measured
/// from Seeed's front photo (approximate for parts, exact for outline/pins).
struct BoardBody: View {
    let model: BoardModel
    let geo: BoardGeometry
    let style: BoardStyle
    let onToggleStyle: () -> Void

    var body: some View {
        let mm = geo.mm
        let left = model.pins(on: .left)
        let right = model.pins(on: .right)
        let padY = { (i: Int) in geo.firstPinCenter + CGFloat(i) * geo.pitch }

        ZStack(alignment: .topLeading) {
            pcb
                // Clicking bare board switches style; parts on top keep their
                // own click (pin guide), so they don't toggle.
                .contentShape(.rect)
                .onTapGesture(perform: onToggleStyle)
                .help("Click the board to switch between realistic and blueprint")

            if style == .realistic { passives }

            // Positions below are part centres in mm, measured from Seeed's
            // front render (XIAO_ESP32-S3_front_pinout.png, 7680 px, board
            // ≈ 19.4 px/mm after cropping): origin = top-left of the PCB.

            // RESET (left) and BOOT (right), beside the USB connector
            TactileSwitch(label: "R", style: style, mm: mm, labelSide: .leading)
                .pinGuide(.resetButton, edge: .top)
                .offset(x: (2.9 - 0.85) * mm, y: (1.6 - 0.95) * mm)
            TactileSwitch(label: "B", style: style, mm: mm, labelSide: .trailing)
                .pinGuide(.bootButton, edge: .top)
                .offset(x: (14.8 - 0.85) * mm, y: (1.6 - 0.95) * mm)

            // Charge LED (red, under R) and user LED (orange, under B)
            SMDLED(style: style, mm: mm, color: .red, lit: false)
                .padding(4)   // bigger hover target than the 1.6 mm part
                .pinGuide(.chargeLED, edge: .leading)
                .offset(x: (2.9 - 0.8) * mm - 4, y: (3.8 - 0.4) * mm - 4)
            SMDLED(style: style, mm: mm, color: .orange, lit: true)
                .padding(4)
                .pinGuide(.userLED, edge: .trailing)
                .offset(x: (14.8 - 0.8) * mm - 4, y: (3.8 - 0.4) * mm - 4)

            ModuleShield(style: style, mm: mm)
                .offset(x: (geo.width - 12.6 * mm) / 2, y: 6.5 * mm)
                .allowsHitTesting(false)

            UFLConnector(style: style, mm: mm)
                .pinGuide(.antenna, edge: .bottom)
                .offset(x: (4.0 - 1.3) * mm, y: (19.2 - 1.3) * mm)

            B2BConnector(style: style, mm: mm)
                .pinGuide(.b2bConnector, edge: .bottom)
                .offset(x: 7.2 * mm, y: 18.2 * mm)

            USBCReceptacle(style: style, mm: mm)
                .offset(x: (geo.width - 8.94 * mm) / 2, y: -1.8 * mm)
                .allowsHitTesting(false)

            // Edge pads: plated hole 1.15 mm in from the edge, pad running
            // out to the board edge (as on the real board, not a hole on the edge).
            ForEach(Array(left.enumerated()), id: \.offset) { i, _ in
                EdgePad(style: style, mm: mm, edge: .leading)
                    .offset(x: 0, y: padY(i) - 0.9 * mm)
            }
            ForEach(Array(right.enumerated()), id: \.offset) { i, _ in
                EdgePad(style: style, mm: mm, edge: .trailing)
                    .offset(x: geo.width - EdgePad.length * mm, y: padY(i) - 0.9 * mm)
            }

            if style == .blueprint { dimensions }
        }
        .frame(width: geo.width, height: geo.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: style)
    }

    // MARK: PCB

    @ViewBuilder private var pcb: some View {
        let shape = RoundedRectangle(cornerRadius: 1.4 * geo.mm)
        switch style {
        case .realistic:
            shape
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                // Edge plating / bevel catching light
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        case .blueprint:
            shape.fill(.clear).overlay(shape.stroke(Blueprint.ink, lineWidth: 1.25))
        }
    }

    /// A few 0402 passives — they make the board read as a real PCB at a
    /// glance. Placed where the photo shows parts, but not individually exact.
    private var passives: some View {
        let mm = geo.mm
        // 0402 parts flanking the LEDs and between antenna and B2B connector
        let spots: [(CGFloat, CGFloat, Bool)] = [
            (2.6, 5.0, true), (3.4, 5.0, true), (14.4, 5.0, true), (15.2, 5.0, true),
            (5.6, 18.3, false), (5.6, 19.3, false), (15.4, 18.8, true),
        ]
        return ForEach(Array(spots.enumerated()), id: \.offset) { _, s in
            Passive(mm: mm, vertical: s.2).offset(x: s.0 * mm, y: s.1 * mm)
        }
        .allowsHitTesting(false)
    }

    // MARK: Blueprint dimensions

    /// Width dimension under the board. The 21 mm length would have to run
    /// through the module or the label columns, so it's stated in the label.
    private var dimensions: some View {
        DimensionLine(length: geo.width, label: "17.8 mm · L 21.0", vertical: false)
            .offset(y: geo.height + 1.0 * geo.mm)
            .allowsHitTesting(false)
    }
}

// MARK: - Parts

/// Top-down USB-C receptacle (8.94 × 7.35 mm shell). From above you see the
/// flat top of the metal shell, the rolled front lip where the plug enters
/// (overhanging the board edge), the side solder tabs and two stamped
/// latch windows — not the oval opening, which faces sideways.
private struct USBCReceptacle: View {
    let style: BoardStyle
    let mm: CGFloat

    var body: some View {
        let w = 8.94 * mm, h = 7.5 * mm   // measured: −1.8 … 5.7 mm from PCB top
        ZStack(alignment: .top) {
            switch style {
            case .realistic:
                // Gold through-hole shell tabs (front pair + rear pair)
                ForEach([2.2, 6.2], id: \.self) { y in
                    HStack { tab; Spacer(); tab }
                        .frame(width: w + 1.3 * mm)
                        .offset(y: y * mm)
                }
                // Row of SMD signal legs along the rear edge
                HStack(spacing: 0.3 * mm) {
                    ForEach(0..<12, id: \.self) { _ in
                        Rectangle().fill(gold).frame(width: 0.3 * mm, height: 0.7 * mm)
                    }
                }
                .offset(y: h - 0.2 * mm)

                RoundedRectangle(cornerRadius: 0.7 * mm)
                    .fill(LinearGradient(stops: [
                        .init(color: Color(white: 0.58), location: 0),
                        .init(color: Color(white: 0.9), location: 0.18),
                        .init(color: Color(white: 0.78), location: 0.5),
                        .init(color: Color(white: 0.92), location: 0.82),
                        .init(color: Color(white: 0.6), location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: h)
                    .overlay(alignment: .top) {
                        // Rolled front lip: darker band where the shell curves down
                        UnevenRoundedRectangle(topLeadingRadius: 0.7 * mm, topTrailingRadius: 0.7 * mm)
                            .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.7)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(height: 1.1 * mm)
                    }
                    .overlay {
                        // Stamped latch windows near the rear
                        HStack(spacing: 2.6 * mm) {
                            latch; latch
                        }
                        .offset(y: 1.5 * mm)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 0.7 * mm)
                        .strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1.5)

            case .blueprint:
                let shell = RoundedRectangle(cornerRadius: 0.7 * mm)
                shell.stroke(Blueprint.ink, lineWidth: 1)
                    .frame(width: w, height: h)
                    .overlay(alignment: .top) {
                        // Front lip line + the plug's insertion arrow
                        Rectangle().fill(Blueprint.ink).frame(height: 0.75).offset(y: 1.1 * mm)
                    }
                    .overlay {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold))
                            Text("USB-C").font(.system(size: 8, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(Blueprint.faint)
                        .offset(y: 0.4 * mm)
                    }
            }
        }
        .frame(width: w, height: h, alignment: .top)
    }

    private var gold: LinearGradient {
        LinearGradient(colors: [Color(red: 0.97, green: 0.82, blue: 0.45),
                                Color(red: 0.76, green: 0.57, blue: 0.24)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var tab: some View {
        Capsule().fill(gold).frame(width: 1.1 * mm, height: 1.5 * mm)
    }

    private var latch: some View {
        RoundedRectangle(cornerRadius: 0.2 * mm)
            .fill(Color(white: 0.45))
            .frame(width: 0.9 * mm, height: 1.6 * mm)
    }
}

private struct TactileSwitch: View {
    let label: String
    let style: BoardStyle
    let mm: CGFloat
    let labelSide: HorizontalEdge

    var body: some View {
        // ~1.7 × 1.9 mm SMD switch: metal body, dark round plunger
        let w = 1.7 * mm, h = 1.9 * mm
        let caption = Text(style == .blueprint ? (label == "R" ? "RST" : "BOOT") : label)
            .font(style == .blueprint ? .system(size: 7, weight: .medium, design: .monospaced)
                                      : .system(size: 8, weight: .heavy))
            .foregroundStyle(style == .blueprint ? Blueprint.faint : .white.opacity(0.9))
            .fixedSize()

        Group {
            switch style {
            case .realistic:
                ZStack {
                    RoundedRectangle(cornerRadius: 0.2 * mm)
                        .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.6)],
                                             startPoint: .top, endPoint: .bottom))
                    Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.14)],
                                             center: .topLeading, startRadius: 0, endRadius: 1.1 * mm))
                        .frame(width: 0.95 * mm, height: 0.95 * mm)
                }
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            case .blueprint:
                ZStack {
                    RoundedRectangle(cornerRadius: 0.2 * mm).stroke(Blueprint.ink, lineWidth: 1)
                    Circle().stroke(Blueprint.ink, lineWidth: 0.75).frame(width: 0.95 * mm, height: 0.95 * mm)
                }
            }
        }
        .frame(width: w, height: h)
        // Silkscreen letter on the outer side, as on the board
        .overlay(alignment: labelSide == .leading ? .topLeading : .topTrailing) {
            caption
                .padding(.horizontal, style == .blueprint ? 2 : 0)
                .background(style == .blueprint ? Blueprint.paper : .clear)
                .offset(x: labelSide == .leading ? -1.1 * mm : 1.1 * mm,
                        y: style == .blueprint ? -1.0 * mm : 0)
        }
    }
}

/// 0603 SMD LED (1.6 × 0.8 mm) inside its white silkscreen outline.
private struct SMDLED: View {
    let style: BoardStyle
    let mm: CGFloat
    let color: Color
    let lit: Bool

    var body: some View {
        let w = 1.6 * mm, h = 0.8 * mm
        switch style {
        case .realistic:
            RoundedRectangle(cornerRadius: 0.1 * mm)
                .fill(lit ? color : color.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 0.08 * mm).fill(.white.opacity(lit ? 0.7 : 0.25))
                    .frame(width: 0.5 * mm, height: 0.22 * mm))
                .frame(width: w, height: h)
                .shadow(color: lit ? color : .clear, radius: 4)
                .padding(0.25 * mm)
                .overlay(RoundedRectangle(cornerRadius: 0.1 * mm).stroke(.white.opacity(0.75), lineWidth: 0.6))
        case .blueprint:
            // Schematic LED symbol: triangle + bar + emission arrow
            ZStack {
                Path { p in
                    p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: 8))
                    p.addLine(to: .init(x: 6, y: 4)); p.closeSubpath()
                    p.move(to: .init(x: 6, y: 0)); p.addLine(to: .init(x: 6, y: 8))
                }
                .stroke(Blueprint.ink, lineWidth: 0.9)
                Image(systemName: "arrow.up.right").font(.system(size: 4, weight: .bold))
                    .foregroundStyle(Blueprint.faint).offset(x: 6, y: -4)
            }
            .frame(width: 7, height: 7)
            .scaleEffect(0.85)
            .frame(width: w + 0.5 * mm, height: h + 0.5 * mm)   // centred in the footprint
        }
    }
}

private struct ModuleShield: View {
    let style: BoardStyle
    let mm: CGFloat

    var body: some View {
        let w = 12.6 * mm, h = 10.4 * mm
        let shape = RoundedRectangle(cornerRadius: 0.5 * mm)
        switch style {
        case .realistic:
            shape
                .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.66)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 0.75))
                .overlay {
                    // Laser-etched marking
                    VStack(spacing: 2) {
                        Text("seeed studio").font(.system(size: 8, weight: .bold))
                        Text("XIAO ESP32S3").font(.system(size: 9, weight: .semibold))
                        Text("ESP32-S3R8").font(.system(size: 7, design: .monospaced))
                    }
                    .foregroundStyle(Color(white: 0.38))
                }
                .overlay(alignment: .bottomTrailing) {
                    // Pin-1 style dot common on shield stampings
                    Circle().fill(Color(white: 0.55)).frame(width: 0.6 * mm, height: 0.6 * mm)
                        .padding(0.8 * mm)
                }
                .frame(width: w, height: h)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1.5)
        case .blueprint:
            shape.stroke(Blueprint.ink, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: w, height: h)
                .overlay {
                    VStack(spacing: 2) {
                        Text("ESP32-S3").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Text("RF SHIELD").font(.system(size: 7, design: .monospaced))
                    }
                    .foregroundStyle(Blueprint.faint)
                }
        }
    }
}

private struct UFLConnector: View {
    let style: BoardStyle
    let mm: CGFloat

    var body: some View {
        let s = 2.26 * mm   // U.FL footprint ≈ 2.6 mm square incl. base
        switch style {
        case .realistic:
            ZStack {
                RoundedRectangle(cornerRadius: 0.2 * mm)
                    .fill(Color(red: 0.86, green: 0.82, blue: 0.72)).frame(width: s * 1.15, height: s * 1.15)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.95, green: 0.8, blue: 0.45),
                                                  Color(red: 0.7, green: 0.52, blue: 0.2)],
                                         center: .topLeading, startRadius: 0, endRadius: s))
                    .frame(width: s, height: s)
                Circle().fill(Color(white: 0.2)).frame(width: s * 0.35, height: s * 0.35)
            }
            .frame(width: s * 1.15, height: s * 1.15)
        case .blueprint:
            ZStack {
                Circle().stroke(Blueprint.ink, lineWidth: 1)
                Path { p in
                    p.move(to: .init(x: s / 2, y: -2)); p.addLine(to: .init(x: s / 2, y: s + 2))
                    p.move(to: .init(x: -2, y: s / 2)); p.addLine(to: .init(x: s + 2, y: s / 2))
                }
                .stroke(Blueprint.faint, lineWidth: 0.5)
            }
            .frame(width: s, height: s)
            .overlay(alignment: .trailing) {
                Text("ANT").font(.system(size: 7, design: .monospaced)).foregroundStyle(Blueprint.faint)
                    .fixedSize().offset(x: 18)
            }
        }
    }
}

/// Edge pad as on the XIAO: a gold pad running from the board edge inward,
/// rounded at its inner end, with the plated through-hole 1.15 mm from the
/// edge (measured from Seeed's render).
struct EdgePad: View {
    static let length: CGFloat = 2.3   // mm, edge → inner end
    let style: BoardStyle
    let mm: CGFloat
    let edge: HorizontalEdge

    var body: some View {
        let h = 1.8 * mm, len = Self.length * mm
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .trailing ? h / 2 : 0,
            bottomLeadingRadius: edge == .trailing ? h / 2 : 0,
            bottomTrailingRadius: edge == .leading ? h / 2 : 0,
            topTrailingRadius: edge == .leading ? h / 2 : 0)
        let hole = Circle().frame(width: 0.95 * mm, height: 0.95 * mm)
        let holeX = edge == .leading ? 1.15 * mm - len / 2 : len / 2 - 1.15 * mm

        ZStack {
            switch style {
            case .realistic:
                shape.fill(LinearGradient(colors: [Color(red: 0.97, green: 0.82, blue: 0.45),
                                                   Color(red: 0.76, green: 0.57, blue: 0.24)],
                                          startPoint: .top, endPoint: .bottom))
                hole.foregroundStyle(Color(white: 0.07)).offset(x: holeX)
            case .blueprint:
                shape.stroke(Blueprint.ink, lineWidth: 0.9)
                hole.foregroundStyle(.clear)
                    .overlay(Circle().stroke(Blueprint.ink, lineWidth: 0.9))
                    .offset(x: holeX)
            }
        }
        .frame(width: len, height: h)
        .allowsHitTesting(false)
    }
}

/// Board-to-board connector along the bottom edge (for the Sense camera /
/// microSD expansion board): black body with two rows of gold contacts.
private struct B2BConnector: View {
    let style: BoardStyle
    let mm: CGFloat

    var body: some View {
        let w = 7.5 * mm, h = 2.0 * mm
        switch style {
        case .realistic:
            ZStack {
                RoundedRectangle(cornerRadius: 0.2 * mm).fill(Color(white: 0.06))
                VStack(spacing: 0.7 * mm) {
                    contacts; contacts
                }
            }
            .frame(width: w, height: h)
            .overlay(RoundedRectangle(cornerRadius: 0.2 * mm).stroke(.white.opacity(0.12), lineWidth: 0.5))
        case .blueprint:
            RoundedRectangle(cornerRadius: 0.2 * mm)
                .stroke(Blueprint.ink, style: StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
                .frame(width: w, height: h)
                .overlay(Text("B2B").font(.system(size: 7, design: .monospaced)).foregroundStyle(Blueprint.faint))
        }
    }

    private var contacts: some View {
        HStack(spacing: 0.22 * mm) {
            ForEach(0..<14, id: \.self) { _ in
                Rectangle().fill(Color(red: 0.9, green: 0.72, blue: 0.35))
                    .frame(width: 0.22 * mm, height: 0.35 * mm)
            }
        }
    }
}

private struct Passive: View {
    let mm: CGFloat
    let vertical: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.75)).frame(width: 0.25 * mm)
            Rectangle().fill(Color(red: 0.32, green: 0.24, blue: 0.16))
            Rectangle().fill(Color(white: 0.75)).frame(width: 0.25 * mm)
        }
        .frame(width: 1.0 * mm, height: 0.5 * mm)
        .rotationEffect(vertical ? .degrees(90) : .zero)
    }
}

/// Engineering dimension line with end ticks and a centred label (mm).
private struct DimensionLine: View {
    let length: CGFloat
    let label: String
    let vertical: Bool

    var body: some View {
        ZStack {
            Path { p in
                if vertical {
                    p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: length))
                    p.move(to: .init(x: -4, y: 0)); p.addLine(to: .init(x: 4, y: 0))
                    p.move(to: .init(x: -4, y: length)); p.addLine(to: .init(x: 4, y: length))
                } else {
                    p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: length, y: 0))
                    p.move(to: .init(x: 0, y: -4)); p.addLine(to: .init(x: 0, y: 4))
                    p.move(to: .init(x: length, y: -4)); p.addLine(to: .init(x: length, y: 4))
                }
            }
            .stroke(Blueprint.faint, lineWidth: 0.75)

            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(Blueprint.ink)
                .padding(.horizontal, 2)
                .background(Blueprint.paper)
                .rotationEffect(vertical ? .degrees(-90) : .zero)
                .position(x: vertical ? 0 : length / 2, y: vertical ? length / 2 : 0)
        }
        .frame(width: vertical ? 1 : length, height: vertical ? length : 1, alignment: .topLeading)
    }
}
