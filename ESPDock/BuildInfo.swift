import AppKit
import Foundation

/// Version · build · build date, shown in the About panel so it's obvious
/// whether the running binary is the latest build.
enum BuildInfo {
    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    static var buildDate: Date? {
        guard let raw = Bundle.main.infoDictionary?["BuildDate"] as? String,
              !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
    static var buildDateDisplay: String {
        guard let date = buildDate else { return "unknown date" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
    static var versionLine: String { "Version \(marketingVersion) (build \(buildNumber))" }
    static var summary: String { "\(versionLine) · Built \(buildDateDisplay)" }

    @MainActor static func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Built \(buildDateDisplay)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
