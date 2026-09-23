import AppKit
import SwiftUI
import VoiceChatKit
import VoiceChatUI

// Spec §17 — the "New debate…" menu item: set a motion and two positions, then
// hand each seat's join instruction to whichever MCP client will argue it.

@MainActor
final class DebateSetupWindowController: NSWindowController {
    private static var current: DebateSetupWindowController?

    static func show(onCreate: @escaping (DebateRoom) -> Void) {
        let controller = current ?? DebateSetupWindowController(onCreate: onCreate)
        current = controller
        controller.present()
    }

    private init(onCreate: @escaping (DebateRoom) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "New Debate"
        window.isReleasedWhenClosed = false
        // Conversation windows float; this dialog must not hide behind one.
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: DebateSetupView(
            onCreate: { [weak self] room in
                onCreate(room)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension DebateSetupWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

private struct DebateSetupView: View {
    let onCreate: (DebateRoom) -> Void
    let onCancel: () -> Void

    @State private var motion = ""
    @State private var forPosition = "In favour of the motion."
    @State private var againstPosition = "Against the motion."
    @State private var statements = 6
    @State private var guidance = "Keep each statement under 120 words."
    @State private var forVoice = ""
    @State private var againstVoice = ""

    private var voices: [(name: String, identifier: String)] {
        DebateVoices.installed()
    }

    private var canCreate: Bool {
        !motion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set the motion, then invite two AI clients to argue it")
                .font(.headline)
            Text("The first seat opens the debate. Each statement is read aloud in its own voice, and you pass it to the other side by pressing Send.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Motion", text: $motion, prompt: Text("AI should write its own tests"))
                Section("Seats") {
                    TextField("“for” argues", text: $forPosition)
                    voicePicker("“for” voice", selection: $forVoice)
                    TextField("“against” argues", text: $againstPosition)
                    voicePicker("“against” voice", selection: $againstVoice)
                }
                Section {
                    Stepper("Statements before closing: \(statements)",
                            value: $statements, in: 2...40)
                    TextField("House rules", text: $guidance)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create Debate") { onCreate(room()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }

    @ViewBuilder
    private func voicePicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("System default").tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text(voice.name).tag(voice.identifier)
            }
        }
    }

    private func room() -> DebateRoom {
        DebateRoom(motion: motion.trimmingCharacters(in: .whitespacesAndNewlines),
                   seats: [
                       DebateSeat(key: "for", name: "For the motion",
                                  position: forPosition, voice: forVoice.isEmpty ? nil : forVoice),
                       DebateSeat(key: "against", name: "Against the motion",
                                  position: againstPosition,
                                  voice: againstVoice.isEmpty ? nil : againstVoice),
                   ],
                   maxStatements: statements,
                   guidance: guidance)
    }
}
