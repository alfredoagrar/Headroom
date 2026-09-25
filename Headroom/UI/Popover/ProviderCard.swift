import SwiftUI

struct ProviderCard: View {
    let provider: ProviderID
    let entry: UsageStore.Entry
    @State private var expanded = false

    private var details: [DetailRow] { entry.snapshot?.details ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot = entry.snapshot {
                if snapshot.windows.isEmpty {
                    Text("Sin límites activos").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.windows) { window in
                    LimitRow(window: window, tint: provider.tint)
                }
            } else if entry.isLoading {
                LimitRow(window: .placeholder, tint: provider.tint).redacted(reason: .placeholder)
            }

            if let error = entry.error {
                Label {
                    Text(entry.snapshot == nil ? error.message : "Desactualizado · \(error.message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(entry.snapshot == nil ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                VStack(spacing: 4) {
                    ForEach(details, id: \.self) { row in
                        HStack {
                            Text(row.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(provider.tint.opacity(0.12)), in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture {
            guard !details.isEmpty else { return }
            withAnimation(.snappy) { expanded.toggle() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.symbol)
                .foregroundStyle(provider.tint)
                .frame(width: 16)
            Text(provider.displayName).font(.subheadline.weight(.semibold))
            if let plan = entry.snapshot?.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            Spacer()
            if entry.isLoading {
                ProgressView().controlSize(.mini)
            } else if !details.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.caption)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let resetsAt = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ResetFormatter.short(until: resetsAt, now: context.date))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                }
            }
            LimitBar(fraction: window.usedPercent / 100,
                     color: Severity(percent: window.usedPercent).color(base: tint))
            if let resetsAt = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Label("Se reinicia \(ResetFormatter.absolute(resetsAt, now: context.date))", systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .help(window.resetsAt.map { "Se reinicia \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }
}

struct LimitBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: clamped > 0 ? max(geo.size.width * clamped, 6) : 0)
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

private extension LimitWindow {
    static let placeholder = LimitWindow(id: "placeholder", kind: .session, label: "Sesión (5h)",
                                         usedPercent: 40, resetsAt: nil)
}
