import SwiftUI
import Testing
@testable import VoiceChatUI

@Suite("Pane split — the divider keeps both panes usable")
struct PaneSplitTests {
    private typealias Split = PaneSplitView<EmptyView, EmptyView>

    @Test("a fraction inside the limits is taken as given")
    func freeFraction() {
        #expect(Split.firstLength(fraction: 0.5, total: 1000, minFirst: 200, minSecond: 200) == 500)
        #expect(Split.firstLength(fraction: 0.3, total: 1000, minFirst: 200, minSecond: 200) == 300)
    }

    @Test("dragging past either end stops at that pane's minimum")
    func clampsToMinimums() {
        #expect(Split.firstLength(fraction: 0.05, total: 1000, minFirst: 200, minSecond: 300) == 200)
        #expect(Split.firstLength(fraction: 0.95, total: 1000, minFirst: 200, minSecond: 300) == 700)
    }

    @Test("too little room shares it in proportion to the minimums")
    func tooSmallSharesProportionally() {
        #expect(Split.firstLength(fraction: 0.9, total: 300, minFirst: 200, minSecond: 200) == 150)
        #expect(Split.firstLength(fraction: 0.5, total: 0, minFirst: 200, minSecond: 200) == 0)
    }
}
