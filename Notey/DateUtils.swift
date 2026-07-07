import Foundation

// Calendar helpers — Monday-based weeks, Polish labels.
enum DateUtils {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "pl_PL")
        return c
    }()

    static let months = [
        "Styczeń", "Luty", "Marzec", "Kwiecień", "Maj", "Czerwiec",
        "Lipiec", "Sierpień", "Wrzesień", "Październik", "Listopad", "Grudzień",
    ]

    static let monthsGenitive = [
        "stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca",
        "lipca", "sierpnia", "września", "października", "listopada", "grudnia",
    ]

    static let weekdays = ["Pon", "Wt", "Śr", "Czw", "Pt", "Sob", "Nd"]

    static let weekdaysFull = [
        "Poniedziałek", "Wtorek", "Środa", "Czwartek", "Piątek", "Sobota", "Niedziela",
    ]

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dateKey(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static func date(fromKey key: String) -> Date {
        keyFormatter.date(from: key) ?? .now
    }

    /// Mon=0 … Sun=6
    static func weekdayIndex(_ date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func startOfWeek(_ date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -weekdayIndex(start), to: start) ?? start
    }

    static func addDays(_ date: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .day, value: n, to: date) ?? date
    }

    static func addMonths(_ date: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .month, value: n, to: date) ?? date
    }

    static func addYears(_ date: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .year, value: n, to: date) ?? date
    }

    static func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    static func year(_ date: Date) -> Int { calendar.component(.year, from: date) }
    static func month(_ date: Date) -> Int { calendar.component(.month, from: date) }
    static func day(_ date: Date) -> Int { calendar.component(.day, from: date) }

    static func firstOfMonth(_ date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? date
    }

    static func firstOfMonth(year: Int, month: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
    }

    /// Full weeks covering the month (Mon before the 1st … Sun after the last day).
    static func monthGrid(for date: Date) -> [Date] {
        let first = firstOfMonth(date)
        guard let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let last = addDays(first, range.count - 1)
        let start = startOfWeek(first)
        let end = addDays(startOfWeek(last), 6)
        var days: [Date] = []
        var d = start
        while d <= end {
            days.append(d)
            d = addDays(d, 1)
        }
        return days
    }

    static func weekDays(for date: Date) -> [Date] {
        let start = startOfWeek(date)
        return (0..<7).map { addDays(start, $0) }
    }

    static func dayTitle(_ date: Date) -> String {
        let m = calendar.component(.month, from: date) - 1
        return "\(weekdaysFull[weekdayIndex(date)]), \(day(date)) \(monthsGenitive[m]) \(year(date))"
    }

    static func monthTitle(_ date: Date) -> String {
        "\(months[calendar.component(.month, from: date) - 1]) \(year(date))"
    }

    static func weekTitle(_ date: Date) -> String {
        let start = startOfWeek(date)
        let end = addDays(start, 6)
        let sm = calendar.component(.month, from: start) - 1
        let em = calendar.component(.month, from: end) - 1
        if sm == em {
            return "\(day(start))–\(day(end)) \(monthsGenitive[em]) \(year(end))"
        }
        return "\(day(start)) \(monthsGenitive[sm]) – \(day(end)) \(monthsGenitive[em]) \(year(end))"
    }
}
