import Foundation
import XCTest
@testable import AssistantCore

final class ReminderScheduleRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAdvanceAlarmIsOnlyAddedForFutureCalendarDayWhenEnabled() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 22))!
        let tomorrow = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 1))!
        XCTAssertEqual(ReminderScheduleRules.alarmDates(dueAt: tomorrow, now: now, advanceEnabled: true, calendar: calendar), [tomorrow, tomorrow.addingTimeInterval(-3600)])
        XCTAssertEqual(ReminderScheduleRules.alarmDates(dueAt: tomorrow, now: now, advanceEnabled: false, calendar: calendar), [tomorrow])
        let soon = now.addingTimeInterval(1800)
        XCTAssertEqual(ReminderScheduleRules.alarmDates(dueAt: soon, now: now, advanceEnabled: true, calendar: calendar), [soon])
        let sameDay = now.addingTimeInterval(5400)
        XCTAssertEqual(ReminderScheduleRules.alarmDates(dueAt: sameDay, now: now, advanceEnabled: true, calendar: calendar), [sameDay])
    }

    func testMoscowTimeResolvesToTheSameAbsoluteInstantAsUTC() throws {
        let local = try ReminderScheduleRules.date(fromISO8601: "2027-01-02T20:00:00+03:00", now: now)
        let utc = try ReminderScheduleRules.date(fromISO8601: "2027-01-02T17:00:00Z", now: now)
        XCTAssertEqual(local, utc)
        XCTAssertEqual(try ReminderScheduleRules.date(fromISO8601: "2027-01-02T20:00+03:00", now: now), utc)
    }

    func testFloatingLocalTimeAndDateOnlyCannotBeSilentlyScheduledInAnotherZone() {
        for value in ["2027-01-02T20:00:00", "2027-01-02", "20:00", "tomorrow at eight"] {
            XCTAssertThrowsError(try ReminderScheduleRules.date(fromISO8601: value, now: now)) {
                XCTAssertEqual($0 as? ReminderScheduleError, .timeZoneRequired)
            }
        }
    }

    func testImpossibleDatesAreRejectedInsteadOfRolledIntoTheNextMonth() throws {
        for value in ["2027-02-29T20:00:00+03:00", "2028-02-30T20:00:00+03:00", "2027-13-01T20:00:00Z", "2027-01-02T24:00:00Z", "2027-01-02T20:60:00Z"] {
            XCTAssertThrowsError(try ReminderScheduleRules.date(fromISO8601: value, now: now))
        }
        XCTAssertNoThrow(try ReminderScheduleRules.date(fromISO8601: "2028-02-29T20:00:00+03:00", now: now))
    }

    func testPastAndNonFiniteDatesCannotBeConfirmed() {
        for date in [now, now.addingTimeInterval(-1), Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            XCTAssertThrowsError(try ReminderScheduleRules.validate(title: "Магазин", dueAt: date, now: now))
        }
        XCTAssertThrowsError(try ReminderScheduleRules.date(fromISO8601: "2020-01-01T00:00:00Z", now: now)) {
            XCTAssertEqual($0 as? ReminderScheduleError, .dateNotInFuture)
        }
    }

    func testTitleIsReadableAndWholeSecondTimeMatchesPersistedTime() throws {
        let date = now.addingTimeInterval(100.75)
        let result = try ReminderScheduleRules.validate(title: "  Сходить\nв\tмагазин  ", dueAt: date, now: now)
        XCTAssertEqual(result.title, "Сходить в магазин")
        XCTAssertEqual(result.dueAt.timeIntervalSince1970, floor(date.timeIntervalSince1970))
        let components = ReminderScheduleRules.calendarComponents(for: result.dueAt)
        XCTAssertEqual(try XCTUnwrap(components.calendar).date(from: components), result.dueAt)
    }

    func testEmptyOrOversizedTitleAndEmbeddedControlCharactersAreRejected() {
        for title in [" \n\t", String(repeating: "я", count: 301), "Магазин\u{0000}потом"] {
            XCTAssertThrowsError(try ReminderScheduleRules.validate(title: title, dueAt: now.addingTimeInterval(100), now: now))
        }
    }

    func testExplicitOffsetsDistinguishTheTwoRepeatedDSTWallTimes() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let summer = try ReminderScheduleRules.date(fromISO8601: "2026-10-25T02:30:00+02:00", now: reference)
        let winter = try ReminderScheduleRules.date(fromISO8601: "2026-10-25T02:30:00+01:00", now: reference)
        XCTAssertEqual(winter.timeIntervalSince(summer), 3600)
        for date in [summer, winter] {
            let components = ReminderScheduleRules.calendarComponents(for: date)
            XCTAssertEqual(components.timeZone?.secondsFromGMT(for: date), 0)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            XCTAssertEqual(calendar.date(from: components), date)
        }
    }

    func testFractionalSecondsResolveToWholeSecondNotificationPrecision() throws {
        let fractional = try ReminderScheduleRules.date(fromISO8601: "2027-01-02T20:00:00.123456+03:00", now: now)
        let whole = try ReminderScheduleRules.date(fromISO8601: "2027-01-02T20:00:00+03:00", now: now)
        XCTAssertEqual(fractional, whole)
    }

    func testInvalidTimezoneOffsetsAndMalformedISOAreRejected() {
        for value in ["2027-01-02T20:00:00+15:00", "2027-01-02T20:00:00+14:01", "2027-01-02T20:00:00+03:60", "2027/01/02T20:00:00Z", "2027-01-02T20:00:00Z ignored"] {
            XCTAssertThrowsError(try ReminderScheduleRules.date(fromISO8601: value, now: now))
        }
    }
}
