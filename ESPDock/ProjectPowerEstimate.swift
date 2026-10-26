import Foundation

/// Supply-sizing allowances for the components in the schematic, not telemetry
/// or an average-consumption/battery-runtime prediction.
struct ProjectPowerEstimate {
    struct Load: Identifiable {
        let id: String
        let name: String
        let watts: Double?
        let detail: String
    }

    private static let amplifierSupplyVolts = 5.0
    static let amplifierEfficiency = 0.8
    static let amplifierIdleAmps = 0.00335
    static let headroom = 0.25

    private static let amplifierSources = [
        ComponentResource(title: "MAX98357A output ratings",
                          url: URL(string: "https://learn.adafruit.com/adafruit-max98357-i2s-class-d-mono-amp/overview")!),
        ComponentResource(title: "MAX98357A electrical specifications",
                          url: URL(string: "https://cdn-shop.adafruit.com/product-files/3006/MAX98357A-MAX98357B.pdf")!),
    ]

    let loads: [Load]
    let issues: [String]
    let speakerOhms: Int?
    let speakerOutputWatts: Double?
    let usesAssumedWiring: Bool
    let supplyVolts: Double?
    let boardAssumption: String?
    let sources: [ComponentResource]

    var knownWatts: Double { loads.compactMap(\.watts).reduce(0, +) }
    var totalWatts: Double? { issues.isEmpty ? knownWatts : nil }
    var totalAmps: Double? {
        guard let totalWatts, let supplyVolts else { return nil }
        return totalWatts / supplyVolts
    }
    var minimumSupplyAmps: Double? { totalAmps.map { $0 * (1 + Self.headroom) } }
    var suggestedSupplyAmps: Double? { minimumSupplyAmps.map { ceil($0) } }

    init(model: BoardModel, parts: [DetectedPart], speakerOhms override: Int? = nil) {
        var loads: [Load] = []
        var issues: [String] = []
        let profile = model.powerProfile.flatMap { $0.isValid ? $0 : nil }
        supplyVolts = profile?.inputVolts
        boardAssumption = profile?.assumption
        sources = (profile?.resources ?? [])
            + (parts.contains { $0.id == PartModel.max98357a.id } ? Self.amplifierSources : [])
        loads.append(Load(id: "board:\(model.id)", name: model.name,
                          watts: profile.map { $0.inputVolts * $0.boardAllowanceAmps },
                          detail: profile.map { "\($0.boardAllowanceAmps) A allowance at the \($0.inputVolts) V input. Not typical or measured draw." }
                            ?? "No valid power profile is available for this board."))
        if profile == nil { issues.append("No valid board power profile; a whole-project supply cannot be recommended.") }

        let amp = parts.first { $0.id == PartModel.max98357a.id }
        let speaker = parts.first { $0.id == PartModel.speaker.id }
        let impedance = override ?? speaker?.part.speakerImpedanceOhms
        speakerOhms = impedance
        // Typical output at 5 V, 1 kHz and 10% THD+N. Include conversion loss
        // and idle draw rather than treating speaker watts as supply watts.
        let output: Double?
        switch impedance {
        case 4: output = 3.2
        case 8: output = 1.8
        default: output = nil
        }
        let speakerConnected = amp != nil && speaker.map { speaker in
            [("+", "OUT+"), ("−", "OUT−")].allSatisfy { pin, output in
                speaker.connections.contains {
                    $0.partPin == pin && $0.end.partID == amp?.id && $0.end.boardPin == output
                }
            }
        } == true
        let ampOnFiveV = amp.map { amp in
            profile?.inputVolts == Self.amplifierSupplyVolts
                && amp.connections.contains { $0.partPin == "Vin" && $0.end.partID == nil && $0.end.boardPin == profile?.inputPin }
                && amp.connections.contains { $0.partPin == "GND" && $0.end.partID == nil && $0.end.boardPin == profile?.groundPin }
        } == true
        speakerOutputWatts = ampOnFiveV && speakerConnected ? output : nil
        usesAssumedWiring = parts.flatMap(\.connections).contains(where: \.isAssumed)

        for part in parts {
            switch part.id {
            case PartModel.max98357a.id:
                let watts: Double?
                let detail: String
                if !ampOnFiveV {
                    watts = nil
                    detail = "Requires a direct connection to the board profile's 5 V input and shared ground."
                    issues.append("Confirm amplifier Vin on the profiled 5 V input rail and shared ground. Other rails and converters need a separate calculation.")
                } else if !speakerConnected {
                    watts = nil
                    detail = "No recognized speaker across OUT+ and OUT−."
                    issues.append("Connect a speaker across the amplifier outputs in the schematic.")
                } else if let output, let impedance {
                    watts = output / Self.amplifierEfficiency + Self.amplifierSupplyVolts * Self.amplifierIdleAmps
                    detail = "\(output) W audio into \(impedance) ohms / 80% efficiency + 3.35 mA idle allowance."
                } else {
                    watts = nil
                    detail = "Speaker impedance is unknown or unsupported."
                    issues.append("Choose a 4 or 8 ohm speaker load to calculate amplifier input power.")
                }
                loads.append(Load(id: part.id, name: part.part.name, watts: watts, detail: detail))
            case PartModel.speaker.id:
                loads.append(Load(id: part.id, name: part.part.name, watts: speakerConnected ? 0 : nil,
                                  detail: speakerConnected
                                    ? "Included in amplifier input, not added twice. Speaker impedance is a nominal value."
                                    : "The speaker is not connected to a modeled amplifier."))
                if !speakerConnected { issues.append("Speaker wiring cannot be included in this estimate.") }
            case "volume-up", "volume-down":
                loads.append(Load(id: part.id, name: part.part.name, watts: 0,
                                  detail: "Passive switch; GPIO pull-resistor current is covered by the board allowance."))
            default:
                loads.append(Load(id: part.id, name: part.part.name, watts: nil,
                                  detail: "No power profile is available for this component."))
                issues.append("No power profile for \(part.part.name); the estimate is incomplete.")
            }
        }
        self.loads = loads
        self.issues = issues
    }
}
