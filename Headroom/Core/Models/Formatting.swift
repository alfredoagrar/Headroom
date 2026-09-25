import Foundation

enum ResetFormatter {
    /// Compact countdown: "4d 3h", "2h 14m", "38m".
    static func short(until date: Date, now: Date = .now) -> String {
        let s = Int(date.timeIntervalSince(now))
        guard s > 0 else { return "ahora" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    private static let weekdays = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"]
    private static let months = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

    /// Human-readable reset date: "hoy, 12:29", "mañana, 09:00", "jue 1 oct, 12:59" (year appended when it differs).
    static func absolute(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "hoy, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "mañana, \(time)"
        }
        var day = "\(weekdays[(c.weekday ?? 1) - 1]) \(c.day ?? 0) \(months[(c.month ?? 1) - 1])"
        if c.year != calendar.component(.year, from: now) { day += " \(c.year ?? 0)" }
        return "\(day), \(time)"
    }
}

enum ISODate {
    /// Accepts "2026-09-25T19:29:59.899633+00:00" (6 fractional digits) and variants without a fraction.
    static func parse(_ string: String?) -> Date? {
        guard var s = string else { return nil }
        if let dot = s.firstIndex(of: ".") {
            let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
            let fraction = s[s.index(after: dot)..<digitsEnd].prefix(3)
            s.replaceSubrange(dot..<digitsEnd, with: "." + fraction)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
