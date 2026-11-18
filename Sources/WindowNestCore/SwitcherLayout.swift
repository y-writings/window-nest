import Foundation

/// Geometry for the application switcher panel.
///
/// Every visible application icon is placed in one horizontal row. The panel
/// grows up to the available screen width and, past that, the icons shrink so
/// the row never scrolls horizontally.
public struct SwitcherLayout: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case icons
        case fullWindowList
        case message
        case permission
    }

    public var panelWidth: Double
    public var panelHeight: Double
    public var contentWidth: Double
    public var iconSize: Double
    public var iconSpacing: Double
    public var iconRowOrigin: Double
    public var iconRowWidth: Double
    public var selectedIconCenterX: Double
    public var windowColumnOrigin: Double
    public var windowColumnWidth: Double
    public var windowListHeight: Double
    public var windowRowHeight: Double
    /// Always false. Icons are scaled into the panel instead of being scrolled.
    public var iconRowScrollsHorizontally: Bool

    public static let outerPadding = 20.0
    public static let stackSpacing = 12.0
    public static let dragHandleHeight = 24.0
    public static let headerHeight = 44.0
    public static let footerHeight = 22.0
    public static let preferredIconSize = 68.0
    public static let preferredIconSpacing = 18.0
    public static let minimumPanelWidth = 1120.0
    public static let windowColumnPreferredWidth = 300.0
    public static let windowRowHeight = 84.0
    public static let windowListSpacing = 8.0
    public static let fullWindowListBodyHeight = 260.0
    public static let messageBodyHeight = 200.0
    public static let permissionBodyHeight = 460.0

    public static var reservedHeight: Double {
        outerPadding * 2 + dragHandleHeight + headerHeight + footerHeight + stackSpacing * 3
    }

    public var lastIconMaxX: Double { iconRowOrigin + iconRowWidth }

    public static func make(
        appCount: Int,
        selectedIndex: Int,
        windowCount: Int,
        windowsRevealed: Bool,
        content: Content,
        maxPanelWidth: Double,
        maxPanelHeight: Double
    ) -> SwitcherLayout {
        let maxPanelWidth = max(480, maxPanelWidth).rounded(.down)
        let maxPanelHeight = max(320, maxPanelHeight).rounded(.down)
        let chromeX = outerPadding * 2
        let minimumWidth = min(minimumPanelWidth, maxPanelWidth)
        let count = max(0, appCount)

        var iconSize = preferredIconSize
        var spacing = preferredIconSpacing
        var rowWidth = 0.0
        if count > 0 {
            rowWidth = preferredIconSize * Double(count) + preferredIconSpacing * Double(count - 1)
            if rowWidth + chromeX > maxPanelWidth {
                let available = max(1, maxPanelWidth - chromeX)
                let scale = available / rowWidth
                iconSize = preferredIconSize * scale
                spacing = preferredIconSpacing * scale
                rowWidth = available
            }
        }

        let naturalWidth = rowWidth + chromeX
        let panelWidth = count == 0 ? minimumWidth : min(maxPanelWidth, max(naturalWidth, minimumWidth))
        let contentWidth = max(0, panelWidth - chromeX)
        let iconRowOrigin = max(0, (contentWidth - rowWidth) / 2)
        let index = count == 0 ? 0 : min(max(selectedIndex, 0), count - 1)
        let selectedIconCenterX = count == 0
            ? contentWidth / 2
            : iconRowOrigin + (iconSize + spacing) * Double(index) + iconSize / 2
        let windowColumnWidth = min(windowColumnPreferredWidth, contentWidth)
        var windowColumnOrigin = selectedIconCenterX - windowColumnWidth / 2
        windowColumnOrigin = min(max(0, windowColumnOrigin), max(0, contentWidth - windowColumnWidth))

        let revealed = windowsRevealed && windowCount > 0 && content == .icons
        let naturalList = Double(max(0, windowCount)) * windowRowHeight
            + Double(max(0, windowCount - 1)) * windowListSpacing
        var windowListHeight = 0.0
        let bodyHeight: Double
        if content == .permission {
            bodyHeight = permissionBodyHeight
        } else if content == .message {
            bodyHeight = messageBodyHeight
        } else if content == .fullWindowList {
            bodyHeight = fullWindowListBodyHeight
        } else if revealed {
            let available = maxPanelHeight - reservedHeight - iconSize - stackSpacing
            windowListHeight = min(naturalList, max(windowRowHeight, available))
            bodyHeight = iconSize + stackSpacing + windowListHeight
        } else {
            bodyHeight = iconSize
        }
        let panelHeight = min(maxPanelHeight, reservedHeight + bodyHeight)

        return SwitcherLayout(
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            contentWidth: contentWidth,
            iconSize: iconSize,
            iconSpacing: spacing,
            iconRowOrigin: iconRowOrigin,
            iconRowWidth: rowWidth,
            selectedIconCenterX: selectedIconCenterX,
            windowColumnOrigin: windowColumnOrigin,
            windowColumnWidth: windowColumnWidth,
            windowListHeight: revealed ? windowListHeight : 0,
            windowRowHeight: windowRowHeight,
            iconRowScrollsHorizontally: false
        )
    }
}
