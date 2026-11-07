#if os(macOS)
import AppKit
import Testing
import WindowNestCore
@testable import WindowNest

private let minimizedFrame = CGRect(x: 0, y: 0, width: 800, height: 600)

private func window(_ number: UInt32, frame: CGRect, onScreen: Bool) -> MacWindowSystem.WindowDescription {
    MacWindowSystem.WindowDescription(
        id: WindowID(processIdentifier: 1, windowNumber: number),
        attributes: WindowAttributes(title: "Document", frame: frame),
        isOnScreen: onScreen
    )
}

@Test func listsMinimizedWindowsWithoutOffscreenApplicationInternals() {
    let visible = window(1, frame: CGRect(x: 20, y: 20, width: 800, height: 600), onScreen: true)
    let minimized = window(2, frame: minimizedFrame, onScreen: false)
    let internalWindow = window(3, frame: CGRect(x: 0, y: 0, width: 800, height: 30), onScreen: false)

    let listed = MacWindowSystem.listedWindows([visible, minimized, internalWindow], minimized: [minimized.attributes])

    #expect(listed.map(\.id) == [visible.id, minimized.id])
    #expect(MacWindowSystem.listedWindows([minimized], minimized: [minimized.attributes]).map(\.id) == [minimized.id])
}

@Test func excludesOffscreenWindowsWithoutMinimizedEvidence() {
    let hidden = window(1, frame: minimizedFrame, onScreen: false)
    #expect(MacWindowSystem.listedWindows([hidden], minimized: []).isEmpty)
}

@Test func excludesAmbiguousMinimizedWindowsInEitherDirection() {
    let first = window(1, frame: minimizedFrame, onScreen: false)
    let second = window(2, frame: minimizedFrame, onScreen: false)
    #expect(MacWindowSystem.listedWindows([first, second], minimized: [first.attributes]).isEmpty)
    #expect(MacWindowSystem.listedWindows([first], minimized: [first.attributes, first.attributes]).isEmpty)
    let visible = window(3, frame: minimizedFrame, onScreen: true)
    #expect(MacWindowSystem.listedWindows([visible, first], minimized: [first.attributes]).map(\.id) == [visible.id])
}
#endif
