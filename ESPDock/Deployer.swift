import Foundation
import Observation

/// Runs `pio run -t upload` for a linked project and reports progress.
///
/// Uses PlatformIO Core installed by the VS Code extension
/// (~/.platformio/penv/bin/pio) so builds are identical to VS Code's.
@MainActor
@Observable
final class Deployer {
    enum Phase: Equatable {
        case idle
        case building
        case uploading(Double)          // 0…1
        case succeeded(Date)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var log: [String] = []
    /// MAC of the board this deploy targets (state is shown only for that board).
    private(set) var targetMAC: String?
    @ObservationIgnored private var process: Process?
    /// Hooks so the serial monitor can let go of the port for esptool and
    /// reattach after the board reboots.
    @ObservationIgnored var willUsePort: (() -> Void)?
    @ObservationIgnored var didReleasePort: ((String) -> Void)?
    @ObservationIgnored private var port: String?

    static let pioURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".platformio/penv/bin/pio")

    var isRunning: Bool {
        switch phase {
        case .building, .uploading: true
        default: false
        }
    }

    func deploy(_ link: ProjectLink, to board: Board, onSuccess: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        guard board.supportsUpload else {
            targetMAC = board.macAddress
            phase = .failed("Connect the board over USB to deploy. Wi-Fi monitoring is read-only.")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: Self.pioURL.path) else {
            phase = .failed("PlatformIO not found. Install the PlatformIO IDE extension in VS Code.")
            return
        }
        targetMAC = board.macAddress
        port = board.port
        willUsePort?()
        log = ["$ pio run -e \(link.environment) -t upload --upload-port \(board.port)"]
        phase = .building

        let p = Process()
        p.executableURL = Self.pioURL
        p.arguments = ["run", "-e", link.environment, "-t", "upload", "--upload-port", board.port]
        p.currentDirectoryURL = link.url
        var env = ProcessInfo.processInfo.environment
        env["PLATFORMIO_FORCE_ANSI"] = "false"   // plain text for the log view
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finish(status: status, reason: reason, onSuccess: onSuccess)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Couldn't start PlatformIO: \(error.localizedDescription)")
            didReleasePort?(board.port)
        }
    }

    func cancel() {
        process?.terminate()
    }

    func reset() {
        if !isRunning { phase = .idle; log = [] }
    }

    // MARK: Output parsing

    private var partialLine = ""

    private func ingest(_ text: String) {
        let combined = partialLine + text
        var lines = combined.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        partialLine = lines.removeLast()
        for line in lines where !line.isEmpty {
            log.append(line)
            update(from: line)
        }
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    /// esptool prints "Writing at 0x0003520e... (66 %)"; anything from
    /// "Uploading" on means the build part is done.
    private func update(from line: String) {
        if let open = line.range(of: "("), let pct = line.range(of: " %)"),
           line.contains("Writing at"),
           let value = Double(line[open.upperBound..<pct.lowerBound].trimmingCharacters(in: .whitespaces)) {
            phase = .uploading(value / 100)
        } else if line.hasPrefix("Uploading") || line.contains("esptool") {
            if case .building = phase { phase = .uploading(0) }
        }
    }

    private func finish(status: Int32, reason: Process.TerminationReason, onSuccess: @MainActor () -> Void) {
        process = nil
        if let port { didReleasePort?(port) }
        if !partialLine.isEmpty { log.append(partialLine); partialLine = "" }
        if reason == .uncaughtSignal {
            phase = .failed("Cancelled.")
        } else if status == 0 {
            phase = .succeeded(.now)
            onSuccess()
        } else {
            phase = .failed(Self.summarize(log))
        }
    }

    /// Picks the most useful error line from PlatformIO/esptool output.
    private static func summarize(_ log: [String]) -> String {
        let patterns = ["could not open port", "Resource busy", "No serial data received",
                        "A fatal error occurred", "error:", "Error:", "*** ["]
        for line in log.reversed() {
            if line.contains("Resource busy") || line.contains("could not open port") {
                return "Port busy — close any serial monitor (e.g. in VS Code) and try again."
            }
            if patterns.contains(where: line.contains) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return "Build or upload failed — see log."
    }
}
