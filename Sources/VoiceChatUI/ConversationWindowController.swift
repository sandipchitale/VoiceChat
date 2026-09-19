import AppKit
import Observation
import SwiftUI
import VoiceChatKit

// Spec §6.1 — the window shell.

/// A borderless window refuses key status by default, which would leave the
/// panes unable to take typing or dictation focus.
final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
public final class ConversationWindowController: NSWindowController, NSWindowDelegate {
    public let model: ConversationModel
    /// Called when the person closes a window that had not already ended
    /// (§5.2 row 14) — this is what turns into a `window_closed` VCP event.
    public var onWindowClose: (() -> Void)?
    /// Called whenever the window actually closes, unconditionally — this is
    /// the true-disposal signal: once it fires, nothing keeps the session
    /// registered, and it can no longer be reopened from the menu bar.
    public var onWindowDidClose: (() -> Void)?
    private var suppressCloseCallback = false

    public init(model: ConversationModel, title: String) {
        self.model = model

        // Frameless, translucent, always on top — a pane of held glass rather
        // than a document window. The header inside the view stands in for the
        // title bar.
        let window = GlassWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.defaultWindowSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.minSize = Metrics.minWindowSize
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("VoiceChatConversationWindow")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let root = ConversationView(model: model, title: title) { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Metrics.windowCornerRadius
        glass.contentView = host
        window.contentView = glass

        observeTheme()
    }

    /// The header's theme buttons drive the window's appearance; `Default`
    /// hands it back to the system.
    private func observeTheme() {
        withObservationTracking {
            _ = GlassSettings.shared.theme
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTheme() }
        }
        window?.appearance = GlassSettings.shared.theme.appearance
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // An accessory app gets no activation for free, and a conversation
        // window nobody can see defeats the entire point of the tool call.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close without reporting it as a person-initiated end (R-VCP-15).
    public func closeQuietly() {
        suppressCloseCallback = true
        close()
    }

    public func windowWillClose(_ notification: Notification) {
        if !suppressCloseCallback { onWindowClose?() }
        onWindowDidClose?()
    }
}
