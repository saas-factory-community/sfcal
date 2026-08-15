import Foundation

enum GDate {
    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let rfc3339Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// All-day de Google: "yyyy-MM-dd" flotante — se interpreta en tz LOCAL.
    static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func parse(_ s: String) -> Date? {
        rfc3339.date(from: s) ?? rfc3339Frac.date(from: s) ?? dayOnly.date(from: s)
    }
    static func format(_ d: Date) -> String { rfc3339.string(from: d) }
    static func formatDay(_ d: Date) -> String { dayOnly.string(from: d) }
}

/// Calendario operativo de la app: semana empieza en LUNES, labels en español.
enum DateKit {
    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "es_MX")
        return c
    }()

    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

    static func startOfWeek(_ d: Date) -> Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return cal.date(from: comps) ?? startOfDay(d)
    }

    static func weekDays(_ anchor: Date) -> [Date] {
        let start = startOfWeek(anchor)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? startOfDay(d)
    }

    /// 42 celdas (6 semanas) empezando el lunes de la semana del dia 1.
    static func monthGrid(_ anchor: Date) -> [Date] {
        let first = startOfMonth(anchor)
        let gridStart = startOfWeek(first)
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    static func isSameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }
    static func isToday(_ d: Date) -> Bool { cal.isDateInToday(d) }

    static func minutesIntoDay(_ d: Date) -> Double {
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
    }

    static func addDays(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
    static func addWeeks(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .weekOfYear, value: n, to: d) ?? d }
    static func addMonths(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .month, value: n, to: d) ?? d }

    private static func fmt(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.calendar = cal
        f.dateFormat = format
        return f
    }
    static let hourLabel = fmt("HH")
    static let dayNum = fmt("d")
    static let weekdayShort = fmt("EEE")
    static let monthYear = fmt("MMMM yyyy")
    static let monthName = fmt("MMMM")
    static let dayMonth = fmt("d MMM")
    static let timeShort = fmt("HH:mm")
    static let fullDay = fmt("EEEE d 'de' MMMM")
    static let agendaDay = fmt("EEEE · d MMM")

    static func cap(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
