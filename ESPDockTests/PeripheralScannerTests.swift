import XCTest
import SwiftUI
@testable import ESPDock

final class PeripheralScannerTests: XCTestCase {
    private func scan(_ code: String, notes: [String: String] = [:]) throws -> [DetectedPart] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Couldn't remove fixture: \(error)") }
        }
        try code.write(to: root.appendingPathComponent("src/main.cpp"), atomically: true, encoding: .utf8)
        for (file, text) in notes {
            try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return PeripheralScanner.scan(projectAt: root, board: BoardCatalog.xiaoESP32S3)
    }

    // Pin definitions and API calls used by berndpl/ESP-Radio.
    private let radio = """
    // XIAO ESP32-S3 + MAX98357A
    #define I2S_LRC_PIN 1
    #define I2S_DOUT_PIN 2
    #define I2S_BCLK_PIN 3
    #define BTN_VOL_UP_PIN 5
    #define BTN_VOL_DOWN_PIN 6
    void setup() {
        pinMode(BTN_VOL_UP_PIN, INPUT_PULLUP);
        pinMode(BTN_VOL_DOWN_PIN, INPUT_PULLUP);
        audio.setPinout(I2S_BCLK_PIN, I2S_LRC_PIN, I2S_DOUT_PIN);
    }
    void loop() {
        digitalRead(BTN_VOL_UP_PIN);
        digitalRead(BTN_VOL_DOWN_PIN);
    }
    """

    func testRadioHasAmplifierSpeakerAndBothButtons() throws {
        let parts = try scan(radio)
        XCTAssertEqual(parts.map(\.id), ["max98357a", "speaker", "volume-up", "volume-down"])
        let amp = try XCTUnwrap(parts.first)
        XCTAssertEqual(amp.connections.first(where: { $0.partPin == "BCLK" })?.end.boardPin, "D2")
        XCTAssertEqual(amp.connections.first(where: { $0.partPin == "LRC" })?.end.boardPin, "D0")
        XCTAssertEqual(amp.connections.first(where: { $0.partPin == "DIN" })?.end.boardPin, "D1")
        for (id, pin, line) in [("volume-up", "D4", 5), ("volume-down", "D5", 6)] {
            let button = try XCTUnwrap(parts.first(where: { $0.id == id }))
            let signal = try XCTUnwrap(button.connections.first(where: { $0.partPin == "1" }))
            XCTAssertEqual(signal.end.boardPin, pin)
            guard case .code(let file, let actualLine, _) = signal.origin else {
                return XCTFail("Button signal must have a source location")
            }
            XCTAssertEqual(file, "src/main.cpp")
            XCTAssertEqual(actualLine, line)
            let ground = try XCTUnwrap(button.connections.first(where: { $0.partPin == "2" }))
            XCTAssertEqual(ground.end.boardPin, "GND")
            XCTAssertTrue(ground.isAssumed)
        }
    }

    func testSpeakerIsAssumedAndConnectedOnlyToAmplifier() throws {
        let parts = try scan(radio)
        let speaker = try XCTUnwrap(parts.first(where: { $0.id == "speaker" }))
        XCTAssertFalse(speaker.namedInCode)
        XCTAssertEqual(speaker.connections.map(\.end.boardPin), ["OUT+", "OUT−"])
        XCTAssertTrue(speaker.connections.allSatisfy {
            $0.isAssumed && $0.end.partID == "max98357a" && $0.end.gpio == nil
        })
        XCTAssertFalse(speaker.part.summary.contains("8"))
    }

    func testButtonsWorkWithoutAmplifierAndPullDownUses3V3() throws {
        let parts = try scan("""
        constexpr int VOL_UP = D4;
        pinMode(VOL_UP, INPUT_PULLDOWN);
        digitalRead(VOL_UP);
        """)
        XCTAssertEqual(parts.map(\.id), ["volume-up"])
        XCTAssertEqual(parts.first?.connections.map(\.end.boardPin), ["D4", "3V3"])
    }

    func testPlainInputDoesNotInventGroundConnection() throws {
        let button = try XCTUnwrap(scan("""
        #define BTN_VOL_DOWN 6
        pinMode(BTN_VOL_DOWN, INPUT);
        digitalRead(BTN_VOL_DOWN);
        """).first)
        XCTAssertEqual(button.connections.count, 1)
        XCTAssertTrue(button.issues.contains(where: { $0.contains("external pull resistor") }))
    }

    func testUnresolvedAndOffHeaderButtonPinsAreReported() throws {
        for expression in ["GPIO_NUM_21", "choosePin()"] {
            let button = try XCTUnwrap(scan("""
            #define VOL_UP_PIN \(expression)
            pinMode(VOL_UP_PIN, INPUT_PULLUP);
            digitalRead(VOL_UP_PIN);
            """).first)
            XCTAssertFalse(button.connections.contains(where: { $0.partPin == "1" }))
            XCTAssertFalse(button.issues.isEmpty)
        }
    }

    func testSharedAmplifierAndButtonGPIOIsReportedOnBothParts() throws {
        let parts = try scan(radio.replacingOccurrences(of: "BTN_VOL_UP_PIN 5", with: "BTN_VOL_UP_PIN 2"))
        for id in ["max98357a", "volume-up"] {
            let part = try XCTUnwrap(parts.first(where: { $0.id == id }))
            XCTAssertTrue(part.issues.contains(where: { $0.contains("GPIO2 is also used") }))
        }
    }

    func testCommentsAndUnusedOrUnrelatedInputsDoNotCreateParts() throws {
        XCTAssertTrue(try scan("""
        // audio.setPinout(3, 1, 2);
        #define VOL_UP_PIN 5
        // pinMode(VOL_UP_PIN, INPUT_PULLUP);
        digitalRead(VOL_UP_PIN);
        #define VOL_DOWN_PIN 6
        pinMode(VOL_DOWN_PIN, INPUT_PULLUP);
        #define BOOT_BUTTON 0
        pinMode(BOOT_BUTTON, INPUT_PULLUP);
        digitalRead(BOOT_BUTTON);
        """).isEmpty)
    }

    func testRepeatedSetupDoesNotDuplicateButtons() throws {
        let parts = try scan(radio + "\npinMode(BTN_VOL_UP_PIN, INPUT_PULLUP);")
        XCTAssertEqual(parts.filter { $0.id == "volume-up" }.count, 1)
    }

    func testProjectNotesIdentifySpeakerAndSwitchesWithoutChangingWiring() throws {
        for file in ["README.md", "WIRING.md", "brief-radio.md"] {
            let generic = try scan(radio)
            let identified = try scan(radio, notes: [file: "Dayton Audio PC83-8 (8 ohm)\n2x NuPhy mechanical switches"])
            XCTAssertEqual(identified.map(\.connections), generic.map(\.connections))
            let speaker = try XCTUnwrap(identified.first(where: { $0.id == "speaker" }))
            XCTAssertEqual(speaker.part.name, "Dayton Audio PC83-8")
            XCTAssertEqual(speaker.part.summary, "Full-range speaker · 8 Ω")
            XCTAssertFalse(speaker.part.resources.isEmpty)
            for id in ["volume-up", "volume-down"] {
                let button = try XCTUnwrap(identified.first(where: { $0.id == id }))
                XCTAssertEqual(button.part.modelName, "NuPhy switch")
                XCTAssertTrue(button.part.summary.contains("unspecified"))
                XCTAssertEqual(button.part.resources.first?.url.host, "nuphy.com")
            }
        }
    }

    func testHardwareNamesAloneDoNotInventWiringOrLeakBetweenProjects() throws {
        XCTAssertTrue(try scan("", notes: ["WIRING.md": "PC83-8 and NuPhy"]).isEmpty)
        let generic = try scan(radio)
        XCTAssertEqual(generic.first(where: { $0.id == "speaker" })?.part.name, "Speaker")
        XCTAssertNil(generic.first(where: { $0.id == "volume-up" })?.part.modelName)
        XCTAssertTrue(try scan(radio, notes: ["WIRING.md": "PC83-80"]).contains(where: { $0.part.name == "Speaker" }))
    }

    func testSpeakerIdentityCanComeFromSourceComment() throws {
        let parts = try scan("// Dayton Audio PC83-8\n" + radio)
        XCTAssertEqual(parts.first(where: { $0.id == "speaker" })?.part.name, "Dayton Audio PC83-8")
    }

    func testAmplifierHasGuideReferenceSchematicAndDatasheet() throws {
        let amp = try XCTUnwrap(scan(radio).first(where: { $0.id == "max98357a" }))
        XCTAssertEqual(amp.part.resources.map(\.title), [
            "Adafruit guide", "Reference breakout schematic", "MAX98357A datasheet",
        ])
        XCTAssertTrue(amp.part.resources.allSatisfy { $0.url.scheme == "https" })
    }

    private let displayHardware = """
    {
      "schemaVersion": 1,
      "board": "seeed_xiao_esp32s3",
      "components": [
        {
          "id": "epaper-driver", "name": "ePaper Driver Board", "kind": "carrier",
          "summary": "Socketed carrier; charging state unavailable.",
          "pins": [{"name": "RST", "detail": "Reset"}, {"name": "FPC", "detail": "Panel connector"}],
          "connections": [{"pin": "RST", "sourcePin": "D0", "note": "V2 schematic; not a continuity measurement."}]
        },
        {
          "id": "epaper-panel", "name": "2.13-inch ePaper", "kind": "display",
          "summary": "122 x 250; SSD1680",
          "pins": [{"name": "FPC", "detail": "24-pin flex cable"}],
          "connections": [{"pin": "FPC", "sourcePart": "epaper-driver", "sourcePin": "FPC", "note": "Fitted ribbon."}]
        },
        {
          "id": "sense-camera", "name": "Sense camera", "kind": "camera",
          "summary": "Attached but not initialized; sensor variant unknown.",
          "pins": [{"name": "B2B", "detail": "Sense expansion connector"}],
          "connections": [{"pin": "B2B", "sourcePin": "B2B", "note": "Board-to-board connector, not a header GPIO."}]
        },
        {
          "id": "battery", "name": "Battery", "kind": "battery",
          "summary": "Connected; capacity and charge level unknown.",
          "pins": [{"name": "+", "detail": "Positive"}, {"name": "-", "detail": "Negative"}],
          "connections": []
        }
      ]
    }
    """

    func testHardwareManifestLoadsAttachedPartsWithoutInventingFirmwareUse() throws {
        let parts = try scan("", notes: ["hardware.json": displayHardware])
        XCTAssertEqual(parts.map(\.id), ["epaper-driver", "epaper-panel", "sense-camera", "battery"])
        let reset = try XCTUnwrap(parts.first?.connections.first)
        XCTAssertEqual(reset.end.boardPin, "D0")
        XCTAssertEqual(reset.end.gpio, 1)
        XCTAssertFalse(reset.isAssumed)
        let panel = try XCTUnwrap(parts.first(where: { $0.id == "epaper-panel" }))
        XCTAssertEqual(panel.connections.first?.end.partID, "epaper-driver")
        let camera = try XCTUnwrap(parts.first(where: { $0.id == "sense-camera" }))
        XCTAssertEqual(camera.connections.first?.end.boardPin, "B2B")
        XCTAssertNil(camera.connections.first?.end.gpio)
        XCTAssertTrue(camera.part.summary.contains("not initialized"))
        XCTAssertTrue(try XCTUnwrap(parts.last).part.summary.contains("unknown"))
    }

    func testHardwareManifestIsAuthoritativeAndDoesNotLeakBetweenProjects() throws {
        let parts = try scan(radio, notes: ["hardware.json": displayHardware])
        XCTAssertEqual(parts.map(\.id), ["epaper-driver", "epaper-panel", "sense-camera", "battery"])
        XCTAssertEqual(try scan(radio).count, 4)
        XCTAssertTrue(try scan("").isEmpty)
    }

    func testInvalidHardwareManifestShowsAnErrorInsteadOfFallingBackToRadio() throws {
        let invalid = [
            "{",
            displayHardware.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"),
            displayHardware.replacingOccurrences(of: "seeed_xiao_esp32s3", with: "another_board"),
            displayHardware.replacingOccurrences(of: "\"sourcePin\": \"D0\"", with: "\"sourcePin\": \"D99\""),
            displayHardware.replacingOccurrences(of: "\"sourcePart\": \"epaper-driver\"", with: "\"sourcePart\": \"missing\""),
            displayHardware.replacingOccurrences(of: "\"id\": \"battery\"", with: "\"id\": \"sense-camera\""),
        ]
        for json in invalid {
            let parts = try scan(radio, notes: ["hardware.json": json])
            XCTAssertEqual(parts.map(\.id), ["hardware-manifest-error"])
            XCTAssertFalse(try XCTUnwrap(parts.first).issues.isEmpty)
        }
    }

    func testHardwareFileChangesInvalidateTheWiringScanInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Couldn't remove fixture: \(error)") }
        }
        let file = root.appendingPathComponent("hardware.json")
        try displayHardware.write(to: file, atomically: true, encoding: .utf8)
        let before = PeripheralScanner.hardwareNotes(projectAt: root)
        XCTAssertTrue(before.contains("Sense camera"))
        try displayHardware.replacingOccurrences(of: "Sense camera", with: "Different camera")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(PeripheralScanner.hardwareNotes(projectAt: root), before)
        XCTAssertEqual(PeripheralScanner.scan(projectAt: root, board: BoardCatalog.xiaoESP32S3)
            .first(where: { $0.id == "sense-camera" })?.part.name, "Different camera")
    }

    func testIllustrationStyleCycleAndTransparentSchematicPalette() {
        XCTAssertEqual(BoardStyle.realistic.toggled, .blueprint)
        XCTAssertEqual(BoardStyle.blueprint.toggled, .schematic)
        XCTAssertEqual(BoardStyle.schematic.toggled, .realistic)
        XCTAssertEqual(Set(BoardStyle.allCases), [.realistic, .blueprint, .schematic])
        XCTAssertEqual(BoardStyle.schematic.paper, .clear)
        XCTAssertEqual(BoardStyle.schematic.ink, .blue)
        XCTAssertEqual(BoardStyle.blueprint.paper, Blueprint.paper)
        XCTAssertEqual(BoardStyle.blueprint.ink, Blueprint.ink)
    }

    @MainActor
    func testDocumentedHardwareHasVisibleBodiesAndEveryConnectionAnchorInAllStyles() throws {
        let parts = try scan("", notes: ["hardware.json": displayHardware])
        XCTAssertEqual(parts.count, 4)
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for style in BoardStyle.allCases {
            UserDefaults.standard.setVolatileDomain(
                arguments.merging(["boardStyle": style.rawValue]) { _, new in new },
                forName: UserDefaults.argumentDomain)
            let frames = WiringFrames()
            let view = PinoutView(model: BoardCatalog.xiaoESP32S3, parts: parts)
                .frame(width: 456)
                .environment(\.boardStyle, style)
                .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear { frames.rects = anchors.mapValues { proxy[$0] } }
                    }
                }
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000),
                                                      size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            for part in parts {
                XCTAssertNotNil(frames.rects["part:\(part.id):body"])
                for pin in part.part.pins {
                    XCTAssertNotNil(frames.rects["part:\(part.id):\(pin.name)"])
                }
                for connection in part.connections {
                    let source = connection.end.partID.map { "part:\($0)" } ?? "board"
                    XCTAssertNotNil(frames.rects["\(source):\(connection.end.boardPin)"])
                }
            }
        }
    }

    @MainActor
    func testAmplifierHeaderMatchesPhysicalTopEdgeOrientation() throws {
        let amp = try XCTUnwrap(scan(radio).first)
        for style in BoardStyle.allCases {
            let frames = WiringFrames()
            let view = PartBoardView(detected: amp, pitch: 28)
                .environment(\.boardStyle, style)
                .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear { frames.rects = anchors.mapValues { proxy[$0] } }
                    }
                }
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000),
                                                      size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            var previousX = -CGFloat.infinity
            for name in ["Vin", "GND", "SD", "GAIN", "DIN", "BCLK", "LRC"] {
                let pad = try XCTUnwrap(frames.rects["part:max98357a:\(name)"])
                XCTAssertGreaterThan(pad.midX, previousX, "\(name) is mirrored in \(style)")
                previousX = pad.midX
            }
        }
    }

    @MainActor
    func testWireHoverTemporarilyOverridesPinnedSelection() {
        var highlight = WireHighlight()
        highlight.toggle("max98357a:BCLK")
        XCTAssertEqual(highlight.activeID, "max98357a:BCLK")
        highlight.hoveredID = "speaker:+"
        XCTAssertEqual(highlight.activeID, "speaker:+")
        XCTAssertEqual(highlight.selectedID, "max98357a:BCLK")
        highlight.hoveredID = nil
        XCTAssertEqual(highlight.activeID, "max98357a:BCLK")
        highlight.toggle("volume-up:1")
        XCTAssertEqual(highlight.selectedID, "volume-up:1")
        highlight.toggle("volume-up:1")
        XCTAssertNil(highlight.activeID)
    }

    @MainActor
    func testWireHitTestingChoosesNearestTraceAndIgnoresEmptySpace() throws {
        let connection = try XCTUnwrap(scan(radio).first?.connections.first)
        let first = WiresOverlay.Route(id: "first", connection: connection, label: "First",
                                      start: .zero, bends: [CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 100)],
                                      end: CGPoint(x: 100, y: 100))
        let second = WiresOverlay.Route(id: "second", connection: connection, label: "Second",
                                       start: CGPoint(x: 6, y: 0), bends: [CGPoint(x: 16, y: 0), CGPoint(x: 16, y: 100)],
                                       end: CGPoint(x: 106, y: 100))
        let routes = [first, second]
        XCTAssertEqual(WiresOverlay.closestRoute(to: CGPoint(x: 15, y: 40), in: routes)?.id, "second")
        XCTAssertEqual(WiresOverlay.closestRoute(to: CGPoint(x: 10, y: 33), in: routes)?.id, "first")
        XCTAssertEqual(WiresOverlay.closestRoute(to: .zero, in: routes)?.id, "first")
        XCTAssertNil(WiresOverlay.closestRoute(to: CGPoint(x: 50, y: 50), in: routes))
    }

    @MainActor
    func testRenderedWiresCanBeClickedAndToggledIndividually() throws {
        let parts = try scan(radio)
        let frames = WiringFrames()
        let model = BoardCatalog.xiaoESP32S3
        let view = PinoutView(model: model, parts: parts)
            .frame(width: 456)
            .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                WiresOverlay(parts: parts, anchors: anchors, model: model,
                             highlight: Binding(get: { frames.highlight }, set: { frames.highlight = $0 }))
            }
            .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.onAppear { frames.rects = anchors.mapValues { proxy[$0] } }
                }
            }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000),
                                                  size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        for id in ["max98357a:BCLK", "speaker:+", "volume-down:1"] {
            let pad = try XCTUnwrap(frames.rects["part:\(id)"])
            let point = host.convert(CGPoint(x: pad.midX, y: host.isFlipped ? pad.midY : host.bounds.height - pad.midY), to: nil)
            func click() throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil,
                                                               eventNumber: 0, clickCount: 1, pressure: 0))
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            try click()
            XCTAssertEqual(frames.highlight.selectedID, id, "active: \(NSApp.isActive), key window: \(window.isKeyWindow)")
            try click()
            XCTAssertNil(frames.highlight.selectedID)
        }
    }

    @MainActor
    func testSchematicScrollViewUsesAvailableHeight() throws {
        let view = SchematicCard(model: BoardCatalog.xiaoESP32S3, parts: try scan(radio))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 480, height: 320),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(findScrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        let initialHeight = scroll.contentView.bounds.height
        XCTAssertGreaterThan(document.bounds.height, initialHeight)
        window.setContentSize(NSSize(width: 480, height: 520))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(scroll.contentView.bounds.height - initialHeight, 200, accuracy: 2)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
    }

    @MainActor
    func testComponentsAreVerticallyStackedInRenderedDiagram() throws {
        let parts = try scan(radio)
        let frames = WiringFrames()
        let view = PinoutView(model: BoardCatalog.xiaoESP32S3, parts: parts)
            .frame(width: 456)
            .overlayPreferenceValue(WireAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frames.rects = anchors.mapValues { proxy[$0] } }
                }
            }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000),
                                                  size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var previous = try XCTUnwrap(frames.rects["board:body"])
        for part in parts {
            let rect = try XCTUnwrap(frames.rects["part:\(part.id):body"])
            XCTAssertGreaterThan(rect.minY, previous.maxY, "\(part.part.name) must have its own row below the previous component")
            previous = rect
        }
    }
}

@MainActor
private final class WiringFrames {
    var rects: [String: CGRect] = [:]
    var highlight = WireHighlight()
}
