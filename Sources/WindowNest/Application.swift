#if os(macOS)
import AppKit
import SwiftUI

@main
struct WindowNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("WindowNest", systemImage: "rectangle.stack") {
            Button("Show WindowNest") { appDelegate.showOverlay() }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Divider()
            Button("Quit WindowNest") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings { SettingsView(settings: appDelegate.settings) }
    }
}
#else
import Foundation

@main
enum WindowNestApp {
    static func main() {
        print("WindowNest requires macOS 14 or later.")
    }
}
#endif
