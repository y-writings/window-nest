import Foundation

public struct BrowserState: Equatable, Sendable {
    public private(set) var applications: [ApplicationItem]
    public private(set) var searchQuery = ""
    public private(set) var searchMode: ApplicationSearchMode
    public private(set) var screen: BrowserScreen = .applications
    public private(set) var selectedIndex = 0
    public var columnCount: Int

    public init(applications: [ApplicationItem] = [], columnCount: Int = 3, searchMode: ApplicationSearchMode = .fuzzy) {
        self.applications = applications
        self.searchMode = searchMode
        self.columnCount = max(columnCount, 1)
        clampSelection()
    }

    public var selectedApplication: ApplicationItem? {
        switch screen {
        case .applications: return visibleApplications[safe: selectedIndex]
        case .windows(let id): return applications.first { $0.id == id }
        }
    }


    public var visibleApplications: [ApplicationItem] {
        ApplicationSearch.results(in: applications, query: searchQuery, mode: searchMode)
    }

    public mutating func updateSearchQuery(_ query: String) {
        searchQuery = query
        if case .applications = screen { selectedIndex = 0 }
    }

    public mutating func updateSearchMode(_ mode: ApplicationSearchMode) {
        searchMode = mode
        if case .applications = screen { selectedIndex = 0 }
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
                selectedIndex = visibleApplications.firstIndex { $0.id == selectedApplicationID } ?? 0
                clampSelection()
                return
            }
            selectedIndex = app.windows.firstIndex { $0.id == selectedWindowID } ?? min(selectedIndex, app.windows.count - 1)
        } else {
            selectedIndex = visibleApplications.firstIndex { $0.id == selectedApplicationID } ?? 0
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
                guard let application = visibleApplications[safe: selectedIndex] else { return .none }
                switch application.windows.count {
                case 0:
                    return .none
                case 1:
                    return .activate(application.windows[0].id)
                default:
                    screen = .windows(applicationID: application.id)
                    selectedIndex = 0
                }
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
                selectedIndex = visibleApplications.firstIndex { $0.id == id } ?? 0
            } else {
                return .dismiss
            }
        }
        return .none
    }

    private var itemCount: Int {
        if case .applications = screen { return visibleApplications.count }
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

public enum ApplicationSearch {
    public static func results(in applications: [ApplicationItem], query: String, mode: ApplicationSearchMode) -> [ApplicationItem] {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return applications }

        switch mode {
        case .prefix:
            return applications.filter { normalized($0.name).hasPrefix(needle) }
        case .fuzzy:
            return applications.enumerated().compactMap { index, application -> (Int, Int, ApplicationItem)? in
                guard let rank = fuzzyRank(name: normalized(application.name), query: needle) else { return nil }
                return (rank, index, application)
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: .current)
    }

    private static func fuzzyRank(name: String, query: String) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.range(of: query) != nil { return 2 }
        var remainder = query[...]
        for character in name where !remainder.isEmpty {
            if character == remainder.first { remainder.removeFirst() }
        }
        return remainder.isEmpty ? 3 : nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
