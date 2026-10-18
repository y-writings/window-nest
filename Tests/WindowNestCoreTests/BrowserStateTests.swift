import Testing
@testable import WindowNestCore

private func fixtures() -> [ApplicationItem] {
    [
        ApplicationItem(id: 1, name: "Browser", windows: [
            WindowItem(id: .init(processIdentifier: 1, windowNumber: 11), title: "One"),
            WindowItem(id: .init(processIdentifier: 1, windowNumber: 12), title: "Two"),
        ]),
        ApplicationItem(id: 2, name: "Editor", windows: [
            WindowItem(id: .init(processIdentifier: 2, windowNumber: 21), title: "Code"),
        ]),
    ]
}

@Test func entersSelectedApplicationWithoutActivatingAWindow() {
    var state = BrowserState(applications: fixtures())
    #expect(state.handle(.moveRight) == .none)
    #expect(state.handle(.confirm) == .none)
    #expect(state.screen == .windows(applicationID: 2))
    #expect(state.visibleWindows.map(\.title) == ["Code"])
}

@Test func escapeMovesBackThenDismisses() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.confirm)
    #expect(state.handle(.escape) == .none)
    #expect(state.screen == .applications)
    #expect(state.handle(.escape) == .dismiss)
}

@Test func keyboardAndNumberSelectionActivateTheVisibleWindow() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.confirm)
    _ = state.handle(.moveRight)
    #expect(state.handle(.confirm) == .activate(.init(processIdentifier: 1, windowNumber: 12)))
    #expect(state.handle(.chooseNumber(1)) == .activate(.init(processIdentifier: 1, windowNumber: 11)))
}

@Test func disappearingWindowNeverChangesIdentity() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.confirm)
    _ = state.handle(.moveRight)
    let updated = [ApplicationItem(id: 1, name: "Browser", windows: [fixtures()[0].windows[0]])]
    state.replaceApplications(updated)
    #expect(state.handle(.confirm) == .activate(.init(processIdentifier: 1, windowNumber: 11)))
}

@Test func disappearingApplicationSafelyReturnsToApplications() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.confirm)
    state.replaceApplications([fixtures()[1]])
    #expect(state.screen == .applications)
    #expect(state.selectedApplication?.id == 2)
}
