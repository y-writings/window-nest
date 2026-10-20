#if os(macOS)
import Carbon
import Combine
import Foundation
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct AtomicShortcutTests {
    private func makeDefaults() throws -> (String, UserDefaults) {
        let suite = "WindowNestAtomicShortcutTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(kVK_ANSI_W, forKey: "shortcutKeyCode")
        defaults.set(cmdKey | optionKey, forKey: "shortcutModifiers")
        return (suite, defaults)
    }

    private var crossedConflicts: NavigationBindings {
        NavigationBindings(assignments: [
            .left: [KeySequence([KeyStroke(key: " ", modifiers: [.command, .option])])],
            .right: [KeySequence([KeyStroke(key: "w", modifiers: [.control, .option])])],
        ])
    }

    @Test func finalPairSucceedsWhenBothIntermediatePairsConflict() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "w" })
        let original = settings.globalShortcut
        #expect(settings.applyNavigationBindings(crossedConflicts))

        #expect(!settings.updateGlobal(keyCode: UInt32(kVK_Space)))
        #expect(settings.globalShortcut == original)
        #expect(!settings.updateGlobal(modifiers: UInt32(controlKey | optionKey)))
        #expect(settings.globalShortcut == original)

        #expect(settings.updateGlobal(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))
        #expect(settings.globalShortcut == GlobalShortcutConfiguration(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))
        #expect(settings.globalKeyStroke == KeyStroke(key: " ", modifiers: [.control, .option]))
        #expect(settings.bindingError == nil)
        #expect(settings.navigationBindings == crossedConflicts)
        #expect(defaults.integer(forKey: "shortcutKeyCode") == kVK_Space)
        #expect(defaults.integer(forKey: "shortcutModifiers") == (controlKey | optionKey))
    }

    @Test func rejectedPairPreservesSavedStateAndDoesNotNotify() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "w" })
        let original = settings.globalShortcut
        #expect(settings.applyNavigationBindings(crossedConflicts))
        let changes = ObservedShortcutChanges()
        let observer = observe(settings, changes: changes)
        defer { NotificationCenter.default.removeObserver(observer) }
        var published: [GlobalShortcutConfiguration] = []
        let subscription = settings.$globalShortcut.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        #expect(!settings.updateGlobal(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)))
        #expect(settings.globalShortcut == original)
        #expect(settings.bindingError != nil)
        #expect(settings.navigationBindings == crossedConflicts)
        #expect(defaults.integer(forKey: "shortcutKeyCode") == kVK_ANSI_W)
        #expect(defaults.integer(forKey: "shortcutModifiers") == (cmdKey | optionKey))
        #expect(published.isEmpty)
        #expect(changes.configurations.isEmpty)
    }

    @Test func acceptedPairPublishesAndNotifiesOnceWithTheFinalState() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "w" })
        let expected = GlobalShortcutConfiguration(
            keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey))
        let changes = ObservedShortcutChanges()
        let observer = observe(settings, changes: changes)
        defer { NotificationCenter.default.removeObserver(observer) }
        var published: [GlobalShortcutConfiguration] = []
        let subscription = settings.$globalShortcut.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        #expect(settings.updateGlobal(keyCode: expected.keyCode, modifiers: expected.modifiers))
        #expect(published == [expected])
        #expect(changes.configurations == [expected])
        #expect(settings.keyCode == expected.keyCode)
        #expect(settings.modifiers == expected.modifiers)
        #expect(defaults.integer(forKey: "shortcutKeyCode") == Int(expected.keyCode))
        #expect(defaults.integer(forKey: "shortcutModifiers") == Int(expected.modifiers))
    }

    private func observe(_ settings: ShortcutSettings, changes: ObservedShortcutChanges) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .shortcutDidChange, object: nil, queue: nil) { _ in
            // updateGlobal posts synchronously from the main actor, after assigning both fields.
            MainActor.assumeIsolated { changes.configurations.append(settings.globalShortcut) }
        }
    }
}

@MainActor
private final class ObservedShortcutChanges {
    var configurations: [GlobalShortcutConfiguration] = []
}
#endif
