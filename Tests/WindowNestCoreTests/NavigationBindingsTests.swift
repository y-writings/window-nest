import Foundation
import Testing
@testable import WindowNestCore

private func apps(_ count: Int) -> [ApplicationItem] {
    (0..<count).map { ApplicationItem(id: Int32($0), name: "\($0)", windows: []) }
}

@Test func gridDestinationsUseRealCards() {
    var state = BrowserState(applications: apps(7), columnCount: 3)
    for _ in 0..<4 { _ = state.handle(.moveRight) }
    _ = state.handle(.moveToRowStart); #expect(state.selectedIndex == 3)
    _ = state.handle(.moveRight); _ = state.handle(.moveToRowEnd); #expect(state.selectedIndex == 5)
    _ = state.handle(.moveToListStart); #expect(state.selectedIndex == 0)
    _ = state.handle(.moveToListEnd); #expect(state.selectedIndex == 6)
    _ = state.handle(.moveToRowStart); #expect(state.selectedIndex == 6)
    _ = state.handle(.moveToRowEnd); #expect(state.selectedIndex == 6)
    #expect(state.handle(.moveDown) == .none); #expect(state.selectedIndex == 6)
}

@Test func emptyAndSingleItemNavigationIsSafe() {
    var empty = BrowserState(); _ = empty.handle(.moveToListEnd); #expect(empty.selectedIndex == 0)
    var single = BrowserState(applications: apps(1)); _ = single.handle(.moveToRowEnd); #expect(single.selectedIndex == 0)
}

@Test func vimMatcherDistinguishesShiftAndModifiers() {
    var matcher = NavigationKeyMatcher(bindings: .vim)
    #expect(matcher.match(KeyStroke(key: "g"), at: 0) == nil)
    #expect(matcher.match(KeyStroke(key: "g"), at: 1) == .moveToListStart)
    #expect(matcher.match(KeyStroke(key: "G"), at: 2) == .moveToListEnd)
    #expect(matcher.match(KeyStroke(key: "h", modifiers: .control), at: 3) == nil)
    #expect(matcher.match(KeyStroke(key: "$", modifiers: .shift), at: 4) == .moveToRowEnd)
    #expect(matcher.match(KeyStroke(key: "4"), at: 5) == nil)
}

@Test func twoStrokeTimeoutMismatchAndRepeatAreDeterministic() {
    var matcher = NavigationKeyMatcher(bindings: .vim)
    #expect(matcher.match(KeyStroke(key: "g"), at: 0) == nil)
    #expect(matcher.match(KeyStroke(key: "g"), at: 1.001) == nil)
    matcher.reset()
    #expect(matcher.match(KeyStroke(key: "g"), at: 2) == nil)
    #expect(matcher.match(KeyStroke(key: "h"), at: 2.1) == .moveLeft)
    #expect(matcher.match(KeyStroke(key: "g"), at: 3) == nil)
    #expect(matcher.match(KeyStroke(key: "g"), at: 3.1, isRepeat: true) == nil)
}

@Test func validationRejectsReservedDuplicatePrefixAndGlobal() {
    let reserved = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "1")])]])
    #expect(NavigationBindingValidator.validate(reserved) == .reserved(KeyStroke(key: "1")))
    let duplicate = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "x")])], .right: [KeySequence([KeyStroke(key: "x")])]])
    #expect(NavigationBindingValidator.validate(duplicate) != nil)
    let prefix = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "g")])], .right: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "h")])]])
    #expect(NavigationBindingValidator.validate(prefix) != nil)
    #expect(NavigationBindingValidator.validate(.vim, globalShortcut: KeyStroke(key: "h")) != nil)
    let allowed = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "g")])], .right: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "h")])], .down: [KeySequence([KeyStroke(key: "n", modifiers: .control)])]])
    #expect(NavigationBindingValidator.validate(allowed) == nil)
}

@Test func storePreservesValidEmptyAndFallsBackFromCorruption() throws {
    let suite = "WindowNestTests-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let store = NavigationBindingsStore(defaults: defaults)
    try store.save(.vim); #expect(store.load() == .vim)
    try store.save(.standard); #expect(store.load() == .standard)
    defaults.set(Data("broken".utf8), forKey: "navigationBindings"); #expect(store.load() == .standard)
}
