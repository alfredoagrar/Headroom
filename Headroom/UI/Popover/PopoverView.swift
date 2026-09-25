import SwiftUI

struct PopoverView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(store.providerIDs, id: \.self) { id in
                        ProviderCard(provider: id, entry: store.entries[id] ?? .init())
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { store.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Headroom").font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
            }
            .buttonStyle(.glass)
            .disabled(store.isRefreshing)
            .help("Actualizar")

            Menu {
                Button("Salir de Headroom") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let lastRefresh = store.lastRefresh {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Actualizado \(lastRefresh, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
