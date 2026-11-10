import Foundation
import Testing
@testable import WindowNestCore

@Test func additionalKeysIgnoreEmptyAssignmentBuckets() {
    #expect(!NavigationBindings.standard.hasAdditionalKeys)
    #expect(!NavigationBindings(assignments: [.left: []]).hasAdditionalKeys)
    #expect(NavigationBindings.vim.hasAdditionalKeys)
}

private func apps(_ count: Int) -> [ApplicationItem] {
    (0..<count).map { ApplicationItem(id: Int32($0), name: "\($0)", windows: []) }
}

@Test func horizontalNavigationStopsAtListBoundaries() {
    var state = BrowserState(applications: apps(4))
    #expect(state.handle(.moveLeft) == .none); #expect(state.selectedIndex == 0)
    for index in 1...3 {
        #expect(state.handle(.moveRight) == .none)
        #expect(state.selectedIndex == index)
    }
    _ = state.handle(.moveRight); #expect(state.selectedIndex == 3)
    _ = state.handle(.moveLeft); #expect(state.selectedIndex == 2)
    _ = state.handle(.moveToListStart); #expect(state.selectedIndex == 0)
    _ = state.handle(.moveToListEnd); #expect(state.selectedIndex == 3)
}

@Test(arguments: [0, 1]) func emptyAndSingleItemNavigationIsSafe(count: Int) {
    var state = BrowserState(applications: apps(count))
    for command in [NavigationCommand.moveLeft, .moveRight, .moveToListStart, .moveToListEnd] {
        #expect(state.handle(command) == .none)
        #expect(state.selectedIndex == 0)
    }
}

@Test func listDestinationsUseWindowsWhenInsideAnApplication() {
    let windows = (1...4).map {
        WindowItem(id: WindowID(processIdentifier: 1, windowNumber: UInt32($0)), title: "Window \($0)")
    }
    var state = BrowserState(applications: [ApplicationItem(id: 1, name: "App", windows: windows)])
    state.handle(.showWindows)
    state.handle(.moveToListEnd)
    #expect(state.handle(.confirm) == .activate(windows[3].id))
    state.handle(.moveToListStart)
    #expect(state.handle(.confirm) == .activate(windows[0].id))
}

@Test func navigationDestinationsStayWithinFilteredApplications() {
    let applications = ["Other", "Match A", "Match B", "Match C", "Match D", "Hidden"].enumerated().map {
        ApplicationItem(id: Int32($0.offset), name: $0.element, windows: [])
    }
    var state = BrowserState(applications: applications)
    state.updateSearchQuery("match")
    state.handle(.moveToListEnd)
    #expect(state.selectedApplication?.name == "Match D")
    state.handle(.moveRight)
    #expect(state.selectedIndex == 3)
    state.handle(.moveToListStart)
    #expect(state.selectedApplication?.name == "Match A")

    state.updateSearchQuery("missing")
    state.handle(.moveToListEnd)
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
    #expect(matcher.match(KeyStroke(key: "$", modifiers: .shift), at: 4) == .moveToListEnd)
    #expect(matcher.match(KeyStroke(key: "0"), at: 4.1) == .moveToListStart)
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
    let allowed = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "g")])], .right: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "h")])], .listEnd: [KeySequence([KeyStroke(key: "n", modifiers: .control)])]])
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

@Test(arguments: [false, true]) func legacyGridBindingsPreserveHorizontalKeys(rowKeysFirst: Bool) throws {
    let suite = "WindowNestTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let rows = #"""
    "rowStart", [{"strokes":[{"key":"0","modifiers":0}]}],
    "rowEnd", [{"strokes":[{"key":"$","modifiers":1}]}]
    """#
    let lists = #"""
    "listStart", [{"strokes":[{"key":"g","modifiers":0},{"key":"g","modifiers":0}]}],
    "listEnd", [{"strokes":[{"key":"g","modifiers":1}]}]
    """#
    let legacyJSON = """
    {"assignments":[
        "left", [{"strokes":[{"key":"h","modifiers":0}]}],
        "right", [{"strokes":[{"key":"l","modifiers":0}]}],
        "up", [{"strokes":[{"key":"k","modifiers":0}]}],
        "down", [{"strokes":[{"key":"j","modifiers":0}]}],
        \(rowKeysFirst ? rows : lists), \(rowKeysFirst ? lists : rows)
    ]}
    """
    let data = Data(legacyJSON.utf8)
    defaults.set(data, forKey: "navigationBindings")
    let store = NavigationBindingsStore(defaults: defaults)
    let loaded = store.load()
    for action in NavigationAction.allCases {
        #expect(Set(loaded.assignments[action] ?? []) == Set(NavigationBindings.vim.assignments[action] ?? []))
    }
    #expect(defaults.data(forKey: "navigationBindings") == data)
    try store.save(loaded)
    #expect(store.load() == loaded)
}

@Test func legacyVerticalOnlyBindingsBecomeStandard() throws {
    let suite = "WindowNestTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacyJSON = #"""
    {"assignments":[
        "up", [{"strokes":[{"key":"k","modifiers":0}]}],
        "down", [{"strokes":[{"key":"j","modifiers":0}]}]
    ]}
    """#
    defaults.set(Data(legacyJSON.utf8), forKey: "navigationBindings")
    let loaded = NavigationBindingsStore(defaults: defaults).load()
    #expect(loaded == .standard)
    #expect(!loaded.hasAdditionalKeys)
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
