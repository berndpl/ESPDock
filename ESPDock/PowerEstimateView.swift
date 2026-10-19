import SwiftUI

struct PowerEstimateView: View {
    let model: BoardModel
    let parts: [DetectedPart]
    let usbConnection: USBConnection?
    @State private var expanded = false
    @State private var showDetails = false
    @State private var speakerLoad: SpeakerLoad = .project

    init(model: BoardModel, parts: [DetectedPart], usbConnection: USBConnection? = nil,
         initiallyExpanded: Bool = false) {
        self.model = model
        self.parts = parts
        self.usbConnection = usbConnection
        _expanded = State(initialValue: initiallyExpanded)
    }

    private enum SpeakerLoad: Hashable {
        case project, fourOhms, eightOhms

        var override: Int? {
            switch self {
            case .project: nil
            case .fourOhms: 4
            case .eightOhms: 8
            }
        }
    }

    private var estimate: ProjectPowerEstimate {
        ProjectPowerEstimate(model: model, parts: parts, speakerOhms: speakerLoad.override)
    }

    var body: some View {
        let estimate = estimate
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label("Power", systemImage: "bolt").font(.callout.weight(.medium))
                    Spacer()
                    if let volts = estimate.supplyVolts, let amps = estimate.totalAmps {
                        Text("\(number(volts, digits: 1)) V / ~\(number(amps, digits: 2)) A")
                            .monospacedDigit()
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                    if let usbConnection {
                        let comparison = PowerSourceComparison(estimate: estimate,
                                                               capacityAmps: usbConnection.allocatedAmps)
                        if comparison.hasShortfall {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Current USB source is below the estimated requirement")
                                .help("The current USB allocation does not meet the modeled voltage or estimated load with 25% headroom.")
                        }
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project power estimate")
            .accessibilityValue(accessibilitySummary)
            .accessibilityIdentifier("power-budget-toggle")
            if expanded {
                HStack(alignment: .top) {
                    if let volts = estimate.supplyVolts, let supply = estimate.suggestedSupplyAmps,
                       let watts = estimate.totalWatts {
                        Text("~\(number(watts, digits: 1)) W estimated · suggested \(number(volts, digits: 1)) V / \(number(supply, digits: 0)) A supply")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Estimate incomplete").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        showDetails.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Calculation, assumptions and sources")
                    .accessibilityLabel("Power budget details and sources")
                    .accessibilityIdentifier("power-budget-details")
                    .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                        detailsPopover
                    }
                }
                if parts.contains(where: { $0.id == PartModel.max98357a.id }) {
                    Picker("Speaker load", selection: $speakerLoad) {
                        Text(projectLoadLabel).tag(SpeakerLoad.project)
                        Text("4 ohms (override)").tag(SpeakerLoad.fourOhms)
                        Text("8 ohms (override)").tag(SpeakerLoad.eightOhms)
                    }
                    .accessibilityIdentifier("power-speaker-load")
                }
                ForEach(estimate.loads.filter { $0.watts != 0 }) { load in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(load.name).fontWeight(.medium)
                            Spacer()
                            Text(load.watts.map { $0 == 0 ? "Included" : "~\(number($0, digits: 2)) W" } ?? "Unknown")
                                .monospacedDigit()
                        }
                    }
                    .help(load.detail)
                }
                let includedLoads = estimate.loads.filter { $0.watts == 0 }
                if !includedLoads.isEmpty {
                    Text("\(includedLoads.count) passive parts already included")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(includedLoads.map(\.name).joined(separator: "\n"))
                }
                ForEach(estimate.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Divider()
                PowerSourcesView(estimate: estimate, usbConnection: usbConnection)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: parts) { speakerLoad = .project }
        .onChange(of: model) { speakerLoad = .project }
    }

    private var detailsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Power budget details").font(.headline)
                Text("Sources").fontWeight(.medium)
                ForEach(estimate.sources) { source in
                    Link(destination: source.url) {
                        Label(source.title, systemImage: "arrow.up.right.square")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                PowerSourceReferencesView()
                Divider()
                if let watts = estimate.totalWatts, let amps = estimate.totalAmps,
                   let minimum = estimate.minimumSupplyAmps, let volts = estimate.supplyVolts {
                    Text("Calculation").fontWeight(.medium)
                    Text("\(number(watts, digits: 2)) W / \(number(volts, digits: 1)) V = \(number(amps, digits: 2)) A. With 25% headroom: \(number(minimum, digits: 2)) A; the recommended supply rounds this up to a whole amp.")
                } else {
                    Text("Known loads only: ~\(number(estimate.knownWatts, digits: 2)) W. Missing data prevents a whole-project recommendation.")
                }
                ForEach(estimate.loads) { load in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(load.name).fontWeight(.medium)
                        Text(load.detail).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Assumptions").fontWeight(.medium)
                if estimate.usesAssumedWiring {
                    Text("Check inferred power and speaker wiring against the physical connections.")
                }
                if let assumption = estimate.boardAssumption {
                    Text(assumption)
                }
                if parts.contains(where: { $0.id == PartModel.max98357a.id }) {
                    Text("Amplifier output ratings use loud 1 kHz audio at 10% distortion; 80% efficiency is an engineering allowance, not a guaranteed minimum.")
                }
                Text("Only shown components are included. Battery charging, other hardware and conversion losses are excluded. Actual program load, volume and Wi-Fi change draw. This is neither a guaranteed maximum nor a battery-runtime estimate.")
                Text("USB port capacity is not the device's allocation or measured draw. Hub figures describe that USB path, not the MacBook charger's wattage. USB comparisons assume nominal 5 V, not a negotiated PD voltage.")
                if let usbConnection {
                    Text("\(usbConnection.pathDescription). \(usbConnection.powerDescription ?? "USB power allocation unavailable.")")
                }
                Text("Saved supplies use manual label ratings, not detected capabilities. Shared ports, cables, board-rail limits and USB-C negotiation can reduce usable power. Compare the output rating at the required voltage, not headline PD wattage. The app does not negotiate power or change allocation.")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 360, height: 460)
        .textSelection(.enabled)
    }

    private var accessibilitySummary: String {
        var values = [expanded ? "Expanded" : "Collapsed"]
        if let volts = estimate.supplyVolts, let amps = estimate.totalAmps {
            values.append("Estimated \(number(volts, digits: 1)) volts, \(number(amps, digits: 2)) amps")
        } else {
            values.append("Estimate unknown")
        }
        if let usbConnection, PowerSourceComparison(estimate: estimate,
            capacityAmps: usbConnection.allocatedAmps).hasShortfall {
            values.append("Warning: current USB source does not meet the estimated requirement")
        }
        return values.joined(separator: ", ")
    }

    private var projectLoadLabel: String {
        if let ohms = parts.first(where: { $0.id == PartModel.speaker.id })?.part.speakerImpedanceOhms {
            return "Project speaker (\(ohms) ohms)"
        }
        return "Project speaker (impedance unknown)"
    }

    private func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}
