import Foundation

public struct ReminderSchedule: Equatable, Sendable {
    public let title: String
    public let dueAt: Date
}

public enum ReminderScheduleError: Error, LocalizedError, Equatable, Sendable {
    case emptyTitle
    case titleTooLong
    case invalidDate
    case timeZoneRequired
    case dateNotInFuture

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: return "Укажите, о чём напомнить."
        case .titleTooLong: return "Сократите текст напоминания до 300 символов."
        case .invalidDate: return "Не удалось определить дату напоминания. Уточните дату и время."
        case .timeZoneRequired: return "Для напоминания нужны дата и время с часовым поясом."
        case .dateNotInFuture: return "Время напоминания должно быть в будущем."
        }
    }
}

/// The model resolves natural language using the user's local clock. This
/// boundary accepts an absolute ISO 8601 instant, never a floating wall time.
public enum ReminderScheduleRules {
    public static let maximumTitleLength = 300

    public static func validate(title: String, dueAt: Date, now: Date = Date()) throws -> ReminderSchedule {
        let title = title.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !title.isEmpty else { throw ReminderScheduleError.emptyTitle }
        guard title.count <= maximumTitleLength else { throw ReminderScheduleError.titleTooLong }
        guard title.rangeOfCharacter(from: .controlCharacters) == nil,
              dueAt.timeIntervalSinceReferenceDate.isFinite else { throw ReminderScheduleError.invalidDate }
        // UNCalendarNotificationTrigger uses whole seconds. Round once here so
        // the persisted due date is exactly the instant scheduled with iOS.
        let date = Date(timeIntervalSince1970: floor(dueAt.timeIntervalSince1970))
        guard date.timeIntervalSince(now) >= 1 else { throw ReminderScheduleError.dateNotInFuture }
        let year = utcCalendar.component(.year, from: date)
        guard (1...9999).contains(year) else { throw ReminderScheduleError.invalidDate }
        return ReminderSchedule(title: title, dueAt: date)
    }

    public static func date(fromISO8601 value: String, now: Date = Date()) throws -> Date {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 64 else { throw ReminderScheduleError.invalidDate }
        guard value.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw ReminderScheduleError.timeZoneRequired
        }
        let expression = try NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { throw ReminderScheduleError.invalidDate }
        func integer(_ group: Int) -> Int? {
            guard let range = Range(match.range(at: group), in: value) else { return nil }
            return Int(value[range])
        }
        guard let year = integer(1), let month = integer(2), let day = integer(3),
              let hour = integer(4), let minute = integer(5), let second = integer(6),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              let zoneRange = Range(match.range(at: 8), in: value) else { throw ReminderScheduleError.invalidDate }
        let zone = String(value[zoneRange])
        let offset: Int
        if zone == "Z" { offset = 0 }
        else {
            let pieces = zone.dropFirst().split(separator: ":")
            guard pieces.count == 2, let hours = Int(pieces[0]), let minutes = Int(pieces[1]),
                  (0...14).contains(hours), (0...59).contains(minutes),
                  hours < 14 || minutes == 0 else { throw ReminderScheduleError.invalidDate }
            offset = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { throw ReminderScheduleError.invalidDate }
        var calendar = utcCalendar
        calendar.timeZone = timeZone
        let components = DateComponents(timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
            throw ReminderScheduleError.invalidDate
        }
        // Calendar sometimes normalizes an impossible date; compare its fields
        // rather than scheduling a different day from the one requested.
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day,
              resolved.hour == hour, resolved.minute == minute, resolved.second == second else {
            throw ReminderScheduleError.invalidDate
        }
        guard date.timeIntervalSince(now) >= 1 else { throw ReminderScheduleError.dateNotInFuture }
        return date
    }

    /// Full date components in UTC preserve the absolute instant across DST and
    /// changes to the device's current time zone. These are one-off reminders.
    public static func calendarComponents(for date: Date) -> DateComponents {
        var components = utcCalendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = utcCalendar
        components.timeZone = utcCalendar.timeZone
        return components
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
