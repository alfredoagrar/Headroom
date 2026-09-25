import Foundation
import Observation

@MainActor @Observable
final class UsageStore {
    struct Entry: Sendable {
        var snapshot: UsageSnapshot?
        var error: ProviderError?
        var isLoading = false
    }

    let providerIDs: [ProviderID]
    private(set) var entries: [ProviderID: Entry] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var refreshInterval: Duration = .seconds(120)

    @ObservationIgnored private let providers: [any UsageProvider]
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(providers: [any UsageProvider]) {
        self.providers = providers
        providerIDs = providers.map(\.id)
        for id in providerIDs { entries[id] = Entry() }
        for snapshot in SnapshotCache.load() where entries[snapshot.provider] != nil {
            entries[snapshot.provider]?.snapshot = snapshot
        }
        lastRefresh = entries.values.compactMap(\.snapshot?.fetchedAt).max()
    }

    static func live() -> UsageStore {
        UsageStore(providers: [ClaudeProvider(), CodexProvider()])
    }

    var mostCriticalPercent: Double? {
        entries.values.compactMap(\.snapshot?.maxUsedPercent).max()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
    }

    /// Al abrir el popover: refresca solo si el dato tiene más de 60 s.
    func refreshIfStale() {
        guard let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 else {
            Task { await refresh() }
            return
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for id in providerIDs { entries[id]?.isLoading = true }

        let results = await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, ProviderError>).self) { group in
            for provider in providers {
                group.addTask {
                    do throws(ProviderError) { return (provider.id, .success(try await provider.fetchUsage())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            var results: [(ProviderID, Result<UsageSnapshot, ProviderError>)] = []
            for await result in group { results.append(result) }
            return results
        }

        for (id, result) in results {
            switch result {
            case .success(let snapshot):
                entries[id] = Entry(snapshot: snapshot)
            case .failure(let error):
                // Conserva el último dato bueno para mostrarlo como desactualizado.
                entries[id]?.error = error
                entries[id]?.isLoading = false
            }
        }
        lastRefresh = .now
        SnapshotCache.save(entries.values.compactMap(\.snapshot))
    }
}

enum SnapshotCache {
    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "Headroom/snapshots.json")
    }

    static func load() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UsageSnapshot].self, from: data)) ?? []
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshots).write(to: url, options: .atomic)
    }
}
