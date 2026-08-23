import SwiftUI
import HarnessCore

// The separate Mac app for openwsigbot: a native SwiftUI shell over the
// ported harness core. This build drives the real claude CLI headlessly —
// one bot, one thread, streaming into a transcript. No Electron, no Node.

@main
struct OpenSigbotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = ChatSession()

    var body: some Scene {
        WindowGroup("openwsigbot") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
