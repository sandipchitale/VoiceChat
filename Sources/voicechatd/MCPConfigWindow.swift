import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Spec §10 — the "MCP Server Config…" menu item: a sample client configuration
// the person can copy or save, instead of hand-assembling paths and ports —
// either as a config file, or as the commands that register it from a shell.

/// The two ways the dialog offers the same configuration.
enum MCPConfigFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case shell = "Shell"

    var id: String { rawValue }

    var text: String {
        switch self {
        case .json:  MCPConfigSample.json()
        case .shell: MCPConfigSample.shell()
        }
    }

    var headline: String {
        switch self {
        case .json:  "Add this to your MCP client's configuration"
        case .shell: "Or register VoiceChat from a terminal"
        }
    }

    var detail: String {
        switch self {
        case .json:
            "For example a project's .mcp.json. Use either entry — the HTTP one also needs “Streamable HTTP” switched on in the menu bar."
        case .shell:
            "Each line removes any earlier entry, then adds it again, so it is safe to re-run. The HTTP entries also need “Streamable HTTP” switched on in the menu bar."
        }
    }

    var fileName: String {
        switch self {
        case .json:  "mcp.json"
        case .shell: "voicechat-mcp.sh"
        }
    }

    var contentType: UTType {
        switch self {
        case .json:  .json
        case .shell: .shellScript
        }
    }
}

enum MCPConfigSample {
    static let stdioPath = "/Applications/VoiceChat.app/Contents/MacOS/voicechat-mcp"
    static var httpURL: String {
        "http://\(HTTPServerLauncher.host):\(HTTPServerLauncher.configuredPort)/mcp"
    }

    /// A `.mcp.json`-style document for both transports: the stdio server at its
    /// standard install location, and the HTTP one at the configured port.
    static func json() -> String {
        """
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

    /// One host's command for one transport. Every command removes first, so
    /// re-running it replaces an entry instead of failing on a duplicate name.
    struct ShellCommand: Identifiable {
        enum Transport: String { case stdio, http }

        let host: String
        let transport: Transport
        let command: String

        var id: String { "\(host) \(transport.rawValue)" }
    }

    /// The same two servers, registered through each host's own CLI — in the
    /// order they are shown.
    static func shellCommands() -> [ShellCommand] {
        let path = shellQuoted(stdioPath)
        let url = shellQuoted(httpURL)
        return [
            .init(host: "Claude Code", transport: .stdio,
                  command: "claude mcp remove voicechat-stdio ; claude mcp add voicechat-stdio \(path)"),
            .init(host: "Claude Code", transport: .http,
                  command: "claude mcp remove voicechat-http ; claude mcp add --transport http voicechat-http \(url)"),
            .init(host: "Antigravity", transport: .stdio,
                  command: "agy mcp remove voicechat-stdio ; agy mcp add voicechat-stdio \(path)"),
            .init(host: "Antigravity", transport: .http,
                  command: "agy mcp remove voicechat-http ; agy mcp add voicechat-http \(url)"),
            .init(host: "Codex", transport: .stdio,
                  command: "codex mcp remove voicechat-stdio ; codex mcp add voicechat-stdio -- \(path)"),
            .init(host: "Codex", transport: .http,
                  command: "codex mcp remove voicechat-http ; codex mcp add voicechat-http --url \(url)"),
        ]
    }

    /// The commands grouped by host, keeping their order.
    static func shellCommandsByHost() -> [(host: String, commands: [ShellCommand])] {
        var groups: [(host: String, commands: [ShellCommand])] = []
        for command in shellCommands() {
            if let last = groups.indices.last, groups[last].host == command.host {
                groups[last].commands.append(command)
            } else {
                groups.append((command.host, [command]))
            }
        }
        return groups
    }

    /// Every command as one script, a comment heading each host — what the
    /// bottom bar's Copy and Save… hand over. Derived from the same list the
    /// rows show, so the two can never disagree.
    static func shell() -> String {
        shellCommandsByHost()
            .map { group in
                (["# \(group.host)"] + group.commands.map(\.command)).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    /// A dialog width that fits the longest line of any format unwrapped,
    /// capped to the screen (where the text then scrolls sideways instead).
    /// `extra` is room for anything drawn beside the text on each line.
    @MainActor
    static func dialogWidth(for texts: [String], extra: CGFloat = 0) -> CGFloat {
        let longest = texts.flatMap { $0.split(separator: "\n") }.map(\.count).max() ?? 0
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let glyph = ("0" as NSString).size(withAttributes: [.font: font]).width
        // Text + its 10 pt padding either side + the 20 pt window padding either
        // side + room for a vertical scroller.
        let wanted = ceil(CGFloat(longest) * glyph) + extra + 2 * 10 + 2 * 20 + 16
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return min(max(wanted, 580), screen * 0.9)
    }

    private static func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value,
                                               options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
    }

    /// Single-quoted for a POSIX shell, so a path with spaces survives.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class MCPConfigWindowController: NSWindowController {
    private static var current: MCPConfigWindowController?

    static func show() {
        let controller = current ?? MCPConfigWindowController()
        current = controller
        controller.present()
    }

    private init() {
        // The shell rows carry a copy button and a transport label beside
        // each command, so they need a little more than their text.
        let width = max(
            MCPConfigSample.dialogWidth(for: [MCPConfigSample.json()]),
            MCPConfigSample.dialogWidth(for: MCPConfigSample.shellCommands().map(\.command),
                                        extra: MCPConfigView.shellRowChrome))
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
            width: width,
            onSave: { [weak self] format in self?.save(format) },
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

    private func save(_ format: MCPConfigFormat) {
        guard let window else { return }
        let text = format.text
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.fileName
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
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
    let width: CGFloat
    let onSave: (MCPConfigFormat) -> Void
    let onClose: () -> Void
    @State private var format: MCPConfigFormat = .json
    @State private var copied = false
    /// The one shell row whose copy button shows a checkmark just now.
    @State private var copiedCommand: String?

    /// Width a shell row adds beside its command: the copy button, the
    /// transport label, and the spacing between them.
    static let shellRowChrome: CGFloat = 22 + 10 + 36 + 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $format) {
                ForEach(MCPConfigFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            Text(format.headline)
                .font(.headline)
            Text(format.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView([.vertical, .horizontal]) {
                Group {
                    switch format {
                    case .json:  jsonText
                    case .shell: shellRows
                    }
                }
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
                Button("Save…") { onSave(format) }
                Button(action: copy) {
                    // On Shell the rows copy one line each, so this one says
                    // plainly that it takes the lot. The longest label is laid
                    // out invisibly underneath, so the button keeps one width
                    // whichever tab is showing and while it says "Copied".
                    ZStack {
                        Label("Copy All", systemImage: "doc.on.doc").hidden()
                        Label(copied ? "Copied" : (format == .shell ? "Copy All" : "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: width, height: 420)
    }

    // MARK: Tabs

    private var jsonText: some View {
        Text(format.text)
            .font(.system(size: 12, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
    }

    /// Every command, grouped by host, each with its own copy button — most
    /// people want the one line for the one host they use.
    private var shellRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(MCPConfigSample.shellCommandsByHost(), id: \.host) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.host.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    ForEach(group.commands) { command in
                        shellRow(command)
                    }
                }
            }
        }
    }

    /// The copy button leads the row so the buttons form one column that
    /// never scrolls out of view, however long each command runs.
    private func shellRow(_ command: MCPConfigSample.ShellCommand) -> some View {
        let isCopied = copiedCommand == command.id
        return HStack(spacing: 10) {
            Button { copyCommand(command) } label: {
                // A fixed box: `checkmark` is shorter than `doc.on.doc`, and
                // letting the glyph size the row made the line jump on copy.
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 22, height: 18)
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .transaction { $0.animation = nil }
            }
            .buttonStyle(.borderless)
            .help("Copy this \(command.host) command")
            .accessibilityLabel("Copy \(command.host) \(command.transport.rawValue) command")

            Text(command.transport.rawValue)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            Text(command.command)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
    }

    // MARK: Copying

    private func copyCommand(_ command: MCPConfigSample.ShellCommand) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.command, forType: .string)
        copiedCommand = command.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCommand == command.id { copiedCommand = nil }
        }
    }

    /// The bottom bar's Copy: the whole tab, e.g. to paste into an email.
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
