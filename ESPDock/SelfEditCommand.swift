#if os(macOS)
import AppKit
import Foundation
import SwiftUI

// MARK: - Self-Edit menu command
//
// Adds an "Edit…" item to the application menu (the bold, app-named menu at the
// far left of the menu bar). Choosing it opens a Terminal window in this app's
// own source project and starts a Copilot session to change the app.
//
// Zero configuration: the source path is captured at build time from `#filePath`
// and walked up to the repository root, so the installed app knows where its own
// code lives on this machine. (Personal apps are built and run locally, so the
// build-time path is valid at runtime.)
//
// Wire it into the app scene:
//
//   @main
//   struct MyApp: App {
//       var body: some Scene {
//           WindowGroup { ContentView() }
//               .commands { SelfEditCommands() }
//       }
//   }
//
// For a `MenuBarExtra`-only app, add a plain button that calls
// `SelfEditLauncher.launch()`.

struct SelfEditCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Edit…") {
                SelfEditLauncher.launch()
            }
            Divider()
        }
    }
}

enum SelfEditLauncher {
    /// Prompt handed to the Copilot CLI when the session starts. Edit this line
    /// to change what the session is asked to do.
    static let editPrompt = "/macos-iterate Work on this macOS project."

    /// Opens Terminal in this app's project root and starts a Copilot session.
    static func launch(sourceFilePath: String = #filePath) {
        guard let root = projectRoot(from: sourceFilePath) else {
            NSLog("SelfEdit: could not locate project root from \(sourceFilePath)")
            NSSound.beep()
            return
        }
        let command = "cd \(root.path.shellQuoted) && copilot -i \(editPrompt.shellQuoted)"
        openTerminal(command: command, title: "Edit")
    }

    /// Walks up from the build-time source path to find the best working
    /// directory for a Copilot session: the repository root (`.git`) is
    /// preferred; otherwise the nearest Xcode project/workspace directory.
    static func projectRoot(from sourceFilePath: String) -> URL? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        var xcodeFallback: URL?

        for _ in 0..<24 {
            let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            if entries.contains(".git") { return directory }
            if xcodeFallback == nil,
               entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                xcodeFallback = directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return xcodeFallback
    }

    /// Opens a new Terminal window running `command`, via a temporary `.command`
    /// file so no Automation/AppleScript permission prompt is required.
    private static func openTerminal(command: String, title: String) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelfEditCommands", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let scriptURL = directory
                .appendingPathComponent("edit-\(UUID().uuidString)")
                .appendingPathExtension("command")
            let script = """
            #!/bin/zsh
            printf '\\033]0;%s\\007' \(title.shellQuoted)
            \(command)
            exit $?
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", scriptURL.path]
            try process.run()
        } catch {
            NSLog("SelfEdit: failed to open Terminal — \(error.localizedDescription)")
        }
    }
}

private extension String {
    /// POSIX single-quote escaping, safe for interpolation into a shell command.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#endif
