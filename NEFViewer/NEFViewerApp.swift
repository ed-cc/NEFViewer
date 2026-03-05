import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        appState.open(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            appState.open(URL(fileURLWithPath: first))
        }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main
struct NEFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environmentObject(appDelegate.appState)
            .onOpenURL { url in
                appDelegate.appState.open(url)
            }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    let needsWindow = NSApp.windows.filter({ $0.isVisible }).isEmpty
                    if needsWindow {
                        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
                    }
                    // Delay so the new window is on screen before we show the panel
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        if let window = NSApp.windows.first(where: { $0.isVisible }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                        appDelegate.appState.openFilePanel()
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
