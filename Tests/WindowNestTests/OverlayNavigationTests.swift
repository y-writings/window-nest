#if os(macOS)
import AppKit
import Carbon
import Testing
import WindowNestCore
@testable import WindowNest

@Suite @MainActor
struct OverlayNavigationTests {
    private func key(_ characters: String, code: Int, modifiers: NSEvent.ModifierFlags = [],
                     at timestamp: TimeInterval = 0, repeat isRepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: timestamp, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: UInt16(code)))
    }

    @Test func searchTypingTakesPriorityAndDiscardsPendingNavigation() throws {
        let editor = NSTextView()
        var bindings = NavigationBindings.vim
        bindings.assignments[.left, default: []].append(KeySequence([KeyStroke(key: "h", modifiers: .control)]))
        let events = [
            try key("h", code: kVK_ANSI_H),
            try key("G", code: kVK_ANSI_G, modifiers: .shift),
            try key("g", code: kVK_ANSI_G),
            try key("0", code: kVK_ANSI_0),
            try key("1", code: kVK_ANSI_1),
            try key("h", code: kVK_ANSI_H, modifiers: .control),
        ]
        for event in events {
            var matcher = NavigationKeyMatcher(bindings: bindings)
            #expect(matcher.process(KeyStroke(key: "g"), at: 0) == .consumed)
            #expect(OverlayPanelController.match(for: event, screen: .applications,
                firstResponder: editor, matcher: &matcher) == .unhandled)
            #expect(matcher.process(KeyStroke(key: "g"), at: 0.1) == .consumed)
        }
    }

    @Test func builtInNavigationStillWorksWhileSearching() throws {
        let editor = NSTextView()
        var matcher = NavigationKeyMatcher(bindings: .vim)
        let cases: [(NSEvent, NavigationCommand)] = [
            (try key("\u{f701}", code: kVK_DownArrow), .moveDown),
            (try key("\r", code: kVK_Return), .confirm),
            (try key("\u{1b}", code: kVK_Escape), .escape),
        ]
        for (event, command) in cases {
            #expect(OverlayPanelController.match(for: event, screen: .applications,
                firstResponder: editor, matcher: &matcher) == .command(command))
        }
    }

    @Test func markedTextKeepsConfirmationAndDiscardsPendingNavigation() throws {
        let editor = NSTextView()
        editor.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        var matcher = NavigationKeyMatcher(bindings: .vim)
        #expect(matcher.process(KeyStroke(key: "g"), at: 0) == .consumed)
        let event = try key("\r", code: kVK_Return)
        #expect(OverlayPanelController.match(for: event, screen: .applications,
            firstResponder: editor, matcher: &matcher) == .unhandled)
        #expect(matcher.process(KeyStroke(key: "g"), at: 0.1) == .consumed)
    }

    @Test func destructiveShortcutsUseTranslatedCharactersAndSuppressRepeats() throws {
        var matcher = NavigationKeyMatcher(bindings: .standard)
        let quit = try key("q", code: kVK_ANSI_A, modifiers: .command)
        #expect(OverlayPanelController.match(for: quit, screen: .applications,
            firstResponder: NSTextView(), matcher: &matcher) == .command(.terminateApplication))
        let close = try key("w", code: kVK_ANSI_A, modifiers: .command)
        #expect(OverlayPanelController.match(for: close, screen: .windows(applicationID: 1),
            firstResponder: nil, matcher: &matcher) == .command(.closeWindow))
        let physicalQ = try key("a", code: kVK_ANSI_Q, modifiers: .command)
        #expect(OverlayPanelController.match(for: physicalQ, screen: .applications,
            firstResponder: nil, matcher: &matcher) == .unhandled)
        let physicalW = try key("z", code: kVK_ANSI_W, modifiers: .command)
        #expect(OverlayPanelController.match(for: physicalW, screen: .windows(applicationID: 1),
            firstResponder: nil, matcher: &matcher) == .unhandled)
        let repeated = try key("q", code: kVK_ANSI_A, modifiers: .command, repeat: true)
        #expect(OverlayPanelController.match(for: repeated, screen: .applications,
            firstResponder: nil, matcher: &matcher) == .consumed)
        #expect(OverlayPanelController.match(for: try key("w", code: kVK_ANSI_A, modifiers: .command, repeat: true),
            screen: .windows(applicationID: 1), firstResponder: nil, matcher: &matcher) == .consumed)
    }

    @Test func markedTextConsumesDestructiveShortcutsButPassesIMEConfirmation() throws {
        let editor = NSTextView()
        editor.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        var matcher = NavigationKeyMatcher(bindings: .standard)
        for event in [try key("q", code: kVK_ANSI_A, modifiers: .command),
                      try key("w", code: kVK_ANSI_A, modifiers: .command),
                      try key("q", code: kVK_ANSI_A, modifiers: .command, repeat: true)] {
            #expect(OverlayPanelController.match(for: event, screen: .applications,
                firstResponder: editor, matcher: &matcher) == .consumed)
        }
        #expect(OverlayPanelController.match(for: try key("\r", code: kVK_Return, modifiers: .command),
            screen: .applications, firstResponder: editor, matcher: &matcher) == .unhandled)
    }

    @Test func commandReturnOpensNestOnceForMainAndKeypadReturn() throws {
        var matcher = NavigationKeyMatcher(bindings: .standard)
        for code in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let event = try key("\r", code: code, modifiers: .command)
            #expect(OverlayPanelController.match(for: event, screen: .applications,
                firstResponder: nil, matcher: &matcher) == .command(.showWindows))
            let repeated = try key("\r", code: code, modifiers: .command, repeat: true)
            #expect(OverlayPanelController.match(for: repeated, screen: .applications,
                firstResponder: nil, matcher: &matcher) == .consumed)
        }
    }

    @Test(arguments: [BrowserScreen.applications, .windows(applicationID: 1)])
    func customNavigationWorksOutsideTheSearchField(screen: BrowserScreen) throws {
        var matcher = NavigationKeyMatcher(bindings: .vim)
        let left = try key("h", code: kVK_ANSI_H)
        #expect(OverlayPanelController.match(for: left, screen: screen,
            firstResponder: nil, matcher: &matcher) == .command(.moveLeft))
        let first = try key("g", code: kVK_ANSI_G, at: 1)
        let second = try key("g", code: kVK_ANSI_G, at: 1.1)
        #expect(OverlayPanelController.match(for: first, screen: screen,
            firstResponder: nil, matcher: &matcher) == .consumed)
        #expect(OverlayPanelController.match(for: second, screen: screen,
            firstResponder: nil, matcher: &matcher) == .command(.moveToListStart))
    }

    @Test func numbersSelectWindowsButRemainSearchInputInApplications() throws {
        var matcher = NavigationKeyMatcher(bindings: .vim)
        let event = try key("1", code: kVK_ANSI_1)
        #expect(OverlayPanelController.match(for: event, screen: .applications,
            firstResponder: nil, matcher: &matcher) == .unhandled)
        #expect(OverlayPanelController.match(for: event, screen: .windows(applicationID: 1),
            firstResponder: nil, matcher: &matcher) == .command(.chooseNumber(1)))
    }
}
#endif
