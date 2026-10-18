#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = ShortcutSettings()
    private let windowSystem = MacWindowSystem()
    private var shortcut: GlobalShortcut?
    private var panel: OverlayPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installShortcut()
        NotificationCenter.default.addObserver(forName: .shortcutDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installShortcut() }
        }
    }

    private func installShortcut() {
        shortcut = nil
        shortcut = GlobalShortcut(keyCode: settings.keyCode, modifiers: settings.modifiers) { [weak self] in
            self?.showOverlay()
        }
    }

    func showOverlay() {
        if panel == nil { panel = OverlayPanelController(windowSystem: windowSystem) }
        panel?.present()
    }
}
#endif
