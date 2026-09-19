import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Spec §10 — the "MCP Server Config…" menu item: a sample client configuration
// the person can copy or save, instead of hand-assembling paths and ports.

enum MCPConfigSample {
    /// A `.mcp.json`-style document for both transports: the stdio server at its
    /// standard install location, and the HTTP one at the configured port.
    static func json() -> String {
        let stdioPath = "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
        let httpURL = "http://\(HTTPServerLauncher.host):\(HTTPServerLauncher.configuredPort)/mcp"
        return """
        {
          "mcpServers": {
            "voicechat-stdio": {
              "type": "stdio",
              "command": \(quoted(stdioPath)),
              "args": []
            },
            "voicechat-http": {
              "type": "streamable-http",
              "url": \(quoted(httpURL))
            }
          }
        }
        """
    }

    /// A dialog width that fits the longest line of `json` unwrapped, capped to
    /// the screen (where the text then scrolls sideways instead).
    @MainActor
    static func dialogWidth(for json: String) -> CGFloat {
        let longest = json.split(separator: "\n").map(\.count).max() ?? 0
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let glyph = ("0" as NSString).size(withAttributes: [.font: font]).width
        // Text + its 10 pt padding either side + the 20 pt window padding either
        // side + room for a vertical scroller.
        let wanted = ceil(CGFloat(longest) * glyph) + 2 * 10 + 2 * 20 + 16
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return min(max(wanted, 580), screen * 0.9)
    }

    private static func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value,
                                               options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
    }
}

@MainActor
final class MCPConfigWindowController: NSWindowController {
    private static var current: MCPConfigWindowController?

    static func show() {
        let controller = current ?? MCPConfigWindowController(json: MCPConfigSample.json())
        current = controller
        controller.present()
    }

    private let json: String

    private init(json: String) {
        self.json = json
        let width = MCPConfigSample.dialogWidth(for: json)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "MCP Server Config"
        window.isReleasedWhenClosed = false
        // Conversation windows float; this dialog must not hide behind one.
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MCPConfigView(
            json: json,
            width: width,
            onSave: { [weak self] in self?.save() },
            onClose: { [weak self] in self?.close() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func save() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mcp.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [json] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

extension MCPConfigWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

private struct MCPConfigView: View {
    let json: String
    let width: CGFloat
    let onSave: () -> Void
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add this to your MCP client's configuration")
                .font(.headline)
            Text("For example a project's .mcp.json. Use either entry — the HTTP one also needs “Streamable HTTP” switched on in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView([.vertical, .horizontal]) {
                Text(json)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: width, height: 420)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
