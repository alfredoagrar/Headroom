import SwiftUI

@main
struct HeadroomApp: App {
    @State private var store: UsageStore

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
    }
}
