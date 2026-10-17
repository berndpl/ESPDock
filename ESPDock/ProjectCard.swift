import SwiftUI

/// The linked PlatformIO project for the connected board: edit it with the
/// AI tool used on it (or VS Code),
/// see whether the code changed since the last deploy, and ▶︎ build + upload.
struct ProjectCard: View {
    let board: Board
    let model: BoardModel?
    let projects: ProjectLinks
    let deployer: Deployer
    let firmware: FirmwareProbe
    @State private var error: String?
    @State private var showLog = false
    /// AI coding tools used on the linked project, most recent first.
    @State private var agents: [AgentUse] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let link = projects.link(for: board) {
                    linked(link)
                } else {
                    unlinked
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Unlinked

    private var unlinked: some View {
        HStack {
            Label("No project linked", systemImage: "folder.badge.plus")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Link Project…") { error = projects.chooseProject(for: board, model: model) }
                .disabled(board.macAddress == nil)
        }
    }

    // MARK: Linked

    @ViewBuilder private func linked(_ link: ProjectLink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(link.name).font(.headline)
                .help("\(link.path)\nenv: \(link.environment)")
            Spacer()
            // Native split button: click edits with the AI used on this
            // project (its CLI in Terminal); the chevron holds the rest.
            let primary = agents.first?.agent
            Menu {
                ForEach(agents.dropFirst(), id: \.agent) { use in
                    Button(use.agent.name) { use.agent.open(link.url) }
                }
                if primary != nil {
                    Button("Open in VS Code") { VSCode.open(link.url) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([link.url]) }
                Divider()
                let envs = projects.environments(for: board)
                if envs.count > 1 {
                    Picker("Environment", selection: Binding(
                        get: { link.environment },
                        set: { projects.setEnvironment($0, for: board) })) {
                        ForEach(envs, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Change Project…") { error = projects.chooseProject(for: board, model: model) }
                Button("Unlink Project", role: .destructive) { projects.unlink(board) }
            } label: {
                if let primary {
                    Label(primary.name, systemImage: "apple.terminal")
                } else {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } primaryAction: {
                if let primary { primary.open(link.url) } else { VSCode.open(link.url) }
            }
            .help(primaryHelp(link))
            .fixedSize()
        }
        // Off the main actor: scanning Copilot's session folders reads a few
        // thousand small files. Once per linked project.
        .task(id: link.path) {
            // Last known result first (no label jump), then a fresh scan.
            if agents.isEmpty {
                agents = AgentCache.agents(for: link.path).map { AgentUse(agent: $0, lastUsed: .distantPast) }
            }
            let url = link.url
            let fresh = await Task.detached { AgentDetector.detect(projectAt: url) }.value
            agents = fresh
            AgentCache.store(fresh.map(\.agent), for: link.path)
        }

        Divider()

        status(link)
        versionReportingRow(link)
        if !board.supportsUpload, case .changed = codeStatus(link) {
            Text("Wi-Fi is read-only. Connect USB to deploy; local builds are still available in your editor.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if showLog, !deployer.log.isEmpty, deployer.targetMAC == board.macAddress {
            LogView(lines: deployer.log)
        }
    }

    /// Says why this tool was picked, so the choice isn't a mystery.
    private func primaryHelp(_ link: ProjectLink) -> String {
        guard let use = agents.first else {
            return VSCode.isInstalled ? "Open \(link.name) in Visual Studio Code"
                                      : "VS Code not found — opens in Finder"
        }
        let base = "Starts \(use.agent.command) in Terminal in \(link.name)"
        // Cached entries (shown until the fresh scan lands) carry no date.
        guard use.lastUsed != .distantPast else { return base }
        return base + " · last used \(use.lastUsed.formatted(.relative(presentation: .named)))"
    }

    // MARK: Status + ▶︎

    @ViewBuilder private func status(_ link: ProjectLink) -> some View {
        let mine = deployer.targetMAC == board.macAddress
        HStack(spacing: 10) {
            if mine, deployer.isRunning {
                running
            } else {
                stateLine(link, failed: mine ? failure : nil)
                Spacer()
                if needsDeploy(link) || (mine && failure != nil) {
                    deployButton(link)
                }
            }
        }
        .animation(.snappy, value: deployer.phase)
    }

    private var failure: String? {
        if case let .failed(msg) = deployer.phase { return msg }
        return nil
    }

    /// What we know about the code on the board vs. the code in the folder.
    private enum CodeStatus {
        case checking
        case upToDate(help: String)
        case changed(title: String, detail: String?, help: String)
        case otherProject(String)
        case unknown(title: String, detail: String)

        var needsDeploy: Bool {
            switch self {
            case .checking, .upToDate: false
            default: true
            }
        }
    }

    /// Prefers the firmware's own report (authoritative — covers uploads from
    /// VS Code too); falls back to ESPDock's record of its last deploy.
    private func codeStatus(_ link: ProjectLink) -> CodeStatus {
        guard let current = projects.watchedMAC == board.macAddress ? projects.currentManifest : nil
        else { return .checking }
        let currentHash = CodeFingerprint.combined(current)

        if let report = firmware.report(for: board), !report.source.isEmpty {
            let built = report.builtDate?.formatted(date: .abbreviated, time: .shortened) ?? report.built
            let help = "Board runs \(report.project) · built \(built)"
                + (report.commit.isEmpty ? "" : " · commit \(report.commit)")
            if report.project != link.name { return .otherProject(report.project) }
            if report.source == currentHash { return .upToDate(help: help) }
            // If the board runs what ESPDock last deployed, we can name the files.
            if let deployed = link.deployed, CodeFingerprint.combined(deployed.manifest) == report.source {
                let changes = CodeFingerprint.changes(from: deployed.manifest, to: current)
                return .changed(title: "\(changes.count) file\(changes.count == 1 ? "" : "s") changed since the build on the board",
                                detail: changes.prefix(3).joined(separator: ", ") + (changes.count > 3 ? " …" : ""),
                                help: help + "\n\n" + changes.joined(separator: "\n"))
            }
            return .changed(title: "Board runs different code",
                            detail: "Built \(built)" + (report.commit.isEmpty ? "" : " · \(report.commit)"),
                            help: help)
        }

        if let deployed = link.deployed {
            let changes = CodeFingerprint.changes(from: deployed.manifest, to: current)
            let help = "Deployed from ESPDock \(deployed.date.formatted(date: .abbreviated, time: .shortened))"
            if changes.isEmpty { return .upToDate(help: help) }
            return .changed(title: "\(changes.count) file\(changes.count == 1 ? "" : "s") changed since last deploy",
                            detail: changes.prefix(3).joined(separator: ", ") + (changes.count > 3 ? " …" : ""),
                            help: changes.joined(separator: "\n"))
        }
        if firmware.state(for: board) == .probing { return .checking }
        return .unknown(title: "Installed code unknown", detail: "Not deployed from ESPDock, and the board doesn't report a version.")
    }

    @ViewBuilder private func stateLine(_ link: ProjectLink, failed: String?) -> some View {
        if let failed {
            VStack(alignment: .leading, spacing: 2) {
                Label("Deploy failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(failed).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        } else {
            switch codeStatus(link) {
            case .checking:
                Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .upToDate(let help):
                Label {
                    Text("Board is up to date")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .help(help)
            case let .changed(title, detail, help):
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        if let detail {
                            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                }
                .help(help)
            case .otherProject(let name):
                Label("Board runs “\(name)”, not this project", systemImage: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.orange)
            case let .unknown(title, detail):
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func needsDeploy(_ link: ProjectLink) -> Bool {
        codeStatus(link).needsDeploy
    }

    /// Offered when the project lacks the ESPDock firmware library.
    @ViewBuilder private func versionReportingRow(_ link: ProjectLink) -> some View {
        if !VersionReportingInstaller.isInstalled(projectAt: link.url) {
            HStack {
                Text("See the exact version on the board, even after uploads from VS Code.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Version Reporting…") { installVersionReporting(link) }
                    .controlSize(.small)
            }
        } else if firmware.state(for: board) == .noAnswer, firmware.report(for: board) == nil {
            Text("Version reporting is installed — deploy, and make sure setup() calls ESPDock::begin().")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func installVersionReporting(_ link: ProjectLink) {
        do {
            try VersionReportingInstaller.install(projectAt: link.url, environment: link.environment)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = "Version reporting added to \(link.name)"
        alert.informativeText = """
            Added lib/ESPDock and its build script to [env:\(link.environment)] in platformio.ini.

            Add these lines to your sketch, then Build & Deploy:

            \(VersionReportingInstaller.snippet)
            """
        alert.addButton(withTitle: "Copy Code")
        alert.addButton(withTitle: "Open in VS Code")
        alert.addButton(withTitle: "Done")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(VersionReportingInstaller.snippet, forType: .string)
        case .alertSecondButtonReturn:
            VSCode.open(link.url)
        default: break
        }
        projects.rescan()
    }

    private func deployButton(_ link: ProjectLink) -> some View {
        Button {
            error = nil
            showLog = false
            // Fingerprint the code *before* building, so edits made during the
            // build correctly show as "changed" afterwards.
            let manifest = CodeFingerprint.manifest(projectAt: link.url)
            let commit = CodeFingerprint.gitCommit(projectAt: link.url)
            deployer.deploy(link, to: board) {
                projects.recordDeployment(for: board, manifest: manifest, gitCommit: commit)
                // The board reboots after upload; ask it what it now runs.
                firmware.probe(board, after: .seconds(3))
            }
        } label: {
            Label("Build & Deploy", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!board.supportsUpload)
        .help(board.supportsUpload ? "Build \(link.environment) and upload to \(board.port)  (⌘R)" : "Connect USB to deploy. Wi-Fi uploads are not supported.")
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch deployer.phase {
                case .uploading(let p):
                    Text("Uploading… \(Int(p * 100)) %")
                    Spacer()
                    ProgressView(value: p).frame(width: 140)
                default:
                    Text("Building…")
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { deployer.cancel() }
            }
            Text(deployer.log.last ?? "")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.suffix(400).enumerated()), id: \.offset) { i, line in
                        Text(line).id(i)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .onAppear { proxy.scrollTo(min(lines.count, 400) - 1, anchor: .bottom) }
        }
    }
}
