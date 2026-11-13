import Foundation

/// English formatters for the agent activity window.
enum AgentFormat {
    static let costDisclaimer =
        "What these tokens would cost at API list prices (as of \(ModelPricing.asOf)). Subscriptions aren't billed per token."

    /// "950", "2.1K", "812K", "3.4M", "24.1M", "1.2B".
    static func tokens(_ count: Int) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let value = Double(count)
        // 0.9995 so 999,999 rounds up to "1M" instead of "1000K".
        for (size, suffix) in units where value >= size * 0.9995 {
            let scaled = value / size
            let text = scaled < 100 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        return "\(count)"
    }

    /// "$4.62", "<$0.01", "$4.12+" (partly unpriced), "—" (fully unpriced), "$1,235".
    static func cost(_ cost: CostEstimate) -> String {
        if cost.usd == 0, cost.hasUnpricedUsage { return "—" }
        let suffix = cost.hasUnpricedUsage ? "+" : ""
        if cost.usd > 0, cost.usd < 0.01 { return "<$0.01" + suffix }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(cost.usd >= 1000 ? 0 : 2))
        return cost.usd.formatted(style) + suffix
    }

    /// "19.7%", "219%".
    static func percent(_ value: Double) -> String {
        value < 100 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    /// Binary units, like Activity Monitor: "900 KB", "310 MB", "1.6 GB".
    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes), mib = 1_048_576.0, gib = 1_073_741_824.0
        if value >= gib { return String(format: "%.1f GB", value / gib) }
        if value >= mib { return String(format: "%.0f MB", value / mib) }
        return String(format: "%.0f KB", value / 1024)
    }

    /// "<1m", "2m", "2h 22m", "4d 2h".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return "—" }
        let s = Int(seconds)
        guard s >= 60 else { return "<1m" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "5s ago", "12m ago", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite, abs(elapsed) < 1e12 else { return "—" }
        let s = max(0, Int(elapsed))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "today, 20:57", "yesterday, 09:05", "Mon Nov 9, 20:57" (year appended when it differs).
    static func dayTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday, \(time)"
        }
        var day = "\(weekdays[(c.weekday ?? 1) - 1]) \(months[(c.month ?? 1) - 1]) \(c.day ?? 0)"
        if c.year != calendar.component(.year, from: now) { day += " \(c.year ?? 0)" }
        return "\(day), \(time)"
    }

    /// "claude-opus-5-5" → "Opus 5.5"; other ids are returned as-is.
    static func modelName(_ id: String) -> String {
        let normalized = ModelID.normalizedClaude(id)
        guard normalized.hasPrefix("claude-") else { return id }
        let parts = normalized.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first,
              ["opus", "sonnet", "haiku", "fable", "mythos"].contains(family),
              parts.count > 1, parts.dropFirst().allSatisfy({ part in part.allSatisfy { $0.isNumber } }) else { return id }
        return family.capitalized + " " + parts.dropFirst().joined(separator: ".")
    }
}
