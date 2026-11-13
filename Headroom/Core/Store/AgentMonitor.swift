import Foundation
import Observation

/// Drives the agent activity window. Runs only between `start()` and `stop()`, so a closed
/// window costs nothing; parsed totals stay in the collector so reopening is instant.
@MainActor @Observable
final class AgentMonitor {
    private(set) var rows: [AgentRow] = []
    private(set) var summary = AgentSummary()
    private(set) var lastUpdated: Date?
    private(set) var isRunning = false

    @ObservationIgnored private let collector: any AgentCollecting
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let fileRefreshEvery: Int
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Processes every `interval`; session files every `fileRefreshEvery` ticks (6 s by default).
    init(collector: any AgentCollecting = AgentCollector(), interval: Duration = .seconds(2), fileRefreshEvery: Int = 3) {
        self.collector = collector
        self.interval = interval
        self.fileRefreshEvery = max(1, fileRefreshEvery)
    }

    func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            var tick = 0
            while let self, !Task.isCancelled {
                // First tick: show processes right away, then fill in tokens.
                if tick == 0 {
                    let quick = await self.collector.collect(refreshFiles: false)
                    guard !Task.isCancelled else { return }
                    self.apply(quick)
                }
                let snapshot = await self.collector.collect(refreshFiles: tick % self.fileRefreshEvery == 0)
                guard !Task.isCancelled else { return }
                self.apply(snapshot)
                tick += 1
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    private func apply(_ snapshot: AgentSnapshot) {
        rows = snapshot.rows
        summary = snapshot.summary
        lastUpdated = snapshot.collectedAt
    }
}
