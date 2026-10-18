/// Arrow keys over project cards laid out `columns` to a row: up and down through a card's agents
/// and on to the card above or below, left and right to the card beside it. Empty (collapsed) cards are skipped.
public enum GridNavigation {
    public enum Direction: Sendable { case up, down, left, right }

    /// The agent to select next. `cards` holds each card's agent ids in order; with nothing selected, the first agent.
    public static func next<ID: Equatable>(after selected: ID?, in cards: [[ID]], columns: Int = 2,
                                           _ direction: Direction) -> ID? {
        guard let selected, let card = cards.firstIndex(where: { $0.contains(selected) }),
              let row = cards[card].firstIndex(of: selected) else {
            return cards.lazy.compactMap(\.first).first
        }
        let down = direction == .down ? 1 : direction == .up ? -1 : 0
        if down != 0, cards[card].indices.contains(row + down) { return cards[card][row + down] }
        let step = direction == .left ? -1 : direction == .right ? 1 : columns * down
        var next = card + step
        while cards.indices.contains(next), down != 0 || next / columns == card / columns {
            let ids = cards[next]
            if !ids.isEmpty { return down > 0 ? ids.first : down < 0 ? ids.last : ids[min(row, ids.count - 1)] }
            next += step
        }
        return selected
    }
}
