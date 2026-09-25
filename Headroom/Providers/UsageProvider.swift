import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws(ProviderError) -> UsageSnapshot
}
