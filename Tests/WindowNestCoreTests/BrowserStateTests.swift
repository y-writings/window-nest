import Foundation
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

@Test func confirmingSingleWindowApplicationActivatesItWithoutChangingScreens() {
    var state = BrowserState(applications: fixtures())
    #expect(state.handle(.moveRight) == .none)
    #expect(state.screen == .applications)
    #expect(state.handle(.confirm) == .activate(.init(processIdentifier: 2, windowNumber: 21)))
    #expect(state.screen == .applications)
    #expect(state.visibleWindows.isEmpty)
}

@Test func confirmingMultipleWindowApplicationEntersItsWindowList() {
    var state = BrowserState(applications: fixtures())
    #expect(state.handle(.confirm) == .none)
    #expect(state.screen == .windows(applicationID: 1))
    #expect(state.visibleWindows.map(\.title) == ["One", "Two"])
}

@Test func selectingSingleWindowApplicationDoesNotActivateIt() {
    var state = BrowserState(applications: fixtures())
    #expect(state.handle(.moveRight) == .none)
    #expect(state.screen == .applications)
    #expect(state.selectedApplication?.id == 2)
}

@Test func confirmingApplicationWithoutWindowsDoesNothing() {
    var state = BrowserState(applications: [
        ApplicationItem(id: 3, name: "Closed", windows: []),
    ])
    #expect(state.handle(.confirm) == .none)
    #expect(state.screen == .applications)
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

@Test func fuzzySearchMatchesAndRanksWithoutChangingStableOrder() {
    let applications = ["Pass", "PassKit", "1Password", "Compass", "P-A-S-S"].enumerated().map {
        ApplicationItem(id: Int32($0.offset), name: $0.element, windows: [])
    }
    let results = ApplicationSearch.results(in: applications, query: "  pAsS ", mode: .fuzzy)
    #expect(results.map(\.name) == ["Pass", "PassKit", "1Password", "Compass", "P-A-S-S"])
    #expect(ApplicationSearch.results(in: applications, query: "   ", mode: .fuzzy) == applications)
}

@Test(arguments: [
    ("1Password", "pass", true, false),
    ("1Password", "1pa", true, true),
    ("1Password", "psw", true, false),
    ("1Password", "pp", false, false),
    ("Safari", "SAF", true, true),
    ("Safari", "sfi", true, false),
    ("Safari", "fs", false, false),
])
func searchExamples(name: String, query: String, fuzzy: Bool, prefix: Bool) {
    let item = ApplicationItem(id: 1, name: name, windows: [])
    #expect(!ApplicationSearch.results(in: [item], query: query, mode: .fuzzy).isEmpty == fuzzy)
    #expect(!ApplicationSearch.results(in: [item], query: query, mode: .prefix).isEmpty == prefix)
}

@Test func filteringConfirmsTheVisibleSingleWindowApplication() {
    var state = BrowserState(applications: fixtures())
    state.updateSearchQuery("dit")
    #expect(state.selectedApplication?.name == "Editor")
    #expect(state.handle(.confirm) == .activate(.init(processIdentifier: 2, windowNumber: 21)))
    #expect(state.screen == .applications)
}

@Test func searchChangesSelectFirstAndZeroResultsCannotConfirm() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.moveRight)
    state.updateSearchQuery("missing")
    #expect(state.selectedApplication == nil)
    #expect(state.handle(.confirm) == .none)
    state.updateSearchQuery("")
    #expect(state.selectedApplication?.id == 1)
}

@Test func modeChangeInWindowsIsDeferredUntilReturning() {
    let apps = [ApplicationItem(id: 1, name: "1Password", windows: [
        WindowItem(id: .init(processIdentifier: 1, windowNumber: 1), title: "Password"),
        WindowItem(id: .init(processIdentifier: 1, windowNumber: 2), title: "Settings"),
    ])]
    var state = BrowserState(applications: apps)
    state.updateSearchQuery("pass")
    #expect(state.handle(.confirm) == .none)
    _ = state.handle(.moveRight)
    state.updateSearchMode(.prefix)
    #expect(state.screen == .windows(applicationID: 1))
    #expect(state.selectedApplication?.id == 1)
    #expect(state.handle(.confirm) == .activate(.init(processIdentifier: 1, windowNumber: 2)))
    _ = state.handle(.escape)
    #expect(state.searchQuery == "pass")
    #expect(state.visibleApplications.isEmpty)
    #expect(state.selectedApplication == nil)
}

@Test func reloadPreservesVisibleApplicationByIdentityOrSelectsFirst() {
    var state = BrowserState(applications: fixtures())
    _ = state.handle(.moveRight)
    state.replaceApplications(fixtures().reversed())
    #expect(state.selectedApplication?.id == 2)
    state.replaceApplications([fixtures()[0]])
    #expect(state.selectedApplication?.id == 1)
}

@Test func searchModeDefaultsAndPersistsInIsolatedDefaults() {
    let suiteName = "WindowNestCoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var store = ApplicationSearchModeStore(defaults: defaults)
    #expect(store.value == .fuzzy)
    store.value = .prefix
    store = ApplicationSearchModeStore(defaults: defaults)
    #expect(store.value == .prefix)
}
