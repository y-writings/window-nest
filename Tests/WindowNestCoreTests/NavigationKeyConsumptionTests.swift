import Testing
@testable import WindowNestCore

@Test func sequencePrefixesAreConsumedWithoutCommands() {
    for prefix in [KeyStroke(key: "tab"), KeyStroke(key: " ")] {
        let bindings = NavigationBindings(assignments: [
            .listStart: [KeySequence([prefix, KeyStroke(key: "g")])],
        ])
        var matcher = NavigationKeyMatcher(bindings: bindings)
        #expect(matcher.process(KeyStroke(key: "x"), at: 0) == .unhandled)
        #expect(matcher.process(prefix, at: 1) == .consumed)
        #expect(matcher.process(prefix, at: 1.05, isRepeat: true) == .consumed)
        #expect(matcher.process(KeyStroke(key: "g"), at: 1.1) == .command(.moveToListStart))
        #expect(matcher.process(KeyStroke(key: "x"), at: 2) == .unhandled)
    }
}

@Test func heldPrefixIsConsumedWithoutCompletingOrCancelingTheSequence() {
    var matcher = NavigationKeyMatcher(bindings: .vim)
    let prefix = KeyStroke(key: "g")
    #expect(matcher.process(prefix, at: 0) == .consumed)
    #expect(matcher.process(prefix, at: 0.2, isRepeat: true) == .consumed)
    #expect(matcher.process(prefix, at: 0.8, isRepeat: true) == .consumed)
    #expect(matcher.process(prefix, at: 1) == .command(.moveToListStart))
    #expect(matcher.process(prefix, at: 1.1, isRepeat: true) == .consumed)
}

@Test func heldFinalStrokeDoesNotLeakToAppKitOrRepeatASequenceCommand() {
    let prefix = KeyStroke(key: "tab")
    let last = KeyStroke(key: " ")
    let bindings = NavigationBindings(assignments: [
        .listStart: [KeySequence([prefix, last])],
    ])
    var matcher = NavigationKeyMatcher(bindings: bindings)
    #expect(matcher.process(prefix, at: 0) == .consumed)
    #expect(matcher.process(last, at: 0.1) == .command(.moveToListStart))
    #expect(matcher.process(last, at: 0.2, isRepeat: true) == .consumed)
    #expect(matcher.process(last, at: 2, isRepeat: true) == .consumed)
    #expect(matcher.process(last, at: 3) == .unhandled)
}

@Test func oneStrokeCommandsStillRepeatAndUnmatchedRepeatsRemainUnhandled() {
    var matcher = NavigationKeyMatcher(bindings: .vim)
    let left = KeyStroke(key: "h")
    #expect(matcher.process(left, at: 0) == .command(.moveLeft))
    #expect(matcher.process(left, at: 0.1, isRepeat: true) == .command(.moveLeft))
    #expect(matcher.process(KeyStroke(key: "x"), at: 0.2, isRepeat: true) == .unhandled)
    #expect(matcher.process(KeyStroke(key: "g"), at: 1) == .consumed)
    #expect(matcher.process(left, at: 1.1, isRepeat: true) == .command(.moveLeft))
    #expect(matcher.process(KeyStroke(key: "g"), at: 1.2) == .consumed)
}

@Test func prefixRepeatsWithoutAnInitialPressDoNotArmTheSequence() {
    let prefix = KeyStroke(key: "tab")
    let last = KeyStroke(key: " ")
    var matcher = NavigationKeyMatcher(bindings: NavigationBindings(assignments: [
        .listStart: [KeySequence([prefix, last])],
    ]))
    #expect(matcher.process(prefix, at: 0, isRepeat: true) == .consumed)
    #expect(matcher.process(last, at: 0.1) == .unhandled)
    #expect(matcher.process(prefix, at: 1) == .consumed)
    #expect(matcher.process(last, at: 1.1, isRepeat: true) == .unhandled)
    #expect(matcher.process(last, at: 1.2) == .unhandled)
}

@Test func mismatchesAreReprocessedAsFreshCommandsPrefixesOrUnhandledKeys() {
    let tab = KeyStroke(key: "tab")
    let space = KeyStroke(key: " ")
    let bindings = NavigationBindings(assignments: [
        .listStart: [KeySequence([tab, KeyStroke(key: "g")])],
        .listEnd: [KeySequence([space, KeyStroke(key: "z")])],
        .left: [KeySequence([KeyStroke(key: "h")])],
    ])
    var matcher = NavigationKeyMatcher(bindings: bindings)
    #expect(matcher.process(tab, at: 0) == .consumed)
    #expect(matcher.process(KeyStroke(key: "h"), at: 0.1) == .command(.moveLeft))
    #expect(matcher.process(tab, at: 1) == .consumed)
    #expect(matcher.process(space, at: 1.1) == .consumed)
    #expect(matcher.process(KeyStroke(key: "z"), at: 1.2) == .command(.moveToListEnd))
    #expect(matcher.process(tab, at: 2) == .consumed)
    #expect(matcher.process(KeyStroke(key: "x"), at: 2.1) == .unhandled)
    #expect(matcher.process(KeyStroke(key: "g"), at: 2.2) == .unhandled)
}

@Test func repeatsDoNotExtendTheSequenceDeadline() {
    let prefix = KeyStroke(key: "tab")
    let last = KeyStroke(key: " ")
    var matcher = NavigationKeyMatcher(bindings: NavigationBindings(assignments: [
        .listStart: [KeySequence([prefix, last])],
    ]))
    #expect(matcher.process(prefix, at: 0) == .consumed)
    #expect(matcher.process(prefix, at: 0.8, isRepeat: true) == .consumed)
    #expect(matcher.process(prefix, at: 1.001, isRepeat: true) == .consumed)
    #expect(matcher.process(last, at: 1.1) == .unhandled)
    #expect(matcher.process(prefix, at: 2) == .consumed)
    #expect(matcher.process(last, at: 3) == .command(.moveToListStart))
}

@Test func expiredPrefixesAreReprocessedAndCanStartANewSequence() {
    var matcher = NavigationKeyMatcher(bindings: .vim)
    let prefix = KeyStroke(key: "g")
    #expect(matcher.process(prefix, at: 0) == .consumed)
    #expect(matcher.process(prefix, at: 1.001) == .consumed)
    #expect(matcher.process(prefix, at: 1.1) == .command(.moveToListStart))
    #expect(matcher.process(prefix, at: 2) == .consumed)
    #expect(matcher.process(KeyStroke(key: "h"), at: 3.001) == .command(.moveLeft))
}

@Test func resettingOrUpdatingBindingsClearsPendingAndRepeatConsumption() {
    let prefix = KeyStroke(key: "tab")
    let last = KeyStroke(key: " ")
    let bindings = NavigationBindings(assignments: [
        .listStart: [KeySequence([prefix, last])],
    ])
    var matcher = NavigationKeyMatcher(bindings: bindings)
    #expect(matcher.process(prefix, at: 0) == .consumed)
    matcher.reset()
    #expect(matcher.process(last, at: 0.1) == .unhandled)
    #expect(matcher.process(prefix, at: 1) == .consumed)
    #expect(matcher.process(last, at: 1.1) == .command(.moveToListStart))
    matcher.reset()
    #expect(matcher.process(last, at: 1.2, isRepeat: true) == .unhandled)
    #expect(matcher.process(prefix, at: 2) == .consumed)
    matcher.update(.standard)
    #expect(matcher.process(last, at: 2.1) == .unhandled)
    #expect(matcher.process(prefix, at: 2.2, isRepeat: true) == .unhandled)
}
