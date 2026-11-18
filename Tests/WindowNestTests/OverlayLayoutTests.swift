#if os(macOS)
import AppKit
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct OverlayLayoutTests {
    @Test func panelShrinksIconsToTheAvailableWidthInsteadOfScrolling() {
        let controller = OverlayPanelController(windowSystem: MacWindowSystem(), settings: ShortcutSettings())
        let apps = (0..<24).map { index in
            ApplicationItem(id: Int32(index), name: "App \(index)", windows: [
                WindowItem(id: WindowID(processIdentifier: Int32(index), windowNumber: 1), title: "Window"),
            ])
        }
        controller.model.viewportMaxWidth = 900
        controller.model.viewportMaxHeight = 800
        controller.model.state = BrowserState(applications: apps)
        controller.resizePanelToLayout()

        let layout = controller.model.switcherLayout
        #expect(!layout.iconRowScrollsHorizontally)
        #expect(layout.panelWidth <= 900)
        #expect(layout.iconSize < SwitcherLayout.preferredIconSize)
        #expect(abs(layout.lastIconMaxX - layout.contentWidth) < 0.01)
        #expect(controller.panel.frame.width <= 960)
        #expect(controller.panel.frame.width + 1 >= CGFloat(layout.panelWidth))
    }
}
#endif
