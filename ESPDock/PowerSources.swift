import Foundation

struct PowerSourceComparison {
    enum Status: Equatable {
        case unknown, differentVoltage, belowLoad, belowMargin, meetsBudget
    }

    let voltageVolts: Double?
    let targetVolts: Double?
    let capacityAmps: Double?
    let loadAmps: Double?
    let targetAmps: Double?

    var capacityWatts: Double? {
        guard let voltageVolts, let capacityAmps else { return nil }
        return voltageVolts * capacityAmps
    }

    var marginAmps: Double? {
        guard let capacityAmps, let targetAmps, voltageVolts == targetVolts else { return nil }
        return capacityAmps - targetAmps
    }

    var status: Status {
        guard let capacityAmps, let voltageVolts, let targetVolts else { return .unknown }
        if voltageVolts != targetVolts { return .differentVoltage }
        guard let loadAmps, let targetAmps else { return .unknown }
        if capacityAmps < loadAmps { return .belowLoad }
        if capacityAmps < targetAmps { return .belowMargin }
        return .meetsBudget
    }

    var hasShortfall: Bool {
        switch status {
        case .differentVoltage, .belowLoad, .belowMargin: true
        case .unknown, .meetsBudget: false
        }
    }

    init(estimate: ProjectPowerEstimate, voltageVolts: Double? = 5, capacityAmps: Double?) {
        self.voltageVolts = Self.validNumber(voltageVolts)
        targetVolts = estimate.supplyVolts
        if let volts = Self.validNumber(voltageVolts), let amps = Self.validNumber(capacityAmps),
           (volts * amps).isFinite {
            self.capacityAmps = amps
        } else {
            self.capacityAmps = nil
        }
        loadAmps = estimate.totalAmps
        targetAmps = estimate.minimumSupplyAmps
    }

    static func parseRating(_ text: String) -> Double? {
        validNumber(Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")))
    }

    private static func validNumber(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }
}

struct PowerSourceProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var volts: Double?
    var amps: Double?
    var notes: String? = nil
    var referenceURL: URL? = nil

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let volts, !(volts > 0 && volts.isFinite) { return false }
        if let amps, !(amps > 0 && amps.isFinite) { return false }
        if let volts, let amps, !(volts * amps).isFinite { return false }
        if let referenceURL, referenceURL.scheme?.lowercased() != "https" || referenceURL.host?.isEmpty != false {
            return false
        }
        return true
    }

    static func decode(_ data: Data) throws -> [Self] {
        let profiles = try JSONDecoder().decode([Self].self, from: data)
        try validate(profiles)
        return profiles
    }

    static func encode(_ profiles: [Self]) throws -> Data {
        try validate(profiles)
        return try JSONEncoder().encode(profiles)
    }

    private static func validate(_ profiles: [Self]) throws {
        guard profiles.allSatisfy(\.isValid), Set(profiles.map(\.id)).count == profiles.count else {
            throw ValidationError.invalidProfiles
        }
    }

    private enum ValidationError: LocalizedError {
        case invalidProfiles
        var errorDescription: String? {
            "Supply profiles need unique IDs, a name, positive finite ratings when specified and an HTTPS reference URL."
        }
    }
}
