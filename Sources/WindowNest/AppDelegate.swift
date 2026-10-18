#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = ShortcutSettings()
    private let windowSystem = MacWindowSystem()
    private var shortcut: GlobalShortcut?
    private var panel: OverlayPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installShortcut()
        NotificationCenter.default.addObserver(forName: .shortcutDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installShortcut() }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "WindowNest")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show WindowNest", action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WindowNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func installShortcut() {
        shortcut = GlobalShortcut(keyCode: settings.keyCode, modifiers: settings.modifiers) { [weak self] in
            self?.showOverlay()
        }
    }

    @objc private func showOverlay() {
        if panel == nil { panel = OverlayPanelController(windowSystem: windowSystem) }
        panel?.present()
    }

    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
