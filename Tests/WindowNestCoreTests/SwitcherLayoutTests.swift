import Foundation
import Testing
@testable import WindowNestCore

@Test(arguments: [1, 3, 8, 12, 24, 40])
func everyIconFitsInOneRowWithoutHorizontalScrolling(appCount: Int) {
    for maxWidth in [800.0, 1120.0, 1440.0, 1920.0] {
        let layout = SwitcherLayout.make(
            appCount: appCount, selectedIndex: appCount - 1, windowCount: 0,
            windowsRevealed: false, content: .icons,
            maxPanelWidth: maxWidth, maxPanelHeight: 1000
        )
        #expect(!layout.iconRowScrollsHorizontally)
        #expect(layout.panelWidth <= maxWidth.rounded(.down))
        #expect(layout.iconRowOrigin >= -0.001)
        #expect(layout.lastIconMaxX <= layout.contentWidth + 0.001)
        #expect(layout.iconSize > 0)
        let preferredRow = SwitcherLayout.preferredIconSize * Double(appCount)
            + SwitcherLayout.preferredIconSpacing * Double(appCount - 1)
        if preferredRow + SwitcherLayout.outerPadding * 2 > maxWidth.rounded(.down) {
            #expect(abs(layout.lastIconMaxX - layout.contentWidth) < 0.001)
            #expect(layout.iconSize < SwitcherLayout.preferredIconSize)
        } else {
            #expect(layout.iconSize == SwitcherLayout.preferredIconSize)
            #expect(layout.panelWidth >= min(SwitcherLayout.minimumPanelWidth, maxWidth.rounded(.down)) - 0.001)
        }
    }
}

@Test func windowColumnStaysUnderTheSelectedIconInsideThePanel() {
    let count = 8
    for index in [0, 3, count - 1] {
        let layout = SwitcherLayout.make(
            appCount: count, selectedIndex: index, windowCount: 3,
            windowsRevealed: true, content: .icons,
            maxPanelWidth: 1600, maxPanelHeight: 1000
        )
        #expect(layout.windowColumnOrigin >= -0.001)
        #expect(layout.windowColumnOrigin + layout.windowColumnWidth <= layout.contentWidth + 0.001)
        #expect(layout.selectedIconCenterX >= layout.windowColumnOrigin - 0.001)
        #expect(layout.selectedIconCenterX <= layout.windowColumnOrigin + layout.windowColumnWidth + 0.001)
        let natural = 3 * SwitcherLayout.windowRowHeight + 2 * SwitcherLayout.windowListSpacing
        #expect(layout.windowListHeight == natural)
        #expect(layout.panelHeight > SwitcherLayout.make(
            appCount: count, selectedIndex: index, windowCount: 0,
            windowsRevealed: false, content: .icons,
            maxPanelWidth: 1600, maxPanelHeight: 1000
        ).panelHeight)
    }
}

@Test func aShortScreenScrollsWindowsVerticallyAndKeepsTheIconRow() {
    let layout = SwitcherLayout.make(
        appCount: 6, selectedIndex: 1, windowCount: 12,
        windowsRevealed: true, content: .icons,
        maxPanelWidth: 1400, maxPanelHeight: 420
    )
    let natural = 12 * SwitcherLayout.windowRowHeight + 11 * SwitcherLayout.windowListSpacing
    #expect(layout.windowListHeight < natural)
    #expect(layout.windowListHeight >= SwitcherLayout.windowRowHeight)
    #expect(layout.panelHeight <= 420)
    #expect(!layout.iconRowScrollsHorizontally)
    #expect(layout.iconSize == SwitcherLayout.preferredIconSize)
}

@Test func fewApplicationsStillUseTheWidenedPanel() {
    let layout = SwitcherLayout.make(
        appCount: 2, selectedIndex: 0, windowCount: 1,
        windowsRevealed: false, content: .icons,
        maxPanelWidth: 1800, maxPanelHeight: 1000
    )
    #expect(layout.panelWidth == SwitcherLayout.minimumPanelWidth)
    #expect(layout.panelWidth > 920)
    #expect(layout.lastIconMaxX < layout.contentWidth)
    #expect(layout.iconRowOrigin > 0)
}
