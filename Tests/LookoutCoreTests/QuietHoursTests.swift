import Foundation
import Testing
@testable import LookoutCore

struct QuietHoursTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: hour, minute: minute))!
    }

    @Test func overnight() {
        let quiet = QuietHours(start: 22 * 60, end: 8 * 60)
        #expect(quiet.contains(at(23), calendar: calendar))
        #expect(quiet.contains(at(0), calendar: calendar))
        #expect(quiet.contains(at(7, 59), calendar: calendar))
        #expect(!quiet.contains(at(8), calendar: calendar))
        #expect(!quiet.contains(at(21, 59), calendar: calendar))
        #expect(quiet.contains(at(22), calendar: calendar))
    }

    @Test func sameDay() {
        let lunch = QuietHours(start: 12 * 60, end: 13 * 60 + 30)
        #expect(lunch.contains(at(12, 45), calendar: calendar))
        #expect(!lunch.contains(at(13, 30), calendar: calendar))
        #expect(!lunch.contains(at(11), calendar: calendar))
    }

    @Test func emptyWindow() {
        #expect(!QuietHours(start: 9 * 60, end: 9 * 60).contains(at(9), calendar: calendar))
    }
}
