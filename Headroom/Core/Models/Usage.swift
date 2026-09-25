import Foundation

enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

enum WindowKind: String, Codable, Sendable {
    case session, daily, weekly, monthly, other

    /// Clasifica una ventana por su duración; los planes cambian la duración (p. ej. Codex Free = 30 días).
    init(seconds: Int) {
        switch seconds {
        case ..<(12 * 3600): self = .session
        case ..<(2 * 86400): self = .daily
        case ..<(10 * 86400): self = .weekly
        default: self = .monthly
        }
    }

    static func label(seconds: Int) -> String {
        switch WindowKind(seconds: seconds) {
        case .session: "Sesión (\(max(1, seconds / 3600))h)"
        case .daily: "Diario"
        case .weekly: "Semanal"
        case .monthly: "Mensual"
        case .other: "Límite"
        }
    }
}

struct LimitWindow: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: WindowKind
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct DetailRow: Codable, Hashable, Sendable {
    let label: String
    let value: String
}

struct UsageSnapshot: Codable, Sendable {
    let provider: ProviderID
    let planName: String?
    let windows: [LimitWindow]
    let details: [DetailRow]
    let fetchedAt: Date

    var maxUsedPercent: Double? { windows.map(\.usedPercent).max() }
}

enum Severity: Sendable {
    case normal, warning, critical

    init(percent: Double) {
        switch percent {
        case 90...: self = .critical
        case 75...: self = .warning
        default: self = .normal
        }
    }
}
