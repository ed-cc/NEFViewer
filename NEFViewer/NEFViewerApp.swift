import SwiftUI

@main
struct NEFViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Remove New Window shortcut — single-window app
            CommandGroup(replacing: .newItem) {}
        }
    }
}
