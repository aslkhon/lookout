import Testing
@testable import LookoutCore

struct GridNavigationTests {
    // a b      cards 0 1
    // - d      cards 2 (collapsed) 3
    // e        card 4
    private let cards = [["a1", "a2", "a3"], ["b1"], [], ["d1", "d2"], ["e1"]]

    private func next(_ id: String?, _ direction: GridNavigation.Direction) -> String? {
        GridNavigation.next(after: id, in: cards, direction)
    }

    @Test func nothingSelectedPicksTheFirstAgent() {
        #expect(next(nil, .down) == "a1")
        #expect(next("gone", .left) == "a1")
        #expect(GridNavigation.next(after: nil, in: [[], ["x"]], .up) == "x")
        #expect(GridNavigation.next(after: nil, in: [[String]](), .up) == nil)
    }

    @Test func upAndDownWithinACardThenOnToTheNext() {
        #expect(next("a1", .down) == "a2")
        #expect(next("a3", .down) == "e1") // skips the collapsed card below
        #expect(next("e1", .up) == "a3") // the last agent of the card above
        #expect(next("b1", .down) == "d1")
        #expect(next("d1", .up) == "b1")
        #expect(next("a1", .up) == "a1") // top edge
        #expect(next("d2", .down) == "d2") // nothing below
    }

    @Test func leftAndRightStayInTheGridRow() {
        #expect(next("a3", .right) == "b1") // row clamped to the shorter card
        #expect(next("b1", .left) == "a1")
        #expect(next("b1", .right) == "b1") // right edge
        #expect(next("d2", .left) == "d2") // the card beside is collapsed
        #expect(next("e1", .left) == "e1") // doesn't wrap to the row above
    }
}
