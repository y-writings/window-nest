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
    /// Height reserved for the screen-recording notice shown above the icons. Zero when that notice is absent.
    public var permissionBannerHeight: Double
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
    public static let permissionBannerHeight = 260.0

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
        showsPermissionBanner: Bool = false,
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
        let minimumCards: Double
        let idealCards: Double
        switch content {
        case .permission:
            minimumCards = permissionBodyHeight
            idealCards = permissionBodyHeight
        case .message:
            minimumCards = messageBodyHeight
            idealCards = messageBodyHeight
        case .fullWindowList:
            minimumCards = min(160, fullWindowListBodyHeight)
            idealCards = fullWindowListBodyHeight
        case .icons:
            if revealed {
                let minimumList = min(naturalList, windowRowHeight)
                minimumCards = iconSize + stackSpacing + minimumList
                idealCards = iconSize + stackSpacing + naturalList
            } else {
                minimumCards = iconSize
                idealCards = iconSize
            }
        }
        let bannerWanted = showsPermissionBanner && content != .permission
        var bannerHeight = bannerWanted ? permissionBannerHeight : 0
        var cardsHeight = idealCards
        func total(banner: Double, cards: Double) -> Double {
            reservedHeight + (banner > 0 ? stackSpacing : 0) + banner + cards
        }
        if total(banner: bannerHeight, cards: cardsHeight) > maxPanelHeight {
            let roomForCards = maxPanelHeight - reservedHeight - (bannerHeight > 0 ? stackSpacing + bannerHeight : 0)
            if roomForCards >= minimumCards {
                cardsHeight = min(idealCards, roomForCards)
            } else {
                cardsHeight = min(idealCards, minimumCards)
                bannerHeight = max(0, maxPanelHeight - reservedHeight - stackSpacing - cardsHeight)
                let room = maxPanelHeight - reservedHeight - (bannerHeight > 0 ? stackSpacing + bannerHeight : 0)
                cardsHeight = min(cardsHeight, max(0, room))
            }
        }
        let windowListHeight = revealed ? max(0, cardsHeight - iconSize - stackSpacing) : 0
        let panelHeight = min(maxPanelHeight, total(banner: bannerHeight, cards: cardsHeight))

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
            windowListHeight: windowListHeight,
            windowRowHeight: windowRowHeight,
            permissionBannerHeight: bannerHeight,
            iconRowScrollsHorizontally: false
        )
    }
}

public struct PanelRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public enum PanelPlacement {
    /// Keeps the panel's top edge while it grows, then shifts it so the whole frame stays inside `visible`.
    public static func frame(current: PanelRect, width: Double, height: Double, visible: PanelRect?) -> PanelRect {
        var width = max(0, width)
        var height = max(0, height)
        if let visible {
            width = min(width, visible.width)
            height = min(height, visible.height)
        }
        let widthChanged = abs(current.width - width) >= 0.5
        var x = widthChanged ? current.x + current.width / 2 - width / 2 : current.x
        var y = current.maxY - height
        if let visible {
            if x < visible.x { x = visible.x }
            if x + width > visible.maxX { x = visible.maxX - width }
            if y < visible.y { y = visible.y }
            if y + height > visible.maxY { y = visible.maxY - height }
        }
        return PanelRect(x: x, y: y, width: width, height: height)
    }
}
