#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct OverlayRenderingTests {
    @Test(arguments: ApplicationSearchMode.allCases)
    func hostedCardsFollowFilteredApplicationIdentity(mode: ApplicationSearchMode) async throws {
        let applications = [
            application(id: 1, name: "1Password"),
            application(id: 2, name: "Safari"),
            application(id: 3, name: "Zed"),
        ]
        let model = OverlayModel(system: MacWindowSystem())
        model.state = BrowserState(applications: applications, searchMode: mode)
        let controller = NSHostingController(rootView: OverlayView(model: model))
        controller.view.frame = NSRect(x: 0, y: 0, width: 920, height: 600)

        await render(controller.view)
        #expect(cardIdentifiers(in: controller.view) == Set(applications.map { "application-card-\($0.id)" }))

        model.state.updateSearchQuery("zed")
        await render(controller.view)
        #expect(cardIdentifiers(in: controller.view) == ["application-card-3"])
        #expect(model.state.handle(.confirm) == .activate(applications[2].windows[0].id))

        model.state.updateSearchQuery("no matches")
        await render(controller.view)
        #expect(cardIdentifiers(in: controller.view).isEmpty)

        model.state.updateSearchQuery("saf")
        await render(controller.view)
        #expect(cardIdentifiers(in: controller.view) == ["application-card-2"])
        #expect(model.state.handle(.terminateApplication) == .terminateApplication(2))

        model.state.updateSearchQuery("")
        await render(controller.view)
        #expect(cardIdentifiers(in: controller.view) == Set(applications.map { "application-card-\($0.id)" }))
    }

    private func application(id: Int32, name: String) -> ApplicationItem {
        ApplicationItem(id: id, name: name, windows: [
            WindowItem(id: WindowID(processIdentifier: id, windowNumber: UInt32(id)), title: "\(name) window")
        ])
    }

    private func render(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        await Task.yield()
        view.layoutSubtreeIfNeeded()
    }

    private func cardIdentifiers(in root: any NSAccessibilityProtocol) -> Set<String> {
        var result: Set<String> = []
        var pending: [any NSAccessibilityProtocol] = [root]
        while let element = pending.popLast() {
            if let identifier = element.accessibilityIdentifier(), identifier.hasPrefix("application-card-") {
                result.insert(identifier)
            }
            pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap {
                $0 as? any NSAccessibilityProtocol
            })
        }
        return result
    }
}
#endif
