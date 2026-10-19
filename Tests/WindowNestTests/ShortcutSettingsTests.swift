#if os(macOS)
import AppKit
import Carbon
import Combine
import Foundation
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct ShortcutSettingsTests {
    private func makeDefaults() throws -> (String, UserDefaults) {
        let suite = "WindowNestSettingsTests-\(UUID())"
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    @Test func tabEventsMatchTheGlobalShortcut() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults)
        settings.updateGlobal(keyCode: UInt32(kVK_Tab))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
        #expect(event.navigationStroke == settings.globalKeyStroke)
        let stroke = try #require(event.navigationStroke)
        #expect(!settings.applyNavigationBindings(NavigationBindings(assignments: [.left: [KeySequence([stroke])]])))
    }

    @Test func globalWUsesTheCurrentLayoutInBothConflictDirections() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(kVK_Space, forKey: "shortcutKeyCode")
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "," })
        let bindings = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: ",", modifiers: [.command, .option])])]])
        #expect(settings.applyNavigationBindings(bindings))
        settings.updateGlobal(keyCode: UInt32(kVK_ANSI_W))
        #expect(settings.keyCode == UInt32(kVK_Space))
        #expect(settings.bindingError != nil)
        #expect(settings.applyNavigationBindings(.standard))
        settings.updateGlobal(keyCode: UInt32(kVK_ANSI_W))
        #expect(settings.globalKeyStroke == KeyStroke(key: ",", modifiers: [.command, .option]))
        #expect(!settings.applyNavigationBindings(bindings))
    }

    @Test func keyboardTranslationIsRefreshedBeforeValidation() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var character = "w"
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in character })
        #expect(settings.globalKeyStroke?.key == "w")
        character = "z"
        #expect(settings.globalKeyStroke?.key == "z")
        let bindings = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "z", modifiers: [.command, .option])])]])
        #expect(!settings.applyNavigationBindings(bindings))
        let allowed = NavigationBindings(assignments: [.left: [KeySequence([KeyStroke(key: "w", modifiers: [.command, .option])])]])
        #expect(settings.applyNavigationBindings(allowed))
    }

    @Test func unavailableKeyboardTranslationDoesNotBypassValidation() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(kVK_Space, forKey: "shortcutKeyCode")
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in nil })
        settings.updateGlobal(keyCode: UInt32(kVK_ANSI_W))
        #expect(settings.keyCode == UInt32(kVK_Space))
        #expect(settings.bindingError != nil)
        defaults.set(kVK_ANSI_W, forKey: "shortcutKeyCode")
        let unavailable = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in nil })
        #expect(!unavailable.applyNavigationBindings(.vim))
        #expect(unavailable.navigationBindings == .standard)
    }

    @Test func reapplyingAPresetPublishesARecordingReset() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults, keyForVirtualKeyCode: { _ in "w" })
        var recording = NavigationKeyRecording()
        recording.strokeCount = 2
        // Rows subscribe to this publisher so even reapplying an unchanged preset resets them.
        let subscription = settings.$navigationBindings.sink { _ in recording.reset() }
        defer { subscription.cancel() }
        #expect(recording.record(KeyStroke(key: "g")) == nil)
        #expect(settings.applyNavigationBindings(.standard))
        #expect(recording.strokes.isEmpty)
        #expect(recording.record(KeyStroke(key: "h")) == nil)
        #expect(settings.applyNavigationBindings(.vim))
        #expect(recording.strokes.isEmpty)
        #expect(recording.record(KeyStroke(key: "j")) == nil)
    }

    @Test func activeKeyboardLayoutCanTranslateTheGlobalLetterKey() {
        #expect(KeyboardLayout.character(for: UInt16(kVK_ANSI_W))?.isEmpty == false)
    }
}
#endif
