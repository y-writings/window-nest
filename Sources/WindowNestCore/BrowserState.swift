import Foundation

public struct BrowserState: Equatable, Sendable {
    public private(set) var applications: [ApplicationItem]
    public private(set) var screen: BrowserScreen = .applications
    public private(set) var selectedIndex = 0
    public var columnCount: Int

    public init(applications: [ApplicationItem] = [], columnCount: Int = 3) {
        self.applications = applications
        self.columnCount = max(columnCount, 1)
        clampSelection()
    }

    public var selectedApplication: ApplicationItem? {
        switch screen {
        case .applications: return applications[safe: selectedIndex]
        case .windows(let id): return applications.first { $0.id == id }
        }
    }

    public var visibleWindows: [WindowItem] {
        guard case .windows(let id) = screen else { return [] }
        return applications.first { $0.id == id }?.windows ?? []
    }

    public mutating func replaceApplications(_ newValue: [ApplicationItem]) {
        let selectedApplicationID = selectedApplication?.id
        let selectedWindowID = visibleWindows[safe: selectedIndex]?.id
        applications = newValue

        if case .windows(let id) = screen {
            guard let app = applications.first(where: { $0.id == id }), !app.windows.isEmpty else {
                screen = .applications
                selectedIndex = applications.firstIndex { $0.id == selectedApplicationID } ?? 0
                clampSelection()
                return
            }
            selectedIndex = app.windows.firstIndex { $0.id == selectedWindowID } ?? min(selectedIndex, app.windows.count - 1)
        } else {
            selectedIndex = applications.firstIndex { $0.id == selectedApplicationID } ?? min(selectedIndex, max(0, applications.count - 1))
        }
    }

    @discardableResult
    public mutating func handle(_ command: NavigationCommand) -> BrowserEffect {
        let count = itemCount
        switch command {
        case .moveLeft: move(by: -1, count: count)
        case .moveRight: move(by: 1, count: count)
        case .moveUp: move(by: -columnCount, count: count)
        case .moveDown: move(by: columnCount, count: count)
        case .moveToRowStart:
            move(to: (selectedIndex / columnCount) * columnCount, count: count)
        case .moveToRowEnd:
            move(to: min(((selectedIndex / columnCount) + 1) * columnCount - 1, count - 1), count: count)
        case .moveToListStart: move(to: 0, count: count)
        case .moveToListEnd: move(to: count - 1, count: count)
        case .confirm:
            if case .applications = screen {
                guard let application = applications[safe: selectedIndex] else { return .none }
                screen = .windows(applicationID: application.id)
                selectedIndex = 0
            } else if let window = visibleWindows[safe: selectedIndex] {
                return .activate(window.id)
            }
        case .chooseNumber(let number):
            guard case .windows = screen, (1...9).contains(number), let window = visibleWindows[safe: number - 1] else { return .none }
            selectedIndex = number - 1
            return .activate(window.id)
        case .escape:
            if case .windows(let id) = screen {
                screen = .applications
                selectedIndex = applications.firstIndex { $0.id == id } ?? 0
            } else {
                return .dismiss
            }
        }
        return .none
    }

    private var itemCount: Int {
        if case .applications = screen { return applications.count }
        return visibleWindows.count
    }

    private mutating func move(by delta: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private mutating func move(to index: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(index, 0), count - 1)
    }

    private mutating func clampSelection() {
        selectedIndex = min(max(selectedIndex, 0), max(0, itemCount - 1))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
