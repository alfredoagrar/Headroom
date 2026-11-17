import SwiftUI

@main
struct HeadroomApp: App {
    @State private var store: UsageStore
    /// App-owned so parsed session totals survive closing the window.
    @State private var agents = AgentMonitor()

    init() {
        let store = UsageStore.live()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Agent activity", id: AgentActivityWindow.windowID) {
            AgentActivityWindow().environment(agents)
        }
        .defaultSize(width: 980, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
