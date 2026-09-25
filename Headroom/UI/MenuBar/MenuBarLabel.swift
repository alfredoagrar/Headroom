import SwiftUI

struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        Image(systemName: Self.symbol(for: store.mostCriticalPercent))
            .accessibilityLabel("Headroom")
    }

    /// La aguja del ícono sigue al límite más crítico.
    static func symbol(for percent: Double?) -> String {
        guard let percent else { return "gauge.with.dots.needle.0percent" }
        return switch percent {
        case ..<20: "gauge.with.dots.needle.0percent"
        case ..<42: "gauge.with.dots.needle.33percent"
        case ..<58: "gauge.with.dots.needle.50percent"
        case ..<84: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}
