#if os(macOS)
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct OverlayCardIdentityTests {
    @Test(arguments: ApplicationSearchMode.allCases)
    func selectionUsesVisibleCardIdentity(mode: ApplicationSearchMode) {
        let applications = [
            ApplicationItem(id: 1, name: "Safari", windows: [
                WindowItem(id: WindowID(processIdentifier: 1, windowNumber: 11), title: "First"),
                WindowItem(id: WindowID(processIdentifier: 1, windowNumber: 12), title: "Second"),
            ]),
            ApplicationItem(id: 2, name: "Zed", windows: []),
        ]
        let model = OverlayModel(system: MacWindowSystem())
        model.state = BrowserState(applications: applications, searchMode: mode)
        let view = OverlayView(model: model)

        model.state.updateSearchQuery("zed")
        #expect(view.selectedCardID == .application(2))

        model.state.updateSearchQuery("missing")
        #expect(view.selectedCardID == nil)

        model.state.updateSearchQuery("")
        #expect(view.selectedCardID == .application(1))
        #expect(model.state.handle(.showWindows) == .none)
        #expect(view.selectedCardID == .window(applications[0].windows[0].id))
        _ = model.state.handle(.moveRight)
        #expect(view.selectedCardID == .window(applications[0].windows[1].id))
    }
}
#endif
