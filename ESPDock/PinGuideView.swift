import AppKit
import SwiftUI

/// Popover content: what a pin is, how to use it (with Arduino snippets) and
/// what to watch out for.
struct PinGuideView: View {
    let guide: PinGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(guide.title).font(.title3.weight(.bold).monospaced())
                Text(guide.subtitle).font(.callout.monospaced()).foregroundStyle(.secondary)
                Spacer()
            }
            if !guide.functions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(guide.functions, id: \.self) { f in
                        Text(f.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(f.role.color)
                            .background(f.role.color.opacity(0.15), in: .rect(cornerRadius: 4))
                    }
                }
            }

            ForEach(guide.uses) { use in
                VStack(alignment: .leading, spacing: 4) {
                    Text(use.title).font(.callout.weight(.semibold))
                    Text(use.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeSnippet(code: use.code)
                }
            }

            if !guide.cautions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(guide.cautions, id: \.self) { c in
                        Label {
                            Text(c).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 400)
    }
}

private struct CodeSnippet: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

/// Shows a guide popover on hover (after a short delay, so sweeping the mouse
/// across the diagram doesn't flash popovers) and keeps it open on click, so
/// the code can be selected or copied. Click again or press Esc to close.
private struct PinGuidePopover: ViewModifier {
    let guide: PinGuide
    let edge: Edge
    @State private var hovering = false
    @State private var pinned = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        if hovering { shown = true }
                    }
                } else if !pinned {
                    shown = false
                }
            }
            .onTapGesture {
                pinned.toggle()
                shown = pinned || hovering
            }
            .popover(isPresented: $shown, arrowEdge: edge) {
                PinGuideView(guide: guide)
            }
            .onChange(of: shown) { _, isShown in
                guard !isShown else { return }
                // The popover is transient: a click on the pin while its
                // hover popover is up is consumed to dismiss it, so the tap
                // gesture never fires and "click to keep open" closed it
                // instead (found in the audit). A click-dismissal with the
                // pointer still over this pin therefore means "pin it".
                // Esc (a key event) and clicks elsewhere still close it.
                let byClick = [.leftMouseDown, .leftMouseUp].contains(NSApp.currentEvent?.type)
                if hovering, !pinned, byClick {
                    pinned = true
                    Task { shown = true }
                } else {
                    pinned = false
                }
            }
    }
}

extension View {
    func pinGuide(_ guide: PinGuide, edge: Edge) -> some View {
        modifier(PinGuidePopover(guide: guide, edge: edge))
    }
}
