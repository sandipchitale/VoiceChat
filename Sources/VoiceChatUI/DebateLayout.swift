import AppKit
import Foundation

// Where a debate's windows go. Two conversation windows at their minimum size
// need 2 × 1040 pt plus a gap, which a laptop display does not have — so below
// that they stack instead of overlapping, which keeps both panes usable.

public enum DebateLayout {
    public static let gap: CGFloat = 12

    /// One frame per seat, in seat order. Side by side where the screen is
    /// wide enough, otherwise stacked top to bottom.
    public static func frames(seatCount: Int, in visible: NSRect) -> [NSRect] {
        guard seatCount > 0 else { return [] }
        let count = CGFloat(seatCount)
        let totalGap = gap * (count - 1)
        let sideBySideWidth = (visible.width - totalGap) / count

        if sideBySideWidth >= Metrics.minWindowSize.width {
            let height = min(visible.height, Metrics.defaultWindowSize.height)
            let y = visible.maxY - height
            return (0..<seatCount).map { index in
                NSRect(x: visible.minX + (sideBySideWidth + gap) * CGFloat(index),
                       y: y, width: sideBySideWidth, height: height)
            }
        }

        // Stacked: full width each, so neither window drops below the width
        // its two panes need.
        let height = (visible.height - totalGap) / count
        return (0..<seatCount).map { index in
            NSRect(x: visible.minX,
                   y: visible.maxY - height - (height + gap) * CGFloat(index),
                   width: visible.width, height: height)
        }
    }

    /// The frame for one seat, or `nil` when there is no screen to place it on.
    public static func frame(seatIndex: Int, seatCount: Int,
                             screen: NSScreen? = NSScreen.main) -> NSRect? {
        guard let visible = screen?.visibleFrame, seatIndex < seatCount else { return nil }
        let all = frames(seatCount: seatCount, in: visible)
        return seatIndex < all.count ? all[seatIndex] : nil
    }
}
