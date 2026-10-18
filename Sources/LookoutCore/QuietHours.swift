import Foundation

/// A daily window without notifications, in minutes after midnight. It may run past midnight (22:00–08:00).
public struct QuietHours: Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Start and end at the same time means no quiet hours.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start <= end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
}
