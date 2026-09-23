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

    public init(model: ConversationModel, title: String, autosaveName: String? = nil) {
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
        // One name per window: debate seats each remember their own place
        // instead of overwriting a single shared frame.
        window.setFrameAutosaveName(NSWindow.FrameAutosaveName(
            autosaveName ?? "VoiceChatConversationWindow"))
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

        // A borderless window's frame is square, so the system draws its
        // shadow and active-window outline square too — visible as a sharp
        // corner poking out past the rounded glass. Rounding the frame's own
        // layer makes both follow the glass.
        if let frame = glass.superview {
            frame.wantsLayer = true
            frame.layer?.cornerRadius = Metrics.windowCornerRadius
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
        }

        observeSettings()
    }

    /// The header's theme buttons drive the window's appearance (`Default`
    /// hands it back to the system); its pin drives whether the window floats.
    private func observeSettings() {
        withObservationTracking {
            _ = GlassSettings.shared.theme
            _ = GlassSettings.shared.alwaysOnTop
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        window?.appearance = GlassSettings.shared.theme.appearance
        window?.level = GlassSettings.shared.alwaysOnTop ? .floating : .normal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func present() { present(frame: nil, activating: true) }

    /// `frame` places the window deliberately (a debate seat) instead of
    /// centring it; `activating` is false for the second window of a pair, so
    /// taking a seat does not yank focus away from the first.
    public func present(frame: NSRect?, activating: Bool) {
        guard let window else { return }
        if let frame {
            window.setFrame(frame, display: true)
        } else if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        // An accessory app gets no activation for free, and a conversation
        // window nobody can see defeats the entire point of the tool call.
        if activating { NSApp.activate(ignoringOtherApps: true) }
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
