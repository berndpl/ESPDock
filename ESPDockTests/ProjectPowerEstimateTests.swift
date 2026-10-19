import XCTest
@testable import ESPDock

final class ProjectPowerEstimateTests: XCTestCase {
    private let model = BoardCatalog.xiaoESP32S3

    private func radio(speaker: PartModel = .daytonPC83, supply: String = "5V",
                       returnPin: String = "OUT−") -> [DetectedPart] {
        [
            DetectedPart(part: .max98357a, namedInCode: true, connections: [
                PartConnection(partPin: "Vin", end: WireEnd(boardPin: supply, gpio: nil),
                               origin: .assumed("Check power wiring.")),
                PartConnection(partPin: "GND", end: WireEnd(boardPin: "GND", gpio: nil),
                               origin: .assumed("Shared ground.")),
            ], issues: []),
            DetectedPart(part: speaker, namedInCode: false, connections: [
                PartConnection(partPin: "+", end: WireEnd(boardPin: "OUT+", gpio: nil, partID: "max98357a"),
                               origin: .assumed("Speaker output.")),
                PartConnection(partPin: "−", end: WireEnd(boardPin: returnPin, gpio: nil, partID: "max98357a"),
                               origin: .assumed("Speaker return.")),
            ], issues: []),
        ]
    }

    func testRadioIncludesAmplifierLossesButDoesNotCountSpeakerTwice() throws {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        XCTAssertTrue(estimate.issues.isEmpty)
        XCTAssertTrue(estimate.usesAssumedWiring)
        XCTAssertEqual(estimate.speakerOhms, 8)
        XCTAssertEqual(try XCTUnwrap(estimate.speakerOutputWatts), 1.8, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.loads.first { $0.id == "max98357a" }?.watts), 2.26675, accuracy: 0.00001)
        XCTAssertEqual(estimate.loads.first { $0.id == "speaker" }?.watts, 0)
        XCTAssertEqual(try XCTUnwrap(estimate.totalWatts), 4.76675, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.totalAmps), 0.95335, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.minimumSupplyAmps), 1.1916875, accuracy: 0.00001)
        XCTAssertEqual(estimate.suggestedSupplyAmps, 2)
    }

    func testFourOhmSpeakerNeedsMoreInputPowerThanEightOhmSpeaker() throws {
        let eight = ProjectPowerEstimate(model: model, parts: radio())
        let four = ProjectPowerEstimate(model: model, parts: radio(), speakerOhms: 4)
        XCTAssertEqual(try XCTUnwrap(four.speakerOutputWatts), 3.2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(four.totalWatts), 6.51675, accuracy: 0.00001)
        XCTAssertGreaterThan(try XCTUnwrap(four.totalAmps), try XCTUnwrap(eight.totalAmps))
        XCTAssertEqual(four.suggestedSupplyAmps, 2)
    }

    func testUnknownSpeakerDoesNotSilentlyAssumeAnImpedance() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio(speaker: .speaker))
        XCTAssertNil(estimate.speakerOhms)
        XCTAssertNil(estimate.totalWatts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertFalse(estimate.issues.isEmpty)
        XCTAssertEqual(estimate.knownWatts, 2.5, accuracy: 0.00001)
    }

    func testExplicitSpeakerSelectionCompletesAGenericSpeakerEstimate() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio(speaker: .speaker), speakerOhms: 8)
        XCTAssertTrue(estimate.issues.isEmpty)
        XCTAssertNotNil(estimate.totalWatts)
        XCTAssertEqual(estimate.suggestedSupplyAmps, 2)
    }

    func testUnknownAndInvalidSpeakerLoadsDoNotProduceRecommendations() {
        for ohms in [0, -4, 2, 16] {
            let estimate = ProjectPowerEstimate(model: model, parts: radio(), speakerOhms: ohms)
            XCTAssertNil(estimate.totalWatts)
            XCTAssertNil(estimate.speakerOutputWatts)
            XCTAssertNil(estimate.suggestedSupplyAmps)
            XCTAssertFalse(estimate.issues.isEmpty)
        }
    }

    func testOtherAmplifierSupplyRailsAreNotTreatedAsFiveVolts() {
        for supply in ["3V3", "BAT", "unknown"] {
            let estimate = ProjectPowerEstimate(model: model, parts: radio(supply: supply))
            XCTAssertNil(estimate.totalWatts)
            XCTAssertNil(estimate.suggestedSupplyAmps)
            XCTAssertNil(estimate.speakerOutputWatts)
            XCTAssertFalse(estimate.issues.isEmpty)
        }
    }

    func testMissingAmplifierGroundBlocksTheWholeProjectRecommendation() {
        var parts = radio()
        let amp = parts[0]
        parts[0] = DetectedPart(part: amp.part, namedInCode: amp.namedInCode,
                                connections: amp.connections.filter { $0.partPin != "GND" }, issues: [])
        let estimate = ProjectPowerEstimate(model: model, parts: parts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertFalse(estimate.issues.isEmpty)
    }

    func testSpeakerOnGroundIsNotAcceptedAsAnAmplifierLoad() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio(returnPin: "GND"))
        XCTAssertNil(estimate.totalWatts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertFalse(estimate.issues.isEmpty)
    }

    func testBoardOnlyBudgetAndPassiveSwitches() {
        let boardOnly = ProjectPowerEstimate(model: model, parts: [])
        let switches = [true, false].map {
            DetectedPart(part: .volumeButton(up: $0), namedInCode: true, connections: [], issues: [])
        }
        let withSwitches = ProjectPowerEstimate(model: model, parts: switches)
        XCTAssertEqual(boardOnly.totalWatts, 2.5)
        XCTAssertEqual(boardOnly.totalAmps, 0.5)
        XCTAssertEqual(boardOnly.suggestedSupplyAmps, 1)
        XCTAssertEqual(withSwitches.totalWatts, boardOnly.totalWatts)
    }

    func testUnmodeledComponentKeepsTheEstimateExplicitlyIncomplete() {
        let unknown = DetectedPart(part: PartModel(id: "display", name: "Display", summary: "", pins: []),
                                   namedInCode: true, connections: [], issues: [])
        let estimate = ProjectPowerEstimate(model: model, parts: radio() + [unknown])
        XCTAssertNil(estimate.totalWatts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertNil(estimate.loads.first { $0.id == "display" }?.watts)
        XCTAssertTrue(estimate.issues.contains { $0.contains("Display") })
    }

    func testUnknownBoardDoesNotBorrowTheXiaoPowerAllowance() {
        let unknown = BoardModel(id: "other-board", name: "Other board", chip: model.chip,
                                 sizeMM: model.sizeMM, platformIOBoard: "other", pins: model.pins,
                                 features: model.features, referenceURL: model.referenceURL,
                                 schematicURL: model.schematicURL)
        let estimate = ProjectPowerEstimate(model: unknown, parts: radio())
        XCTAssertNil(estimate.totalWatts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertFalse(estimate.issues.isEmpty)
    }

    func testSourcesDistinguishInsufficientLoadFromInsufficientHeadroom() throws {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        let basicUSB = PowerSourceComparison(estimate: estimate, capacityAmps: 0.5)
        let oneAmp = PowerSourceComparison(estimate: estimate, capacityAmps: 1)
        let port = PowerSourceComparison(estimate: estimate, capacityAmps: 1.5)
        let brick = PowerSourceComparison(estimate: estimate, capacityAmps: 2)
        XCTAssertEqual(basicUSB.status, .belowLoad)
        XCTAssertEqual(oneAmp.status, .belowMargin)
        XCTAssertEqual(port.status, .meetsBudget)
        XCTAssertEqual(brick.status, .meetsBudget)
        XCTAssertEqual(brick.capacityWatts, 10)
        XCTAssertEqual(try XCTUnwrap(basicUSB.marginAmps), -0.6916875, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(port.marginAmps), 0.3083125, accuracy: 0.00001)
    }

    func testUSBAllocationAndPortCapacityAreComparedSeparately() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        let connection = USBConnection(speed: .full, hubs: ["USB hub"],
                                       allocatedMilliamps: 500, portLimitMilliamps: 1500)
        let allocation = PowerSourceComparison(estimate: estimate,
            capacityAmps: connection.allocatedMilliamps.map { Double($0) / 1_000 })
        let port = PowerSourceComparison(estimate: estimate,
            capacityAmps: connection.portLimitMilliamps.map { Double($0) / 1_000 })
        XCTAssertEqual(allocation.status, .belowLoad)
        XCTAssertEqual(port.status, .meetsBudget)
        XCTAssertEqual(allocation.capacityAmps, 0.5)
        XCTAssertEqual(port.capacityAmps, 1.5)
    }

    func testExactlyMeetingTheSizingTargetHasZeroSpareCapacity() throws {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        let comparison = PowerSourceComparison(estimate: estimate, capacityAmps: estimate.minimumSupplyAmps)
        XCTAssertEqual(comparison.status, .meetsBudget)
        XCTAssertEqual(try XCTUnwrap(comparison.marginAmps), 0, accuracy: 0.00001)
    }

    func testUnknownOrInvalidSourceCapacityNeverClaimsSufficientPower() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        for amps: Double? in [nil, 0, -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let comparison = PowerSourceComparison(estimate: estimate, capacityAmps: amps)
            XCTAssertEqual(comparison.status, .unknown)
            XCTAssertNil(comparison.capacityAmps)
            XCTAssertNil(comparison.capacityWatts)
            XCTAssertNil(comparison.marginAmps)
        }
    }

    func testIncompleteProjectCannotBeApprovedByALargeSupply() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio(speaker: .speaker))
        let comparison = PowerSourceComparison(estimate: estimate, capacityAmps: 5)
        XCTAssertEqual(comparison.status, .unknown)
        XCTAssertEqual(comparison.capacityWatts, 25)
        XCTAssertNil(comparison.marginAmps)
    }

    func testSourceHeadroomUpdatesWithSpeakerLoad() {
        let eight = ProjectPowerEstimate(model: model, parts: radio())
        let four = ProjectPowerEstimate(model: model, parts: radio(), speakerOhms: 4)
        XCTAssertEqual(PowerSourceComparison(estimate: eight, capacityAmps: 1.5).status, .meetsBudget)
        XCTAssertEqual(PowerSourceComparison(estimate: four, capacityAmps: 1.5).status, .belowMargin)
    }

    func testManualRatingsAcceptDecimalSeparatorsButNotInvalidOrNonFiniteValues() {
        XCTAssertEqual(PowerSourceComparison.parseRating(" 2.5 "), 2.5)
        XCTAssertEqual(PowerSourceComparison.parseRating("2,5"), 2.5)
        XCTAssertEqual(PowerSourceComparison.parseRating("3"), 3)
        for text in ["", " ", "0", "-2", "nan", "inf", "1e999", "65 W", "3 A", "2.3.4"] {
            XCTAssertNil(PowerSourceComparison.parseRating(text), text)
        }
    }

    private func otherBoard(volts: Double, pin: String = "VIN") -> BoardModel {
        BoardModel(id: "other-board", name: "Other board", chip: "Other chip", sizeMM: "30 x 20 mm",
                   platformIOBoard: "other", pins: [
                    Pin(label: pin, side: .left, gpio: nil, functions: []),
                    Pin(label: "GND", side: .right, gpio: nil, functions: []),
                   ], features: [], referenceURL: model.referenceURL, schematicURL: model.schematicURL,
                   powerProfile: BoardPowerProfile(inputVolts: volts, inputPin: pin, groundPin: "GND",
                       boardAllowanceAmps: 0.2, assumption: "This board's documented sizing allowance."))
    }

    func testDifferentBoardUsesItsOwnProfileVoltageAndAllowance() throws {
        let estimate = ProjectPowerEstimate(model: otherBoard(volts: 9), parts: [])
        XCTAssertEqual(estimate.supplyVolts, 9)
        XCTAssertEqual(try XCTUnwrap(estimate.totalWatts), 1.8, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.totalAmps), 0.2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.minimumSupplyAmps), 0.25, accuracy: 0.00001)
        XCTAssertEqual(estimate.boardAssumption, "This board's documented sizing allowance.")
        XCTAssertTrue(estimate.sources.isEmpty)
        XCTAssertEqual(PowerSourceComparison(estimate: estimate, voltageVolts: 9, capacityAmps: 1).status, .meetsBudget)
        XCTAssertEqual(PowerSourceComparison(estimate: estimate, voltageVolts: 5, capacityAmps: 3).status, .differentVoltage)
    }

    func testAmplifierSupportsAnotherBoardWithDifferentInputPinLabels() throws {
        let estimate = ProjectPowerEstimate(model: otherBoard(volts: 5, pin: "VBUS"),
                                            parts: radio(supply: "VBUS"))
        XCTAssertTrue(estimate.issues.isEmpty)
        XCTAssertEqual(try XCTUnwrap(estimate.totalWatts), 3.26675, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(estimate.totalAmps), 0.65335, accuracy: 0.00001)
    }

    func testAmplifierOnAnotherVoltageIsNotSilentlyConvertedOrIncluded() {
        let estimate = ProjectPowerEstimate(model: otherBoard(volts: 9), parts: radio(supply: "VIN"))
        XCTAssertNil(estimate.totalWatts)
        XCTAssertNil(estimate.suggestedSupplyAmps)
        XCTAssertFalse(estimate.issues.isEmpty)
    }

    func testInvalidBoardProfileDoesNotProduceAnEstimate() {
        for volts in [0, -5, Double.nan, .infinity] {
            let estimate = ProjectPowerEstimate(model: otherBoard(volts: volts), parts: [])
            XCTAssertNil(estimate.totalWatts)
            XCTAssertNil(estimate.supplyVolts)
            XCTAssertNil(estimate.suggestedSupplyAmps)
        }
    }

    func testHigherVoltageHeadlinePowerDoesNotMakeASupplyCompatible() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        let supply = PowerSourceComparison(estimate: estimate, voltageVolts: 20, capacityAmps: 3.25)
        XCTAssertEqual(supply.capacityWatts, 65)
        XCTAssertEqual(supply.status, .differentVoltage)
        XCTAssertNil(supply.marginAmps)
    }

    func testInvalidSourceVoltageNeverClaimsSufficientPower() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        for volts: Double? in [nil, 0, -5, .nan, .infinity] {
            let supply = PowerSourceComparison(estimate: estimate, voltageVolts: volts, capacityAmps: 3)
            XCTAssertEqual(supply.status, .unknown)
            XCTAssertNil(supply.marginAmps)
            XCTAssertNil(supply.capacityWatts)
        }
    }

    func testNamedSupplyProfilesRoundTripWithoutProjectSpecificFields() throws {
        let profiles = [
            PowerSourceProfile(name: "USB-C charger", volts: 5, amps: 3),
            PowerSourceProfile(name: "Bench supply", volts: 9, amps: 1.25),
        ]
        let restored = try PowerSourceProfile.decode(PowerSourceProfile.encode(profiles))
        XCTAssertEqual(restored, profiles)
        XCTAssertEqual(restored.map(\.id), profiles.map(\.id))
        let project = ProjectPowerEstimate(model: otherBoard(volts: 9), parts: [])
        XCTAssertEqual(PowerSourceComparison(estimate: project,
            voltageVolts: restored[1].volts, capacityAmps: restored[1].amps).status, .meetsBudget)
    }

    func testCorruptOrInvalidProfilesFailExplicitlyRatherThanBecomingEmpty() throws {
        XCTAssertThrowsError(try PowerSourceProfile.decode(Data("not JSON".utf8)))
        XCTAssertThrowsError(try PowerSourceProfile.decode(Data(#"[{"name":"Missing ratings"}]"#.utf8)))
        for profile in [
            PowerSourceProfile(name: " ", volts: 5, amps: 2),
            PowerSourceProfile(name: "Invalid", volts: 0, amps: 2),
            PowerSourceProfile(name: "Invalid", volts: 5, amps: -.infinity),
            PowerSourceProfile(name: "Invalid", volts: 5, amps: .greatestFiniteMagnitude),
        ] {
            XCTAssertThrowsError(try PowerSourceProfile.encode([profile]))
        }
        let profile = PowerSourceProfile(name: "Supply", volts: 5, amps: 2)
        XCTAssertThrowsError(try PowerSourceProfile.encode([profile, profile]))
        XCTAssertEqual(try PowerSourceProfile.decode(Data("[]".utf8)), [])
    }

    func testUnknownSupplyRatingsStayUnknownAfterSaving() throws {
        let profile = PowerSourceProfile(name: "Unverified USB port", volts: 5, amps: nil,
            notes: "Connect to read the actual USB allocation.",
            referenceURL: URL(string: "https://support.apple.com/"))
        let restored = try PowerSourceProfile.decode(PowerSourceProfile.encode([profile]))
        XCTAssertEqual(restored, [profile])
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        let comparison = PowerSourceComparison(estimate: estimate,
            voltageVolts: restored[0].volts, capacityAmps: restored[0].amps)
        XCTAssertEqual(comparison.status, .unknown)
        XCTAssertNil(comparison.marginAmps)
    }

    func testExistingProfilesWithoutNewOptionalMetadataStillDecode() throws {
        let data = Data(#"[{"id":"368B9233-3C8A-4D6E-84F5-F568089F111A","name":"Existing supply","volts":5,"amps":2}]"#.utf8)
        let profiles = try PowerSourceProfile.decode(data)
        XCTAssertEqual(profiles.first?.amps, 2)
        XCTAssertNil(profiles.first?.notes)
        XCTAssertNil(profiles.first?.referenceURL)
    }

    func testUnsafeReferenceURLsAreRejectedWithoutLosingProfiles() {
        for url in ["http://example.com/", "javascript:alert(1)", "file:///tmp/spec.pdf", "https:missing-host"] {
            let profile = PowerSourceProfile(name: "Supply", volts: 5, amps: 2,
                                            referenceURL: URL(string: url))
            XCTAssertThrowsError(try PowerSourceProfile.encode([profile]), url)
        }
    }

    func testCurrentSourceWarningOnlyAppearsForKnownShortfalls() {
        let estimate = ProjectPowerEstimate(model: model, parts: radio())
        XCTAssertTrue(PowerSourceComparison(estimate: estimate, capacityAmps: 0.5).hasShortfall)
        XCTAssertTrue(PowerSourceComparison(estimate: estimate, capacityAmps: 1).hasShortfall)
        XCTAssertTrue(PowerSourceComparison(estimate: estimate, voltageVolts: 9, capacityAmps: 3).hasShortfall)
        XCTAssertFalse(PowerSourceComparison(estimate: estimate, capacityAmps: nil).hasShortfall)
        XCTAssertFalse(PowerSourceComparison(estimate: estimate, capacityAmps: 3).hasShortfall)
        let unknown = ProjectPowerEstimate(model: model, parts: radio(speaker: .speaker))
        XCTAssertFalse(PowerSourceComparison(estimate: unknown, capacityAmps: 0.5).hasShortfall)
    }
}
