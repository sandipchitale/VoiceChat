import AppKit
import SwiftUI

// Spec §6.7 — the metric and typography scale. One place, so "not cramped" is
// a property of the layout rather than a habit.

public enum Metrics {
    public static let outerPadding: CGFloat = 20
    public static let paneGap: CGFloat = 16
    public static let cardRadius: CGFloat = 12
    public static let windowCornerRadius: CGFloat = 24
    public static let headerHeight: CGFloat = 52
    public static let editorInset: CGFloat = 16
    public static let footerHeight: CGFloat = 52
    public static let bottomBarHeight: CGFloat = 56
    public static let controlHeight: CGFloat = 28
    /// The accent strip above the panes: the terminal banner, the history
    /// peek bar and the debate bar all stand this tall.
    public static let accentBarHeight: CGFloat = 36
    public static let historyCollapsedHeight: CGFloat = 28
    public static let historyExpandedHeight: CGFloat = 160

    public static let minPaneWidth: CGFloat = 420
    /// A stacked pane's floor: its header, a few lines of text and its footer.
    public static let minPaneHeight: CGFloat = 180
    public static let defaultWindowSize = CGSize(width: 1360, height: 860)
    public static let minWindowSize = CGSize(width: 1040, height: 680)

    public static let bodyPointSize: CGFloat = 15
    nonisolated(unsafe) public static let bodyFont = NSFont.systemFont(ofSize: bodyPointSize)
    nonisolated(unsafe) public static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    public static let paneHeaderFont = Font.system(size: 13, weight: .semibold)
    public static let captionFont = Font.system(size: 11)
}
