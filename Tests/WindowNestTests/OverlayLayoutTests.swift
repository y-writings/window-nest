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

    @Test func screenChangeReplacesTheStaleViewportBeforeLayout() {
        let controller = OverlayPanelController(windowSystem: MacWindowSystem(), settings: ShortcutSettings())
        let apps = (0..<24).map { index in
            ApplicationItem(id: Int32(index), name: "App \(index)", windows: [
                WindowItem(id: WindowID(processIdentifier: Int32(index), windowNumber: 1), title: "Window"),
            ])
        }
        controller.model.state = BrowserState(applications: apps)
        controller.model.viewportMaxWidth = 5000
        controller.model.viewportMaxHeight = 4000

        controller.noteScreenChange()

        guard let visible = (controller.panel.screen ?? NSScreen.main)?.visibleFrame else {
            #expect(controller.model.viewportMaxWidth == 5000)
            #expect(controller.model.viewportMaxHeight == 4000)
            return
        }
        let expectedWidth = max(640.0, Double(visible.width) - 48)
        let expectedHeight = max(480.0, Double(visible.height) - 80)
        #expect(controller.model.viewportMaxWidth == expectedWidth)
        #expect(controller.model.viewportMaxHeight == expectedHeight)
        let layout = controller.model.switcherLayout
        #expect(layout.panelWidth <= expectedWidth + 0.1)
        #expect(layout.panelHeight <= expectedHeight + 0.1)
        #expect(!layout.iconRowScrollsHorizontally)
        #expect(layout.lastIconMaxX <= layout.contentWidth + 0.01)
    }
}
#endif
