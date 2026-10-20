#if os(macOS)
import AppKit
import Carbon
import Combine
import Foundation
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct KeyboardLayoutChangeTests {
    private func makeDefaults() throws -> (String, UserDefaults) {
        let suite = "WindowNestLayoutTests-\(UUID())"
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    private var configured: NavigationBindings {
        let conflict = KeyStroke(key: "z", modifiers: [.command, .option])
        return NavigationBindings(assignments: [
            .left: [KeySequence([conflict]), KeySequence([KeyStroke(key: "h")])],
            .right: [KeySequence([KeyStroke(key: "g"), conflict])],
        ])
    }

    @Test func startupDisablesOnlyConflictingSequencesAndPreservesSavedBindings() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationBindingsStore(defaults: defaults)
        try store.save(configured)
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "z" })
        #expect(settings.navigationBindings == configured)
        #expect(settings.activeNavigationBindings.assignments[.left] == [KeySequence([KeyStroke(key: "h")])])
        #expect(settings.activeNavigationBindings.assignments[.right] == [])
        #expect(settings.bindingError?.contains("temporarily disabled") == true)
        #expect(store.load() == configured)
    }

    @Test func layoutChangesRestorePreservedBindingsWhenTheConflictClears() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var character = "w"
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in character })
        #expect(settings.applyNavigationBindings(configured))
        character = "z"
        settings.refreshActiveNavigationBindings()
        #expect(settings.activeNavigationBindings != configured)
        #expect(settings.navigationBindings == configured)
        character = "w"
        settings.refreshActiveNavigationBindings()
        #expect(settings.activeNavigationBindings == configured)
        #expect(settings.bindingError == nil)
        #expect(NavigationBindingsStore(defaults: defaults).load() == configured)
    }

    @Test func unavailableLayoutTemporarilyDisablesCustomBindingsAndRecovers() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationBindingsStore(defaults: defaults)
        try store.save(configured)
        var character: String?
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in character })
        #expect(settings.activeNavigationBindings == .standard)
        #expect(settings.navigationBindings == configured)
        #expect(settings.bindingError?.contains("temporarily disabled") == true)
        character = "w"
        settings.refreshActiveNavigationBindings()
        #expect(settings.activeNavigationBindings == configured)
        #expect(settings.bindingError == nil)
        #expect(store.load() == configured)
    }

    @Test func changingTheGlobalShortcutRestoresPreservedBindings() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationBindingsStore(defaults: defaults)
        try store.save(configured)
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "z" })
        #expect(settings.activeNavigationBindings != configured)
        #expect(settings.updateGlobal(keyCode: UInt32(kVK_Tab)))
        #expect(settings.activeNavigationBindings == configured)
        #expect(settings.bindingError == nil)
        #expect(store.load() == configured)
    }

    @Test(.timeLimit(.minutes(1)))
    func inputSourceNotificationRevalidatesTheActiveBindings() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var character = "w"
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in character })
        #expect(settings.applyNavigationBindings(configured))
        character = "z"
        let (updates, continuation) = AsyncStream<NavigationBindings>.makeStream()
        let subscription = settings.$activeNavigationBindings.dropFirst().prefix(1).sink {
            continuation.yield($0)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            continuation.finish()
        }
        defer { timeout.cancel(); subscription.cancel(); continuation.finish() }
        NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        var iterator = updates.makeAsyncIterator()
        let received = await iterator.next()
        let active = try #require(received)
        #expect(active.assignments[.left] == [KeySequence([KeyStroke(key: "h")])])
        #expect(settings.navigationBindings == configured)
    }
}
#endif
