import SwiftUI

@main
struct PRAgentApp: App {
    @StateObject private var store = PRReviewStore()

    var body: some Scene {
        MenuBarExtra {
            PRMenuView(store: store)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "eye.circle.fill")
                if store.pendingCount > 0 {
                    Text("\(store.pendingCount)")
                        .font(.caption2)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
