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

@Test func navigationDestinationsStayWithinFilteredApplications() {
    let applications = ["Other", "Match A", "Match B", "Match C", "Match D", "Hidden"].enumerated().map {
        ApplicationItem(id: Int32($0.offset), name: $0.element, windows: [])
    }
    var state = BrowserState(applications: applications, columnCount: 3)
    state.updateSearchQuery("match")
    state.handle(.moveToRowEnd)
    #expect(state.selectedApplication?.name == "Match C")
    state.handle(.moveToListEnd)
    #expect(state.selectedApplication?.name == "Match D")
    state.handle(.moveToRowEnd)
    #expect(state.selectedIndex == 3)

    state.updateSearchQuery("missing")
    state.handle(.moveToListEnd)
    state.handle(.moveToRowEnd)
    #expect(state.selectedIndex == 0)
    #expect(state.selectedApplication == nil)
    #expect(state.handle(.confirm) == .none)
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

@Test func loadingDropsOnlyBindingsThatBecameReserved() throws {
    let suite = "WindowNestTests-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let bindings = NavigationBindings(assignments: [.left: [
        KeySequence([KeyStroke(key: "h")]), KeySequence([KeyStroke(key: "q", modifiers: .command)]),
    ]])
    defaults.set(try JSONEncoder().encode(bindings), forKey: "navigationBindings")
    #expect(NavigationBindingsStore(defaults: defaults).load() == NavigationBindings(assignments: [
        .left: [KeySequence([KeyStroke(key: "h")])],
    ]))
}

@Test func tabAliasesConflictWithEveryGlobalModifierCombination() {
    let combinations: [KeyModifiers] = [[.command, .option], [.control, .option], [.control, .command]]
    for modifiers in combinations {
        let global = KeyStroke(key: "tab", modifiers: modifiers)
        for key in ["\t", "\u{19}", "tab"] {
            let stroke = KeyStroke(key: key, modifiers: modifiers)
            #expect(stroke == global)
            let bindings = NavigationBindings(assignments: [.left: [KeySequence([stroke])]])
            #expect(NavigationBindingValidator.validate(bindings, globalShortcut: global) == .globalShortcut(global))
            #expect(NavigationBindingValidator.validate(bindings, globalShortcut: KeyStroke(key: "tab")) == nil)
            let sequence = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "g"), stroke])]])
            #expect(NavigationBindingValidator.validate(sequence, globalShortcut: global) == .globalShortcut(global))
        }
    }
}

@Test func legacyTabBindingsAreNormalizedWhenLoaded() throws {
    let suite = "WindowNestTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = NavigationBindingsStore(defaults: defaults)
    let tab = KeyStroke(key: "tab", modifiers: [.command, .option])
    let bindings = NavigationBindings(assignments: [.left: [KeySequence([tab])]])
    let encoded = try JSONEncoder().encode(bindings)
    // Simulate data saved before Tab was canonicalized, rather than encoding a new stroke.
    let legacyJSON = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"tab\"", with: "\"\\t\"")
    #expect(legacyJSON != String(decoding: encoded, as: UTF8.self))
    defaults.set(Data(legacyJSON.utf8), forKey: "navigationBindings")
    let loaded = store.load()
    #expect(loaded == bindings)
    #expect(NavigationBindingValidator.validate(loaded, globalShortcut: tab) == .globalShortcut(tab))
    var matcher = NavigationKeyMatcher(bindings: loaded)
    #expect(matcher.match(tab, at: 0) == .moveLeft)
    try store.save(loaded)
    #expect(store.load() == bindings)
}

@Test func changingRecordingLengthDiscardsThePartialSequence() {
    var recording = NavigationKeyRecording()
    recording.strokeCount = 2
    #expect(recording.record(KeyStroke(key: "g")) == nil)
    recording.strokeCount = 1
    #expect(recording.strokes.isEmpty)
    #expect(recording.record(KeyStroke(key: "h")) == KeySequence([KeyStroke(key: "h")]))
    #expect(recording.strokes.isEmpty)
    recording.strokeCount = 2
    #expect(recording.record(KeyStroke(key: "j")) == nil)
    #expect(recording.record(KeyStroke(key: "k")) == KeySequence([KeyStroke(key: "j"), KeyStroke(key: "k")]))
    #expect(recording.strokes.isEmpty)
}

@Test func clearingAPartialRecordingStartsAFreshSequence() {
    var recording = NavigationKeyRecording()
    recording.strokeCount = 2
    #expect(recording.record(KeyStroke(key: "g")) == nil)
    recording.reset()
    #expect(recording.strokes.isEmpty)
    #expect(recording.record(KeyStroke(key: "h")) == nil)
    #expect(recording.record(KeyStroke(key: "j")) == KeySequence([KeyStroke(key: "h"), KeyStroke(key: "j")]))
    #expect(recording.strokes.isEmpty)
    #expect(recording.record(KeyStroke(key: "k")) == nil)
}

@Test func rejectedRecordingDoesNotPreventTheNextRecording() throws {
    var recording = NavigationKeyRecording()
    let completed = recording.record(KeyStroke(key: "1"))
    let reserved = try #require(completed)
    let bindings = NavigationBindings(assignments: [.left: [reserved]])
    #expect(NavigationBindingValidator.validate(bindings) == .reserved(KeyStroke(key: "1")))
    #expect(recording.strokes.isEmpty)
    #expect(recording.record(KeyStroke(key: "h")) == KeySequence([KeyStroke(key: "h")]))
}
