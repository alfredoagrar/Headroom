import SwiftUI

extension ProviderID {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension Severity {
    func color(base: Color) -> Color {
        switch self {
        case .normal: base
        case .warning: .yellow
        case .critical: .red
        }
    }
}
