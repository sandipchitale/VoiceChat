import AppKit
import SwiftUI

// Spec §6.1 — the two panes, side by side or stacked, with a draggable
// divider between them. The person owns the proportion; the divider only
// keeps each pane above its minimum.

struct PaneSplitView<First: View, Second: View>: View {
    let axis: Axis
    /// The first pane's share of the space, 0…1.
    @Binding var fraction: Double
    let minFirst: CGFloat
    let minSecond: CGFloat
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    private let gap = Metrics.paneGap

    var body: some View {
        GeometryReader { proxy in
            let total = max(0, (axis == .horizontal ? proxy.size.width : proxy.size.height) - gap)
            let firstLength = Self.firstLength(fraction: fraction, total: total,
                                               minFirst: minFirst, minSecond: minSecond)
            // One `AnyLayout` for both arrangements, so toggling the layout
            // keeps the panes' identity — and their text views, focus and
            // selection — rather than rebuilding them.
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0))
                                             : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: axis == .horizontal ? firstLength : nil,
                           height: axis == .vertical ? firstLength : nil)
                SplitHandle(axis: axis, fraction: $fraction, firstLength: firstLength) { length in
                    guard total > 0 else { return }
                    let clamped = Self.firstLength(fraction: length / total, total: total,
                                                   minFirst: minFirst, minSecond: minSecond)
                    fraction = clamped / total
                }
                .frame(width: axis == .horizontal ? gap : nil,
                       height: axis == .vertical ? gap : nil)
                second()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The first pane's length for `fraction`, kept clear of both minimums.
    /// When the space cannot fit both, it is shared in proportion to them
    /// rather than letting one pane collapse.
    static func firstLength(fraction: Double, total: CGFloat,
                            minFirst: CGFloat, minSecond: CGFloat) -> CGFloat {
        guard total > minFirst + minSecond else {
            return total * minFirst / max(minFirst + minSecond, 1)
        }
        return min(max(total * fraction, minFirst), total - minSecond)
    }

    /// The divider: a grip that brightens on hover and while dragging.
    private struct SplitHandle: View {
        let axis: Axis
        @Binding var fraction: Double
        /// The first pane's length as currently laid out.
        let firstLength: CGFloat
        /// Asks for a new first-pane length; the split clamps it.
        let onDrag: (CGFloat) -> Void
        @State private var isHovering = false
        @State private var isDragging = false
        @State private var startLength: CGFloat = 0

        var body: some View {
            let lit = isHovering || isDragging
            Capsule()
                .fill(Glass.accent.opacity(lit ? 0.85 : 0.3))
                .frame(width: axis == .horizontal ? 3 : 44,
                       height: axis == .horizontal ? 44 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .overlay {
                    DividerDragSurface(
                        axis: axis,
                        onBegan: { startLength = firstLength; isDragging = true },
                        onChanged: { onDrag(startLength + $0) },
                        onEnded: { isDragging = false },
                        onDoubleClick: { fraction = 0.5 },
                        onHover: { isHovering = $0 })
                }
                .accessibilityElement()
                .accessibilityLabel("Pane divider")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: fraction = min(1, fraction + 0.05)
                    case .decrement: fraction = max(0, fraction - 0.05)
                    @unknown default: break
                    }
                }
        }
    }
}

/// The divider's mouse handling, in AppKit. The window is movable by its
/// background, and AppKit decides that on mouse-down — before any SwiftUI
/// gesture sees the event — so a SwiftUI drag here moves the window instead.
/// A view that refuses `mouseDownCanMoveWindow` keeps the drag for itself.
private struct DividerDragSurface: NSViewRepresentable {
    let axis: Axis
    let onBegan: () -> Void
    /// Distance dragged along the axis since mouse-down, in points, growing
    /// rightward or downward — the direction the first pane grows.
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.axis = axis
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.toolTip = "Drag to resize the panes. Double-click to split them evenly."
    }

    final class SurfaceView: NSView {
        var axis: Axis = .horizontal {
            didSet { if axis != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        private var dragStart: NSPoint?
        private var trackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                dragStart = nil
                onDoubleClick()
                return
            }
            dragStart = event.locationInWindow
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            let point = event.locationInWindow
            // Window coordinates grow upward; the panes stack downward.
            onChanged(axis == .horizontal ? point.x - dragStart.x : dragStart.y - point.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            onEnded()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}
