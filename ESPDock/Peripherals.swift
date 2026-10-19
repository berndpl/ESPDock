import Foundation

// MARK: - Parts catalog

/// A pin on an external part's header.
struct PartPin: Hashable, Sendable {
    let name: String      // silkscreen, e.g. "BCLK"
    let detail: String    // what it does, shown in the legend
}

struct ComponentResource: Hashable, Sendable, Identifiable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    var symbol: String = "book"
}

/// An external board ESPDock can recognise from code.
struct PartModel: Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    /// Header pins in physical order, left → right, as printed on the board.
    let pins: [PartPin]
    var modelName: String? = nil
    var resources: [ComponentResource] = []
    var speakerImpedanceOhms: Int? = nil

    // Pin names, order and meaning: Adafruit "MAX98357 I2S Class-D Mono Amp"
    // guide (pinouts page) and the Maxim MAX98357A datasheet. With the header
    // along the top edge as drawn, Vin is on the left and LRC on the right.
    // https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp/pinouts
    static let max98357a = PartModel(
        id: "max98357a",
        name: "MAX98357A",
        summary: "I²S class-D mono amplifier · 3 W into 4 Ω at 5 V",
        pins: [
            PartPin(name: "Vin", detail: "2.5–5.5 V. 5 V gives the most volume"),
            PartPin(name: "GND", detail: "Ground, shared with the XIAO"),
            PartPin(name: "SD", detail: "Shutdown / channel select. Low = off; floating = (L+R)/2"),
            PartPin(name: "GAIN", detail: "Unconnected = 9 dB; to GND = 12 dB; to Vin = 6 dB"),
            PartPin(name: "DIN", detail: "Audio data from the ESP32 (its DOUT)"),
            PartPin(name: "BCLK", detail: "Bit clock"),
            PartPin(name: "LRC", detail: "Word select (left/right clock), a.k.a. WS / LRCLK"),
        ],
        resources: [
            ComponentResource(title: "Adafruit guide", url: URL(string: "https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp")!),
            ComponentResource(title: "Reference breakout schematic", url: URL(string: "https://cdn-learn.adafruit.com/assets/assets/000/032/642/original/adafruit_products_schem.png?1464034817")!, symbol: "doc"),
            ComponentResource(title: "MAX98357A datasheet", url: URL(string: "https://cdn-shop.adafruit.com/product-files/3006/MAX98357A-MAX98357B.pdf")!, symbol: "doc"),
        ])

    static let speaker = PartModel(
        id: "speaker", name: "Speaker",
        summary: "Assumed passive speaker · check its rating before connecting",
        pins: [
            PartPin(name: "+", detail: "Amplifier OUT+, not an ESP32 GPIO"),
            PartPin(name: "−", detail: "Amplifier OUT−, not ground"),
        ])

    static let daytonPC83 = PartModel(
        id: "speaker", name: "Dayton Audio PC83-8",
        summary: "Full-range speaker · 8 Ω",
        pins: speaker.pins,
        resources: [
            ComponentResource(title: "Product specifications", url: URL(string: "https://www.parts-express.com/Dayton-Audio-PC83-8-3-Full-Range-Poly-Cone-Driver-295-150")!),
        ],
        speakerImpedanceOhms: 8)

    static func volumeButton(up: Bool, nuphy: Bool = false) -> PartModel {
        PartModel(id: up ? "volume-up" : "volume-down",
                  name: up ? "Volume up" : "Volume down",
                  summary: nuphy ? "NuPhy mechanical switch · exact variant unspecified" : "Momentary switch",
                  pins: [
                    PartPin(name: "1", detail: "GPIO input"),
                    PartPin(name: "2", detail: "Other switch contact; hookup inferred from input mode"),
                  ],
                  modelName: nuphy ? "NuPhy switch" : nil,
                  resources: nuphy ? [
                    ComponentResource(title: "NuPhy switches", url: URL(string: "https://nuphy.com/collections/switches")!),
                  ] : [])
    }
}

// MARK: - Detection result

struct WireEnd: Hashable, Sendable {
    let boardPin: String   // Source pin label, e.g. "D1", "5V", "OUT+"
    let gpio: Int?
    /// Nil means the microcontroller; otherwise an external part's ID.
    var partID: String? = nil
}

/// One expected wire from a source board or part to a part pin.
struct PartConnection: Hashable, Sendable, Identifiable {
    enum Origin: Hashable, Sendable {
        /// Read from the code at file:line (relative to the project).
        case code(file: String, line: Int, expression: String)
        /// Not in the code; the conventional hookup.
        case assumed(String)
    }
    var id: String { partPin }
    let partPin: String
    let end: WireEnd
    let origin: Origin

    var isAssumed: Bool { if case .assumed = origin { true } else { false } }
}

struct DetectedPart: Hashable, Sendable, Identifiable {
    var id: String { part.id }
    let part: PartModel
    /// True when the code names the part (comment, identifier or lib_deps);
    /// false when it was inferred from an I²S output alone.
    let namedInCode: Bool
    let connections: [PartConnection]
    /// Problems worth checking first when audio doesn't work.
    let issues: [String]
}

// MARK: - Scanner

/// Finds external parts and their expected wiring in a PlatformIO project by
/// reading the source. Deliberately small: it resolves pin constants
/// (`#define`, `const`/`constexpr`/`static const` integers, `GPIO_NUM_n`,
/// `Dn`/`An` aliases) and recognises the common I²S output setups:
///
/// - ESP32-audioI2S / ESP8266Audio: `x.setPinout(BCLK, LRC, DOUT)`
/// - Arduino-ESP32 3.x `I2SClass`: `i2s.setPins(BCLK, WS, DOUT, ...)`
/// - ESP-IDF legacy `i2s_pin_config_t` (`.bck_io_num`, `.ws_io_num`,
///   `.data_out_num`) and IDF 5 std mode (`.bclk`, `.ws`, `.dout`)
/// - Volume buttons configured with `pinMode` and used with `digitalRead`.
///
/// Anything computed at runtime or hidden behind macro arithmetic is out of
/// scope (see PRD non-goals); such pins are reported as unresolved.
enum PeripheralScanner {
    static func scan(projectAt root: URL, board: BoardModel) -> [DetectedPart] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let files = sourceFiles(in: root)
        var symbols: [String: String] = [:]
        var texts: [(path: String, raw: String, code: String)] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = stripComments(raw)
            let rel = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
            texts.append((rel, raw, code))
            collectSymbols(code, into: &symbols)
        }
        let ini = (try? String(contentsOf: root.appendingPathComponent("platformio.ini"), encoding: .utf8)) ?? ""
        let named = (texts.map(\.raw) + [ini]).contains { $0.range(of: "MAX98357", options: .caseInsensitive) != nil }
        let identityText = (texts.map(\.raw) + [hardwareNotes(projectAt: root)]).joined(separator: "\n")
        let dayton = identityText.range(of: #"\bPC83-8\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let nuphy = identityText.range(of: #"\bNuPhy\b"#, options: [.regularExpression, .caseInsensitive]) != nil

        var parts: [DetectedPart] = []
        if let i2s = findI2SOutput(texts, symbols: symbols) {
            parts.append(makeMAX98357A(i2s: i2s, texts: texts, symbols: symbols, board: board, named: named))
            parts.append(DetectedPart(part: dayton ? .daytonPC83 : .speaker, namedInCode: false, connections: [
                PartConnection(partPin: "+", end: WireEnd(boardPin: "OUT+", gpio: nil, partID: PartModel.max98357a.id),
                               origin: .assumed("Not detectable in code. Connect a suitable passive speaker to the amplifier outputs.")),
                PartConnection(partPin: "−", end: WireEnd(boardPin: "OUT−", gpio: nil, partID: PartModel.max98357a.id),
                               origin: .assumed("Not ground. Never connect either speaker output to GND or an ESP32 GPIO.")),
            ], issues: []))
        }
        parts += findVolumeButtons(texts, symbols: symbols, board: board, nuphy: nuphy)
        return parts.map { part in
            var issues = part.issues
            for connection in part.connections {
                guard let gpio = connection.end.gpio else { continue }
                for other in parts where other.id != part.id {
                    if other.connections.contains(where: { $0.end.gpio == gpio }) {
                        issues.append("GPIO\(gpio) is also used by \(other.part.name).")
                    }
                }
            }
            return DetectedPart(part: part.part, namedInCode: part.namedInCode,
                                connections: part.connections, issues: Array(Set(issues)).sorted())
        }
    }

    static func hardwareNotes(projectAt root: URL) -> String {
        ["README.md", "WIRING.md", "brief-radio.md"].compactMap {
            try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private static func findVolumeButtons(_ texts: [(path: String, raw: String, code: String)],
                                          symbols: [String: String], board: BoardModel, nuphy: Bool) -> [DetectedPart] {
        let pinMode = try! NSRegularExpression(
            pattern: #"\bpinMode\s*\(\s*([A-Za-z_]\w*)\s*,\s*(INPUT(?:_PULLUP|_PULLDOWN)?)\s*\)"#)
        var result: [DetectedPart] = []
        for text in texts {
            let ns = text.code as NSString
            for match in pinMode.matches(in: text.code, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                let upper = name.uppercased()
                guard upper.contains("VOL"), upper.contains("UP") || upper.contains("DOWN") else { continue }
                let readPattern = #"\bdigitalRead\s*\(\s*\#(name)\s*\)"#
                guard texts.contains(where: { $0.code.range(of: readPattern, options: .regularExpression) != nil }) else { continue }
                let part = PartModel.volumeButton(up: !upper.contains("DOWN"), nuphy: nuphy)
                guard !result.contains(where: { $0.id == part.id }) else { continue }
                let mode = ns.substring(with: match.range(at: 2))
                let sourceLine = line(of: match.range(at: 1).location, in: ns)
                var connections: [PartConnection] = []
                var issues: [String] = []
                switch resolve(name, symbols: symbols, board: board) {
                case .gpio(let gpio):
                    if let pin = board.pins.first(where: { $0.gpio == gpio }) {
                        let definition = location(ofSymbol: name, in: texts)
                        connections.append(PartConnection(
                            partPin: "1", end: WireEnd(boardPin: pin.label, gpio: gpio),
                            origin: .code(file: definition?.file ?? text.path, line: definition?.line ?? sourceLine,
                                          expression: "\(name) = \(symbols[name] ?? name)")))
                        if let note = pin.note { issues.append(note) }
                    } else {
                        issues.append("\(part.name) uses GPIO\(gpio), which isn't on the \(board.name) header (\(text.path):\(sourceLine)).")
                    }
                case .unresolved(let expression):
                    issues.append("Couldn't work out \(part.name)'s pin: “\(expression)” (\(text.path):\(sourceLine)).")
                }
                if mode != "INPUT" {
                    let rail = mode == "INPUT_PULLUP" ? "GND" : "3V3"
                    connections.append(PartConnection(
                        partPin: "2", end: WireEnd(boardPin: rail, gpio: nil),
                        origin: .assumed("\(mode) at \(text.path):\(sourceLine). Conventional switch hookup to \(rail); physical wiring isn't detectable in code.")))
                } else {
                    issues.append("INPUT at \(text.path):\(sourceLine) needs an external pull resistor. The other switch contact can't be inferred.")
                }
                result.append(DetectedPart(part: part, namedInCode: true, connections: connections, issues: issues))
            }
        }
        return result
    }

    // MARK: Files

    private static let sourceExtensions: Set<String> = ["c", "cc", "cpp", "h", "hpp", "ino"]

    private static func sourceFiles(in root: URL) -> [URL] {
        var result: [URL] = []
        for dir in ["src", "include", "lib"] {
            let base = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                // ESPDock's own library mentions Serial only; skip it.
                if url.path.contains("/lib/ESPDock/") { continue }
                if sourceExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Removes // and /* */ comments but keeps newlines, so line numbers hold.
    static func stripComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        var inLine = false, inBlock = false, inString = false
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i) < s.endIndex ? s[s.index(after: i)] : "\0"
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inBlock {
                if c == "*" && next == "/" { inBlock = false; i = s.index(after: i) }
                else if c == "\n" { out.append(c) }
            } else if inString {
                out.append(c)
                if c == "\\" && next != "\0" { out.append(next); i = s.index(after: i) }
                else if c == "\"" { inString = false }
            } else if c == "/" && next == "/" {
                inLine = true; i = s.index(after: i)
            } else if c == "/" && next == "*" {
                inBlock = true; i = s.index(after: i)
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    // MARK: Symbols

    private static let defineRE = try! NSRegularExpression(
        pattern: #"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)[ \t]+([^\n]+?)[ \t]*$"#, options: [.anchorsMatchLines])
    /// A whole integer constant declaration up to `;`; the declarators are
    /// split afterwards, so `constexpr int kBclk = 7, kWs = 8;` yields both.
    private static let constRE = try! NSRegularExpression(
        pattern: #"\b(?:static\s+)?(?:const|constexpr)\s+(?:static\s+)?(?:unsigned\s+)?(?:int|int8_t|uint8_t|int16_t|uint16_t|int32_t|uint32_t|gpio_num_t|byte|auto|long|short|pin_size_t)\s+([^;{}()]+=[^;{}]+);"#)

    private static func collectSymbols(_ code: String, into symbols: inout [String: String]) {
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in defineRE.matches(in: code, range: full) {
            symbols[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
        }
        for m in constRE.matches(in: code, range: full) {
            for declarator in ns.substring(with: m.range(at: 1)).split(separator: ",") {
                let parts = declarator.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                guard name.wholeMatch(of: #/[A-Za-z_]\w*/#) != nil else { continue }
                symbols[name] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// A pin expression resolved to a GPIO number, or why it couldn't be.
    enum Resolved: Equatable { case gpio(Int), unresolved(String) }

    static func resolve(_ expression: String, symbols: [String: String], board: BoardModel, depth: Int = 0) -> Resolved {
        var e = expression.trimmingCharacters(in: .whitespaces)
        // Peel casts and parentheses: (gpio_num_t)5, static_cast<int>(D1), (D1)
        if let r = e.range(of: #"^\((?:gpio_num_t|int|uint8_t|int8_t)\)\s*"#, options: .regularExpression) { e.removeSubrange(r) }
        if let r = e.range(of: #"^static_cast<\w+>\((.*)\)$"#, options: .regularExpression), r == e.startIndex..<e.endIndex {
            e = String(e.dropFirst(e.firstIndex(of: "(")!.utf16Offset(in: e) + 1).dropLast())
        }
        while e.hasPrefix("(") && e.hasSuffix(")") { e = String(e.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        e = e.replacingOccurrences(of: #"[uUlL]+$"#, with: "", options: .regularExpression)

        if let n = Int(e) { return .gpio(n) }
        if e.hasPrefix("GPIO_NUM_"), let n = Int(e.dropFirst(9)) { return .gpio(n) }
        // Arduino aliases: D3 / A3 are the board's silkscreen pins.
        if let m = e.wholeMatch(of: #/([DA])(\d+)/#), let pin = board.pins.first(where: { $0.label == "D\(m.2)" }),
           let gpio = pin.gpio { return .gpio(gpio) }
        if depth < 6, let value = symbols[e] {
            return resolve(value, symbols: symbols, board: board, depth: depth + 1)
        }
        return .unresolved(e)
    }

    // MARK: I²S output

    struct I2SOutput {
        struct Arg { let expression: String; let file: String; let line: Int }
        var bclk: Arg, ws: Arg, dout: Arg
    }

    private static let setPinoutRE = try! NSRegularExpression(
        pattern: #"\.\s*set[Pp]inout\s*\(\s*([^,()]+(?:\([^()]*\))?)\s*,\s*([^,()]+(?:\([^()]*\))?)\s*,\s*([^,()]+(?:\([^()]*\))?)"#)
    private static let setPinsRE = try! NSRegularExpression(
        pattern: #"\b(\w*[iI]2[sS]\w*)\s*\.\s*setPins\s*\(\s*([^,()]+(?:\([^()]*\))?)\s*,\s*([^,()]+(?:\([^()]*\))?)\s*,\s*([^,()]+(?:\([^()]*\))?)"#)

    private static func findI2SOutput(_ texts: [(path: String, raw: String, code: String)],
                                      symbols: [String: String]) -> I2SOutput? {
        for t in texts {
            let ns = t.code as NSString
            let full = NSRange(location: 0, length: ns.length)
            func arg(_ m: NSTextCheckingResult, _ i: Int) -> I2SOutput.Arg {
                I2SOutput.Arg(expression: ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces),
                              file: t.path, line: line(of: m.range(at: i).location, in: ns))
            }
            if let m = setPinoutRE.firstMatch(in: t.code, range: full) {
                return I2SOutput(bclk: arg(m, 1), ws: arg(m, 2), dout: arg(m, 3))
            }
            if let m = setPinsRE.firstMatch(in: t.code, range: full) {
                return I2SOutput(bclk: arg(m, 2), ws: arg(m, 3), dout: arg(m, 4))
            }
            // ESP-IDF designated initializers (legacy and IDF 5 std mode).
            let fields: [(bclk: String, ws: String, dout: String)] = [
                ("bck_io_num", "ws_io_num", "data_out_num"), ("bclk", "ws", "dout"),
            ]
            for f in fields {
                if let b = field(f.bclk, in: t.code), let w = field(f.ws, in: t.code), let d = field(f.dout, in: t.code) {
                    let mk = { (x: (String, Int)) in I2SOutput.Arg(expression: x.0, file: t.path, line: x.1) }
                    return I2SOutput(bclk: mk(b), ws: mk(w), dout: mk(d))
                }
            }
        }
        return nil
    }

    /// `.name = expr` inside a designated initializer: (expr, line).
    private static func field(_ name: String, in code: String) -> (String, Int)? {
        let re = try! NSRegularExpression(pattern: #"\.\s*\#(name)\s*=\s*([^,}\n]+)"#)
        let ns = code as NSString
        guard let m = re.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                line(of: m.range(at: 1).location, in: ns))
    }

    private static func line(of location: Int, in ns: NSString) -> Int {
        ns.substring(to: location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: MAX98357A

    private static func makeMAX98357A(i2s: I2SOutput, texts: [(path: String, raw: String, code: String)],
                                      symbols: [String: String], board: BoardModel, named: Bool) -> DetectedPart {
        var connections: [PartConnection] = []
        var issues: [String] = []
        var used: [Int: String] = [:]   // gpio → part pin, to catch double use

        func connect(_ partPin: String, _ arg: I2SOutput.Arg) {
            switch resolve(arg.expression, symbols: symbols, board: board) {
            case .gpio(let gpio):
                if let other = used[gpio] {
                    issues.append("\(partPin) and \(other) both use GPIO\(gpio).")
                }
                used[gpio] = partPin
                guard let pin = board.pins.first(where: { $0.gpio == gpio }) else {
                    // Name the onboard part if that GPIO is one (e.g. the LED),
                    // which usually explains the mistake.
                    let onboard = board.features.first { $0.detail.contains("GPIO\(gpio) ") || $0.detail.hasPrefix("GPIO\(gpio)") }
                    let what = onboard.map { " (it's the \($0.name))" } ?? ""
                    issues.append("\(partPin) is on GPIO\(gpio)\(what), which isn't on the \(board.name) header (\(arg.file):\(arg.line)).")
                    return
                }
                if let note = pin.note { issues.append("\(partPin) on \(pin.label): \(note)") }
                // Point at the constant's definition when there is one: that's
                // the line to edit when the wiring and the code disagree.
                var origin = PartConnection.Origin.code(file: arg.file, line: arg.line, expression: arg.expression)
                if let value = symbols[arg.expression], let def = location(ofSymbol: arg.expression, in: texts) {
                    origin = .code(file: def.file, line: def.line, expression: "\(arg.expression) = \(value)")
                }
                connections.append(PartConnection(
                    partPin: partPin, end: WireEnd(boardPin: pin.label, gpio: gpio), origin: origin))
            case .unresolved(let what):
                issues.append("Couldn't work out which pin \(partPin) uses: “\(what)” (\(arg.file):\(arg.line)).")
            }
        }
        connect("BCLK", i2s.bclk)
        connect("LRC", i2s.ws)
        connect("DIN", i2s.dout)

        // Optional control pins, recognised by constant names. Names must say
        // "amp"/"MAX"/"shutdown"/"gain" so an SD-card pin isn't mistaken for
        // the amp's SD (shutdown) pin.
        for (name, value) in symbols.sorted(by: { $0.key < $1.key }) {
            let upper = name.uppercased()
            let partPin: String
            if upper.contains("GAIN") { partPin = "GAIN" }
            else if upper.contains("SHUTDOWN") || upper.contains("SD_MODE")
                        || ((upper.contains("AMP") || upper.contains("MAX")) && (upper.contains("SD") || upper.contains("EN"))) {
                partPin = "SD"
            } else { continue }
            guard !connections.contains(where: { $0.partPin == partPin }),
                  let loc = location(ofSymbol: name, in: texts) else { continue }
            connect(partPin, I2SOutput.Arg(expression: value, file: loc.file, line: loc.line))
        }

        // Power isn't in code: the conventional hookup.
        let fiveV = board.pins.first { $0.label == "5V" }
        connections.append(PartConnection(partPin: "Vin", end: WireEnd(boardPin: fiveV?.label ?? "3V3", gpio: nil),
                                          origin: .assumed("Not in code. 5 V gives the most volume; 3V3 also works, quieter.")))
        connections.append(PartConnection(partPin: "GND", end: WireEnd(boardPin: "GND", gpio: nil),
                                          origin: .assumed("Not in code. Always needed: shared ground.")))

        // A signal pin the sketch also drives as plain GPIO is a likely bug.
        for c in connections {
            guard let gpio = c.end.gpio else { continue }
            for t in texts {
                for (n, lineText) in t.code.components(separatedBy: "\n").enumerated()
                where lineText.contains("pinMode") || lineText.contains("digitalWrite") {
                    guard let arg = lineText.firstMatch(of: #/(?:pinMode|digitalWrite)\s*\(\s*([^,]+),/#)?.1 else { continue }
                    if case .gpio(gpio) = resolve(String(arg), symbols: symbols, board: board), c.partPin != "SD", c.partPin != "GAIN" {
                        issues.append("GPIO\(gpio) is \(c.partPin) for the amp but also used with \(lineText.contains("pinMode") ? "pinMode" : "digitalWrite") at \(t.path):\(n + 1).")
                    }
                }
            }
        }

        let order = PartModel.max98357a.pins.map(\.name)
        return DetectedPart(part: .max98357a, namedInCode: named,
                            connections: connections.sorted { order.firstIndex(of: $0.partPin)! < order.firstIndex(of: $1.partPin)! },
                            issues: issues)
    }

    private static func location(ofSymbol name: String, in texts: [(path: String, raw: String, code: String)]) -> (file: String, line: Int)? {
        for t in texts {
            for (n, l) in t.code.components(separatedBy: "\n").enumerated()
            where l.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
                && (l.contains("define") || l.contains("const")) {
                return (t.path, n + 1)
            }
        }
        return nil
    }
}
