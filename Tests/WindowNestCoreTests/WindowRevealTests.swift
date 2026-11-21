import Foundation
import Testing
@testable import WindowNestCore

private func window(_ pid: Int32, _ number: UInt32, _ title: String) -> WindowItem {
    WindowItem(id: WindowID(processIdentifier: pid, windowNumber: number), title: title)
}

private func browserApps() -> [ApplicationItem] {
    [
        ApplicationItem(id: 1, name: "Browser", windows: [window(1, 11, "One"), window(1, 12, "Two")]),
        ApplicationItem(id: 2, name: "Editor", windows: [window(2, 21, "Code")]),
        ApplicationItem(id: 3, name: "Notes", windows: [window(3, 31, "A"), window(3, 32, "B"), window(3, 33, "C")]),
    ]
}

@Test func revealShowsEveryWindowUnderTheSelectedIconIncludingASingleWindow() {
    var state = BrowserState(applications: browserApps())
    #expect(state.handle(.revealWindows) == .none)
    #expect(state.screen == .applications)
    #expect(state.windowsRevealed)
    #expect(state.selectedApplication?.id == 1)
    #expect(state.visibleWindows.map(\.title) == ["One", "Two"])
    #expect(state.selectedWindowIndex == 0)

    state.handle(.moveRight)
    #expect(state.selectedApplication?.id == 2)
    #expect(state.windowsRevealed)
    #expect(state.visibleWindows.map(\.title) == ["Code"])
    #expect(state.selectedWindowIndex == 0)
    #expect(state.handle(.confirm) == .activate(window(2, 21, "Code").id))
    #expect(state.screen == .applications)
}

@Test func revealDoesNotActivateUntilTheWindowCandidateIsConfirmed() {
    var state = BrowserState(applications: browserApps())
    state.handle(.moveRight)
    #expect(state.handle(.confirm) == .activate(window(2, 21, "Code").id))
    #expect(!state.windowsRevealed)

    var listed = BrowserState(applications: browserApps())
    #expect(listed.handle(.confirm) == .none)
    #expect(listed.screen == .windows(applicationID: 1))
    #expect(!listed.windowsRevealed)
}

@Test func repeatedDownMovesThroughWindowsAndUpClosesFromTheFirst() {
    var state = BrowserState(applications: browserApps())
    state.handle(.revealWindows)
    state.handle(.revealWindows)
    #expect(state.selectedWindowIndex == 1)
    state.handle(.revealWindows)
    #expect(state.selectedWindowIndex == 1)
    #expect(state.handle(.concealWindows) == .none)
    #expect(state.selectedWindowIndex == 0)
    #expect(state.windowsRevealed)
    #expect(state.handle(.concealWindows) == .none)
    #expect(!state.windowsRevealed)
    #expect(state.handle(.concealWindows) == .none)
    #expect(state.screen == .applications)
}

@Test func escapeClosesTheIconWindowListBeforeDismissing() {
    var state = BrowserState(applications: browserApps())
    state.handle(.revealWindows)
    state.handle(.revealWindows)
    #expect(state.handle(.escape) == .none)
    #expect(!state.windowsRevealed)
    #expect(state.selectedApplication?.id == 1)
    #expect(state.handle(.escape) == .dismiss)
}

@Test func horizontalMovementKeepsTheListUnderTheNewlySelectedIcon() {
    var state = BrowserState(applications: browserApps())
    state.handle(.revealWindows)
    state.handle(.revealWindows)
    state.handle(.moveToListEnd)
    #expect(state.selectedApplication?.name == "Notes")
    #expect(state.windowsRevealed)
    #expect(state.selectedWindowIndex == 0)
    #expect(state.visibleWindows.map(\.title) == ["A", "B", "C"])
    state.handle(.moveToListStart)
    #expect(state.selectedApplication?.id == 1)
    #expect(state.selectedWindowIndex == 0)
    #expect(state.windowsRevealed)
}

@Test func revealedWindowCanBeChosenClosedOrPassedToTheFullList() {
    var state = BrowserState(applications: browserApps())
    state.handle(.revealWindows)
    #expect(state.handle(.chooseNumber(2)) == .activate(window(1, 12, "Two").id))

    state.handle(.revealWindows)
    state.handle(.revealWindows)
    #expect(state.handle(.closeWindow) == .closeWindow(window(1, 12, "Two").id))
    #expect(state.handle(.terminateApplication) == .terminateApplication(1))
    #expect(state.handle(.showWindows) == .none)
    #expect(state.screen == .windows(applicationID: 1))
    #expect(state.selectedIndex == 1)
    #expect(!state.windowsRevealed)
}

@Test func revealOnTheFullWindowListDoesNotChangeSelection() {
    var state = BrowserState(applications: browserApps())
    state.handle(.confirm)
    state.handle(.moveRight)
    #expect(state.handle(.revealWindows) == .none)
    #expect(state.handle(.concealWindows) == .none)
    #expect(state.screen == .windows(applicationID: 1))
    #expect(state.selectedIndex == 1)
}

@Test func searchClearsTheRevealedWindowList() {
    var state = BrowserState(applications: browserApps())
    state.handle(.revealWindows)
    state.updateSearchQuery("note")
    #expect(!state.windowsRevealed)
    #expect(state.selectedApplication?.name == "Notes")
}

@Test func reloadKeepsTheRevealedWindowAndDropsAMissingApplication() {
    var state = BrowserState(applications: browserApps())
    state.handle(.moveToListEnd)
    state.handle(.revealWindows)
    state.handle(.revealWindows)
    let kept = window(3, 32, "B")
    state.replaceApplications([
        ApplicationItem(id: 3, name: "Notes", windows: [window(3, 31, "A"), kept]),
    ])
    #expect(state.windowsRevealed)
    #expect(state.selectedWindowIndex == 1)
    #expect(state.visibleWindows[state.selectedWindowIndex].id == kept.id)

    state.replaceApplications([
        ApplicationItem(id: 2, name: "Editor", windows: [window(2, 21, "Code")]),
    ])
    #expect(!state.windowsRevealed)
    #expect(state.screen == .applications)
    #expect(state.selectedApplication?.id == 2)
}

@Test func emptyApplicationCannotRevealWindows() {
    var state = BrowserState(applications: [ApplicationItem(id: 4, name: "Idle", windows: [])])
    #expect(state.handle(.revealWindows) == .none)
    #expect(!state.windowsRevealed)
    #expect(state.visibleWindows.isEmpty)
}

@Test func vimPresetBindsJAndStillRejectsTheArrowKeys() {
    #expect(NavigationBindingValidator.validate(NavigationBindings.vim) == nil)
    #expect(NavigationBindings.vim.assignments[.windows] == [KeySequence([KeyStroke(key: "j")])])
    #expect(NavigationBindings.standard.assignments[.windows] == nil)
    let down = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "down")])]])
    #expect(NavigationBindingValidator.validate(down) == .reserved(KeyStroke(key: "down")))
    let up = NavigationBindings(assignments: [.right: [KeySequence([KeyStroke(key: "up")])]])
    #expect(NavigationBindingValidator.validate(up) == .reserved(KeyStroke(key: "up")))
}

@Test func loadingDropsADownArrowBindingWithoutDroppingItsNeighbors() throws {
    let suite = "WindowNestTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = #"""
    {"assignments":[
        "left", [{"strokes":[{"key":"h","modifiers":0}]},{"strokes":[{"key":"down","modifiers":0}]}]
    ]}
    """#
    defaults.set(Data(legacy.utf8), forKey: "navigationBindings")
    let loaded = NavigationBindingsStore(defaults: defaults).load()
    #expect(loaded == NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "h")])]]))
}
