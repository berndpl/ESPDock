import AppKit
import CoreServices
import CryptoKit
import Foundation
import Observation

/// A PlatformIO project linked to one physical board (keyed by MAC address),
/// plus what ESPDock last deployed to that board.
struct ProjectLink: Codable, Equatable {
    var path: String
    var environment: String
    var deployed: Deployment?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Snapshot of the code at the moment ESPDock uploaded it.
struct Deployment: Codable, Equatable {
    var date: Date
    /// Relative path → SHA-256 of every tracked source file (see CodeFingerprint).
    var manifest: [String: String]
    var gitCommit: String?
}

/// What `platformio.ini` declares.
struct PlatformIOConfig {
    struct Environment: Hashable {
        let name: String
        let board: String?
        let platform: String?
    }
    let environments: [Environment]
    let defaultEnvironments: [String]

    /// Minimal INI reading: only `[env:NAME]` sections and their `board`,
    /// `platform` keys, plus `default_envs`. Enough to pick an environment;
    /// PlatformIO itself does the real parsing when building.
    static func read(projectAt url: URL) -> PlatformIOConfig? {
        guard let text = try? String(contentsOf: url.appendingPathComponent("platformio.ini"), encoding: .utf8)
        else { return nil }
        var envs: [Environment] = []
        var defaults: [String] = []
        var current: String?
        var board: String?, platform: String?
        func flush() {
            if let current { envs.append(.init(name: current, board: board, platform: platform)) }
            board = nil; platform = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: ";", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("[") {
                flush()
                current = line.hasPrefix("[env:") ? String(line.dropFirst(5).dropLast()) : nil
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "board" where current != nil: board = parts[1]
            case "platform" where current != nil: platform = parts[1]
            case "default_envs":
                defaults = parts[1].split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            default: break
            }
        }
        flush()
        return PlatformIOConfig(environments: envs, defaultEnvironments: defaults)
    }

    /// Best environment for a board: one whose `board =` matches the model's
    /// PlatformIO id, then `default_envs`, then the first non-native one.
    func bestEnvironment(forPlatformIOBoard pioBoard: String?) -> String? {
        if let pioBoard, let match = environments.first(where: { $0.board == pioBoard }) { return match.name }
        if let d = defaultEnvironments.first(where: { name in environments.contains { $0.name == name } }) { return d }
        return environments.first(where: { $0.platform != "native" })?.name ?? environments.first?.name
    }
}

/// Hashes the files that make up the firmware, so "has the code changed since
/// the last deploy?" can be answered per file.
///
/// Tracked: platformio.ini, *.csv partition tables at the root, and everything
/// under src/, include/, lib/. Not tracked: .pio/ (build output), test/ (not in
/// the firmware), data/ (filesystem image, uploaded separately), dot-folders.
enum CodeFingerprint {
    static func manifest(projectAt root: URL) -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        func add(_ url: URL) {
            guard let data = try? Data(contentsOf: url) else { return }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            result[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        where name == "platformio.ini" || name.hasSuffix(".csv") {
            add(root.appendingPathComponent(name))
        }
        for dir in ["src", "include", "lib"] {
            let base = root.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                add(url)
            }
        }
        return result
    }

    /// Files added, removed or modified between two manifests, sorted.
    static func changes(from old: [String: String], to new: [String: String]) -> [String] {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    static func gitCommit(projectAt root: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path, "rev-parse", "--short", "HEAD"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Watches a folder tree with FSEvents and calls back (debounced by FSEvents'
/// 1 s latency) when a tracked file may have changed. Events under .pio/ and
/// .git/ are ignored, so builds don't trigger rescans.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { !$0.contains("/.pio/") && !$0.contains("/.git/") }
            if relevant { MainActor.assumeIsolated { watcher.onChange() } }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                                              | kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// All project links, persisted as JSON in UserDefaults ("projectLinks").
/// Also tracks the live code state of the link for the connected board.
@MainActor
@Observable
final class ProjectLinks {
    private static let key = "projectLinks"
    private var byMAC: [String: ProjectLink]

    /// Live state for the board currently shown.
    private(set) var watchedMAC: String?
    private(set) var currentManifest: [String: String]?
    private(set) var currentHardwareNotes = ""
    @ObservationIgnored private var watcher: FolderWatcher?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: ProjectLink].self, from: data) {
            byMAC = decoded
        } else {
            byMAC = [:]
        }
    }

    func link(for board: Board) -> ProjectLink? {
        board.macAddress.flatMap { byMAC[$0] }
    }

    /// Files changed since the last ESPDock deploy; nil = never deployed or not scanned yet.
    func changes(for board: Board) -> [String]? {
        guard let link = link(for: board), let deployed = link.deployed,
              let current = currentManifest, watchedMAC == board.macAddress else { return nil }
        return CodeFingerprint.changes(from: deployed.manifest, to: current)
    }

    // MARK: Editing

    /// Lets the user pick a PlatformIO folder and links it. Returns an error
    /// message to show, or nil on success/cancel.
    func chooseProject(for board: Board, model: BoardModel?) -> String? {
        guard let mac = board.macAddress else { return "This board has no MAC address to remember it by." }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Choose a PlatformIO project folder (it contains platformio.ini)."
        if let existing = byMAC[mac] { panel.directoryURL = existing.url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let config = PlatformIOConfig.read(projectAt: url) else {
            return "\(url.lastPathComponent) has no platformio.ini."
        }
        guard let env = config.bestEnvironment(forPlatformIOBoard: model?.platformIOBoard) else {
            return "platformio.ini in \(url.lastPathComponent) defines no [env:…] section."
        }
        byMAC[mac] = ProjectLink(path: url.path, environment: env, deployed: nil)
        save()
        watch(board)
        return nil
    }

    func setEnvironment(_ env: String, for board: Board) {
        guard let mac = board.macAddress else { return }
        byMAC[mac]?.environment = env
        save()
    }

    func unlink(_ board: Board) {
        guard let mac = board.macAddress else { return }
        byMAC[mac] = nil
        save()
        watch(nil)
    }

    func recordDeployment(for board: Board, manifest: [String: String], gitCommit: String?) {
        guard let mac = board.macAddress else { return }
        byMAC[mac]?.deployed = Deployment(date: .now, manifest: manifest, gitCommit: gitCommit)
        save()
    }

    // MARK: Watching

    /// Start watching the linked project of `board` (or stop, for nil).
    func watch(_ board: Board?) {
        let mac = board?.macAddress
        guard let link = board.flatMap({ self.link(for: $0) }) else {
            watcher = nil; watchedMAC = nil; currentManifest = nil; currentHardwareNotes = ""
            return
        }
        if mac == watchedMAC, watcher != nil { return }
        watchedMAC = mac
        currentManifest = nil
        currentHardwareNotes = ""
        watcher = FolderWatcher(path: link.path) { [weak self] in self?.rescan() }
        rescan()
    }

    func rescan() {
        guard let mac = watchedMAC, let link = byMAC[mac] else { return }
        let url = link.url
        // Hashing a typical sketch takes milliseconds, but keep it off the main thread.
        Task.detached(priority: .utility) {
            let manifest = CodeFingerprint.manifest(projectAt: url)
            let hardwareNotes = PeripheralScanner.hardwareNotes(projectAt: url)
            await MainActor.run { [weak self] in
                guard self?.watchedMAC == mac else { return }
                self?.currentManifest = manifest
                self?.currentHardwareNotes = hardwareNotes
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(byMAC) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func environments(for board: Board) -> [String] {
        guard let link = link(for: board) else { return [] }
        return PlatformIOConfig.read(projectAt: link.url)?.environments.map(\.name) ?? []
    }
}

enum VSCode {
    /// Opens a folder in VS Code (by bundle id, so it works wherever it's installed).
    @MainActor static func open(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil
    }
}
