import SwiftUI

struct PowerSourcesView: View {
    let estimate: ProjectPowerEstimate
    let usbConnection: USBConnection?
    @AppStorage("powerSources.profiles") private var savedSources = Data("[]".utf8)
    @State private var editedSource: PowerSourceProfile?
    @State private var storageError: String?
    @State private var selectedSourceID: UUID?

    private var profiles: Result<[PowerSourceProfile], Error> {
        Result { try PowerSourceProfile.decode(savedSources) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch profiles {
            case .success(let profiles):
                let selected = profiles.first { $0.id == selectedSourceID }
                let comparison = PowerSourceComparison(estimate: estimate,
                    voltageVolts: selected?.volts ?? (selectedSourceID == nil ? 5 : nil),
                    capacityAmps: selectedSourceID == nil ? usbConnection?.allocatedAmps : selected?.amps)
                HStack(spacing: 8) {
                    Text("Supply")
                    Picker("Compare supply", selection: $selectedSourceID) {
                        Text("Current USB").tag(UUID?.none)
                        ForEach(profiles) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("power-source-picker")
                    Menu {
                        Button {
                            editedSource = PowerSourceProfile(name: "", volts: estimate.supplyVolts, amps: nil)
                        } label: {
                            Label("Add supply", systemImage: "plus")
                        }
                        .accessibilityIdentifier("power-source-add")
                        if let selected {
                            Divider()
                            Button("Edit") { editedSource = selected }
                            Button("Remove", role: .destructive) {
                                do {
                                    try remove(selected)
                                    selectedSourceID = nil
                                } catch { storageError = error.localizedDescription }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add or manage power supplies")
                    .accessibilityLabel("Power supply options")
                    .accessibilityIdentifier("power-source-options")
                }
                HStack(alignment: .top) {
                    ratingLabel(comparison, isUSB: selectedSourceID == nil)
                    Spacer()
                    PowerSourceStatusView(comparison: comparison, showsMargin: false)
                }
                .font(.caption)
                .help(selected?.notes ?? usbConnection?.powerDescription ?? "No USB allocation is known.")
            case .failure(let error):
                Label("Cannot load saved supplies: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .sheet(item: $editedSource) { source in
            PowerSourceEditor(source: source, save: save)
        }
        .alert("Could not update power sources", isPresented: Binding(
            get: { storageError != nil },
            set: { if !$0 { storageError = nil } })) {
                Button("OK") { storageError = nil }
        } message: {
            Text(storageError ?? "")
        }
        .onChange(of: savedSources) {
            if case .success(let profiles) = profiles,
               let selectedSourceID, !profiles.contains(where: { $0.id == selectedSourceID }) {
                self.selectedSourceID = nil
            }
        }
    }

    private func ratingLabel(_ comparison: PowerSourceComparison, isUSB: Bool) -> some View {
        Group {
            if let volts = comparison.voltageVolts, let amps = comparison.capacityAmps {
                Text("\(number(volts)) V / \(number(amps)) A\(isUSB ? " allocated" : "")")
            } else {
                Text("Capacity unknown")
            }
        }
        .monospacedDigit().foregroundStyle(.secondary)
    }

    private func save(_ source: PowerSourceProfile) throws {
        var profiles = try PowerSourceProfile.decode(savedSources)
        if let index = profiles.firstIndex(where: { $0.id == source.id }) {
            profiles[index] = source
        } else {
            profiles.append(source)
        }
        savedSources = try PowerSourceProfile.encode(profiles)
    }

    private func remove(_ source: PowerSourceProfile) throws {
        let profiles = try PowerSourceProfile.decode(savedSources).filter { $0.id != source.id }
        savedSources = try PowerSourceProfile.encode(profiles)
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct PowerSourceReferencesView: View {
    @AppStorage("powerSources.profiles") private var savedSources = Data("[]".utf8)

    var body: some View {
        switch Result(catching: { try PowerSourceProfile.decode(savedSources) }) {
        case .success(let profiles):
            ForEach(profiles) { source in
                VStack(alignment: .leading, spacing: 3) {
                    if let referenceURL = source.referenceURL {
                        Link(destination: referenceURL) {
                            Label(source.name, systemImage: "arrow.up.right.square")
                        }
                    } else {
                        Text(source.name).fontWeight(.medium)
                    }
                    if let notes = source.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .failure(let error):
            Label("Supply references unavailable: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

struct PowerSourceStatusView: View {
    let comparison: PowerSourceComparison
    var showsMargin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).foregroundStyle(color)
            if showsMargin, let margin = comparison.marginAmps {
                Text(margin >= 0
                     ? "\(number(margin)) A above sizing target"
                     : "\(number(-margin)) A short of sizing target")
                    .foregroundStyle(.secondary)
            }
            if showsMargin, comparison.status == .differentVoltage, let target = comparison.targetVolts {
                Text("Requires nominal \(number(target)) V. Do not connect a higher-voltage output; conversion is not modeled.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch comparison.status {
        case .unknown:
            comparison.capacityAmps == nil ? "Capacity not specified" : "Project estimate incomplete"
        case .differentVoltage: "Different voltage; not comparable"
        case .belowLoad: "Below estimated load"
        case .belowMargin: "Load fits; below 25% headroom"
        case .meetsBudget: "Meets sizing target"
        }
    }

    private var icon: String {
        switch comparison.status {
        case .unknown: "questionmark.circle"
        case .differentVoltage, .belowLoad, .belowMargin: "exclamationmark.triangle"
        case .meetsBudget: "checkmark.circle"
        }
    }

    private var color: Color {
        switch comparison.status {
        case .unknown: .secondary
        case .differentVoltage, .belowLoad, .belowMargin: .orange
        case .meetsBudget: .green
        }
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct PowerSourceEditor: View {
    let source: PowerSourceProfile
    let save: (PowerSourceProfile) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var volts: String
    @State private var amps: String
    @State private var notes: String
    @State private var reference: String
    @State private var saveError: String?

    init(source: PowerSourceProfile, save: @escaping (PowerSourceProfile) throws -> Void) {
        self.source = source
        self.save = save
        _name = State(initialValue: source.name)
        _volts = State(initialValue: source.volts.map { String($0) } ?? "")
        _amps = State(initialValue: source.amps.map { String($0) } ?? "")
        _notes = State(initialValue: source.notes ?? "")
        _reference = State(initialValue: source.referenceURL?.absoluteString ?? "")
    }

    private var validProfile: PowerSourceProfile? {
        let voltageText = volts.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = amps.trimmingCharacters(in: .whitespacesAndNewlines)
        let voltage = PowerSourceComparison.parseRating(voltageText)
        let current = PowerSourceComparison.parseRating(currentText)
        if !voltageText.isEmpty && voltage == nil || !currentText.isEmpty && current == nil { return nil }
        let referenceText = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = referenceText.isEmpty ? nil : URL(string: referenceText)
        if !referenceText.isEmpty && url == nil { return nil }
        var profile = source
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.volts = voltage
        profile.amps = current
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        profile.referenceURL = url
        return profile.isValid ? profile : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Power source").font(.headline)
            TextField("Name", text: $name).accessibilityIdentifier("power-source-name")
            HStack {
                TextField("Output voltage", text: $volts).accessibilityIdentifier("power-source-volts")
                Text("V")
                TextField("Output current", text: $amps).accessibilityIdentifier("power-source-amps")
                Text("A")
            }
            Text("Use the label's output rating at the required voltage, not headline PD wattage. Leave a rating blank when unknown; it will not be treated as sufficient.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("power-source-notes")
            TextField("HTTPS specification URL (optional)", text: $reference)
                .accessibilityIdentifier("power-source-reference")
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let validProfile else {
                        saveError = "Enter a name, positive finite ratings or blanks, and a valid HTTPS reference."
                        return
                    }
                    do {
                        try save(validProfile)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled(validProfile == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 380)
    }
}
