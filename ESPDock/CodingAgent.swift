import AppKit
import Foundation

/// The AI coding tool used with a project, so the project card can open the
/// project where the work actually happens.
///
/// Detected from each tool's own session records, not from repo files: a repo
/// can carry both a `.claude/` folder and Copilot instructions, but only one
/// was used last. Whichever has the most recent session for the project wins.
enum CodingAgent: String, Hashable, Sendable {
    case claudeCode
    case copilot

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .copilot: "Copilot"
        }
    }

    var command: String {
        switch self {
        case .claudeCode: "claude"
        case .copilot: "copilot"
        }
    }

    /// Starts the agent's CLI in a new Terminal window in the project folder.
    @MainActor func open(_ project: URL) {
        Terminal.run(command, in: project, title: project.lastPathComponent)
    }
}

/// Last detected agents per project path, so the button shows the right tool
/// at once instead of "Open in VS Code" for the seconds a fresh scan takes.
enum AgentCache {
    private static let key = "codingAgentsByProject"

    static func agents(for path: String) -> [CodingAgent] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return (all[path] ?? []).compactMap(CodingAgent.init(rawValue:))
    }

    static func store(_ agents: [CodingAgent], for path: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[path] = agents.map(\.rawValue)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// A detected agent with the time it was last used on the project.
struct AgentUse: Hashable, Sendable {
    let agent: CodingAgent
    let lastUsed: Date
}

enum AgentDetector {
    /// Agents used on the project, most recent first. Reads small session
    /// files only (Copilot keeps a few thousand session folders, each with a
    /// short workspace.yaml), so call it off the main actor; it's run once per
    /// linked project.
    static func detect(projectAt project: URL) -> [AgentUse] {
        let path = project.standardizedFileURL.path
        var uses: [CodingAgent: Date] = [:]
        func note(_ agent: CodingAgent, _ date: Date) {
            if date > uses[agent] ?? .distantPast { uses[agent] = date }
        }
        if let date = claudeLastUse(path) { note(.claudeCode, date) }
        for (agent, date) in copilotUses(path) { note(agent, date) }
        return uses.map { AgentUse(agent: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Claude Code keeps one folder per working directory under
    /// ~/.claude/projects, named by the path with every non-alphanumeric
    /// character replaced by "-"; each session is a .jsonl file in it.
    private static func claudeLastUse(_ path: String) -> Date? {
        let slug = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// Copilot (CLI and the VS Code agent host alike) writes
    /// ~/.copilot/session-state/<id>/workspace.yaml with a `cwd:` line; the
    /// file's modification date is the session's last activity. Sessions from
    /// VS Code count too: it's the same agent, and the CLI picks them up.
    private static func copilotUses(_ path: String) -> [(CodingAgent, Date)] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var result: [(CodingAgent, Date)] = []
        for id in sessions {
            let file = root.appendingPathComponent(id).appendingPathComponent("workspace.yaml")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let cwd = text.split(separator: "\n").prefix(12)
                .first { $0.hasPrefix("cwd: ") }.map { String($0.dropFirst(5)) }
            guard let cwd, cwd == path || cwd.hasPrefix(path + "/") else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            result.append((.copilot, date))
        }
        return result
    }
}

/// Opens a new Terminal window running a command in a folder, via a temporary
/// `.command` file so no Automation (AppleScript) permission prompt is needed.
enum Terminal {
    @MainActor static func run(_ command: String, in folder: URL, title: String) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ESPDockTerminal", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("\(UUID().uuidString).command")
            // Login shell (-l) so PATH includes ~/.local/bin, Homebrew, etc.
            try """
            #!/bin/zsh -l
            printf '\\033]0;%s\\007' \(title.shellQuoted)
            cd \(folder.path.shellQuoted) && \(command)
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", script.path]
            try process.run()
        } catch {
            NSSound.beep()
        }
    }
}

private extension String {
    /// POSIX single-quote escaping, safe for interpolation into a shell command.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
