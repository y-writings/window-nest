import Foundation

public struct BrowserState: Equatable, Sendable {
    public private(set) var applications: [ApplicationItem]
    public private(set) var searchQuery = ""
    public private(set) var searchMode: ApplicationSearchMode
    public private(set) var screen: BrowserScreen = .applications
    public private(set) var selectedIndex = 0
    /// When true on the applications screen, that app's windows are listed under its icon.
    public private(set) var windowsRevealed = false
    public private(set) var selectedWindowIndex = 0

    public init(applications: [ApplicationItem] = [], searchMode: ApplicationSearchMode = .fuzzy) {
        self.applications = applications
        self.searchMode = searchMode
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
        if case .applications = screen {
            selectedIndex = 0
            hideRevealedWindows()
        }
    }

    public mutating func updateSearchMode(_ mode: ApplicationSearchMode) {
        searchMode = mode
        if case .applications = screen {
            selectedIndex = 0
            hideRevealedWindows()
        }
    }

    public var visibleWindows: [WindowItem] {
        switch screen {
        case .windows(let id):
            return applications.first { $0.id == id }?.windows ?? []
        case .applications:
            guard windowsRevealed, let application = selectedApplication else { return [] }
            return application.windows
        }
    }

    public mutating func replaceApplications(_ newValue: [ApplicationItem]) {
        let selectedApplicationID = selectedApplication?.id
        let windowIndex = screen == .applications ? selectedWindowIndex : selectedIndex
        let selectedWindowID = visibleWindows[safe: windowIndex]?.id
        let revealed = windowsRevealed
        applications = newValue

        switch screen {
        case .windows(let id):
            guard let app = applications.first(where: { $0.id == id }), !app.windows.isEmpty else {
                screen = .applications
                hideRevealedWindows()
                selectedIndex = visibleApplications.firstIndex { $0.id == selectedApplicationID } ?? 0
                clampSelection()
                return
            }
            selectedIndex = app.windows.firstIndex { $0.id == selectedWindowID } ?? min(selectedIndex, app.windows.count - 1)
        case .applications:
            let keptApplication = visibleApplications.contains { $0.id == selectedApplicationID }
            selectedIndex = visibleApplications.firstIndex { $0.id == selectedApplicationID } ?? 0
            windowsRevealed = revealed && keptApplication
            guard windowsRevealed, let app = selectedApplication, !app.windows.isEmpty else {
                hideRevealedWindows()
                break
            }
            selectedWindowIndex = app.windows.firstIndex { $0.id == selectedWindowID }
                ?? min(selectedWindowIndex, app.windows.count - 1)
        }
        clampSelection()
    }

    @discardableResult
    public mutating func handle(_ command: NavigationCommand) -> BrowserEffect {
        switch command {
        case .moveLeft: moveSelection(by: -1)
        case .moveRight: moveSelection(by: 1)
        case .moveToListStart: moveSelection(toEnd: false)
        case .moveToListEnd: moveSelection(toEnd: true)
        case .revealWindows:
            guard case .applications = screen,
                  let application = visibleApplications[safe: selectedIndex],
                  !application.windows.isEmpty else { return .none }
            if windowsRevealed {
                selectedWindowIndex = min(selectedWindowIndex + 1, application.windows.count - 1)
            } else {
                windowsRevealed = true
                selectedWindowIndex = 0
            }
        case .concealWindows:
            guard case .applications = screen, windowsRevealed else { return .none }
            if selectedWindowIndex > 0 {
                selectedWindowIndex -= 1
            } else {
                hideRevealedWindows()
            }
        case .confirm:
            if case .applications = screen {
                if windowsRevealed {
                    guard let window = visibleWindows[safe: selectedWindowIndex] else { return .none }
                    return .activate(window.id)
                }
                guard let application = visibleApplications[safe: selectedIndex] else { return .none }
                switch application.windows.count {
                case 0:
                    return .none
                case 1:
                    return .activate(application.windows[0].id)
                default:
                    openFullWindowList(application, selectedWindow: 0)
                }
            } else if let window = visibleWindows[safe: selectedIndex] {
                return .activate(window.id)
            }
        case .chooseNumber(let number):
            guard (1...9).contains(number), let window = visibleWindows[safe: number - 1] else { return .none }
            if case .applications = screen {
                guard windowsRevealed else { return .none }
                selectedWindowIndex = number - 1
            } else {
                selectedIndex = number - 1
            }
            return .activate(window.id)
        case .showWindows:
            guard case .applications = screen,
                  let application = visibleApplications[safe: selectedIndex],
                  !application.windows.isEmpty else { return .none }
            let index = windowsRevealed ? selectedWindowIndex : 0
            openFullWindowList(application, selectedWindow: index)
        case .terminateApplication:
            guard case .applications = screen,
                  let application = visibleApplications[safe: selectedIndex] else { return .none }
            return .terminateApplication(application.id)
        case .closeWindow:
            let index = screen == .applications ? selectedWindowIndex : selectedIndex
            guard screen != .applications || windowsRevealed,
                  let window = visibleWindows[safe: index] else { return .none }
            return .closeWindow(window.id)
        case .escape:
            if case .windows(let id) = screen {
                screen = .applications
                hideRevealedWindows()
                selectedIndex = visibleApplications.firstIndex { $0.id == id } ?? 0
            } else if windowsRevealed {
                hideRevealedWindows()
            } else {
                return .dismiss
            }
        }
        return .none
    }

    private mutating func openFullWindowList(_ application: ApplicationItem, selectedWindow: Int) {
        hideRevealedWindows()
        screen = .windows(applicationID: application.id)
        selectedIndex = min(max(selectedWindow, 0), max(0, application.windows.count - 1))
    }

    private mutating func hideRevealedWindows() {
        windowsRevealed = false
        selectedWindowIndex = 0
    }

    private mutating func moveSelection(by delta: Int) {
        if case .applications = screen {
            let before = selectedIndex
            move(by: delta, count: visibleApplications.count)
            retargetRevealedWindows(from: before)
        } else {
            move(by: delta, count: visibleWindows.count)
        }
    }

    private mutating func moveSelection(toEnd: Bool) {
        if case .applications = screen {
            let before = selectedIndex
            let count = visibleApplications.count
            move(to: toEnd ? count - 1 : 0, count: count)
            retargetRevealedWindows(from: before)
        } else {
            let count = visibleWindows.count
            move(to: toEnd ? count - 1 : 0, count: count)
        }
    }

    private mutating func retargetRevealedWindows(from previousIndex: Int) {
        guard windowsRevealed, selectedIndex != previousIndex else { return }
        if selectedApplication?.windows.isEmpty == false {
            selectedWindowIndex = 0
        } else {
            hideRevealedWindows()
        }
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
        let windowCount = selectedApplication?.windows.count ?? 0
        selectedWindowIndex = windowCount == 0 ? 0 : min(max(selectedWindowIndex, 0), windowCount - 1)
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
