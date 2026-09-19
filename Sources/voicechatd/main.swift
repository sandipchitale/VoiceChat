import AppKit
import SwiftUI
import VoiceChatKit
import VoiceChatMCPServer
import VoiceChatUI

// Spec §2.1 / §10 — the daemon process: menu bar applet, VCP listener, and
// window host, all in one NSApplication (R-ARCH-1).

let daemonVersion = "2.0.0"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var server: DaemonServer!
    private var httpServer: ConverseHTTPServer?
    private var testSessions: [Session] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no application menu — the menu bar item is the whole
        // surface (R-APP-1). Phase 6 moves this to LSUIElement in a bundle.
        NSApp.setActivationPolicy(.accessory)

        // A standard Edit menu so the panes get the system editing shortcuts —
        // ⌘X/⌘C/⌘V/⌘A and ⌘Z/⇧⌘Z. NSTextView implements every one of these
        // actions through the responder chain; without a main menu carrying the
        // key equivalents they never reach the field editor. An accessory app
        // shows no menu bar, but its main menu still services key equivalents
        // for the key window.
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle",
                                           accessibilityDescription: "VoiceChat")

        server = DaemonServer(version: daemonVersion)
        server.onSessionsChanged = { [weak self] in self?.rebuildMenu() }

        do {
            try server.start()
        } catch {
            presentFatal("VoiceChat could not open its control socket.\n\n\(error)")
            return
        }
        rebuildMenu()
        if HTTPServerLauncher.startsAutomatically {
            startHTTPServer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // R-APP-6 / R-VCP-14 — end every session, on both transports, so no
        // host is left with a hanging call.
        server?.stop()
        if let httpServer {
            Task { await httpServer.stop() }
        }
    }

    // MARK: Menu (§10)

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled("VoiceChat \(daemonVersion)"))
        menu.addItem(.separator())

        let sessions = server.sessions.values.sorted { $0.id < $1.id }
        if sessions.isEmpty {
            menu.addItem(disabled("Idle"))
        } else {
            menu.addItem(disabled("\(sessions.count) conversation\(sessions.count == 1 ? "" : "s") open"))
            for session in sessions {
                let label = "    \(session.model.sessionDisplayName) — turn \(session.model.turn)"
                let item = NSMenuItem(title: label, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.toolTip = session.model.workingDirectory
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let test = NSMenuItem(title: "Test Conversation…",
                              action: #selector(startTestConversation), keyEquivalent: "t")
        test.keyEquivalentModifierMask = [.command, .option]
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())
        let httpItem = NSMenuItem(title: "Streamable HTTP (port \(HTTPServerLauncher.configuredPort))",
                                  action: #selector(toggleHTTPServer), keyEquivalent: "")
        httpItem.target = self
        httpItem.state = httpServer != nil ? .on : .off
        httpItem.toolTip = "http://\(HTTPServerLauncher.host):\(HTTPServerLauncher.configuredPort)/mcp — reachable by any local user account, not just you (§10, R-APP-7 note)."
        menu.addItem(httpItem)

        let configItem = NSMenuItem(title: "MCP Server Config…",
                                    action: #selector(showMCPConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoiceChat", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.image = NSImage(
            systemSymbolName: sessions.isEmpty ? "waveform.circle" : "waveform.circle.fill",
            accessibilityDescription: "VoiceChat")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The standard system Edit menu. Every action targets the first responder
    /// (`target == nil`), so the focused pane's `NSTextView` handles it and
    /// enables/disables each item via its own validation. This is also what the
    /// command-mode "Cut that" / "Undo that" voice commands ultimately drive.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // A minimal application menu so ⌘Q behaves and the Edit menu is not the
        // first (application) slot.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let quitItem = appMenu.addItem(withTitle: "Quit VoiceChat",
                                       action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        server.focus(sessionId: id)
    }

    /// R-APP-3 — a full conversation loop with no MCP host, so speech, voices
    /// and commands can be checked without configuring anything.
    @objc private func startTestConversation() {
        let session = Session(id: "test-\(UUID().uuidString)",
                              title: "VoiceChat — Test Conversation",
                              hostName: "Test Conversation",
                              cwd: nil)
        testSessions.append(session)

        session.model.onSubmitPrompt = { [weak session] text in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                session?.present(response: """
                    You said: **\(text)**

                    This is the built-in test conversation, so nothing here came from a model. \
                    Press **Got it!** to compose another turn, or **End conversation** to finish.
                    """)
            }
        }
        session.model.onEnd = { _ in }
        session.show()
    }

    @objc private func showMCPConfig() {
        MCPConfigWindowController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Streamable HTTP MCP transport (§4, §10)

    @objc private func toggleHTTPServer() {
        if httpServer != nil {
            stopHTTPServer()
        } else {
            startHTTPServer()
        }
    }

    private func startHTTPServer() {
        let port = HTTPServerLauncher.configuredPort
        let candidate = ConverseHTTPServer(host: HTTPServerLauncher.host, port: port,
                                           daemonServer: server, waitMs: HTTPServerLauncher.waitMs)
        Task { @MainActor in
            do {
                try await candidate.start()
                self.httpServer = candidate
                self.log("MCP Streamable HTTP listening on http://\(HTTPServerLauncher.host):\(port)/mcp")
            } catch {
                self.log("MCP HTTP server failed to start: \(error)")
                // Unlike a VCP-socket failure at launch, this is a person
                // clicking a menu item (or an auto-start that just failed) —
                // silence would look like nothing happened at all.
                self.presentHTTPFailure(port: port, error: error)
            }
            self.rebuildMenu()
        }
    }

    private func stopHTTPServer() {
        guard let httpServer else { return }
        self.httpServer = nil
        Task { await httpServer.stop() }
        rebuildMenu()
    }

    private func presentHTTPFailure(port: Int, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't start the Streamable HTTP MCP server"
        alert.informativeText = "Port \(port) — \(error)\n\nAnother process may already be using this port. Set VOICECHAT_MCP_HTTP_PORT to a different one, or free the port and try again."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[voicechatd] \(message)\n".utf8))
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VoiceChat cannot start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
