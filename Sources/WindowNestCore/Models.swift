import Foundation

public struct WindowID: Hashable, Sendable, Codable {
    public let processIdentifier: Int32
    public let windowNumber: UInt32

    public init(processIdentifier: Int32, windowNumber: UInt32) {
        self.processIdentifier = processIdentifier
        self.windowNumber = windowNumber
    }
}

public struct WindowItem: Identifiable, Hashable, Sendable {
    public let id: WindowID
    public let title: String

    public init(id: WindowID, title: String) {
        self.id = id
        self.title = title.isEmpty ? "Untitled Window" : title
    }
}

public struct ApplicationItem: Identifiable, Hashable, Sendable {
    public let id: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let windows: [WindowItem]

    public init(id: Int32, name: String, bundleIdentifier: String? = nil, windows: [WindowItem]) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.windows = windows
    }
}

public enum ApplicationSearchMode: String, CaseIterable, Codable, Sendable {
    case fuzzy
    case prefix
}

public struct ApplicationSearchModeStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "applicationSearchMode") {
        self.defaults = defaults
        self.key = key
    }

    public var value: ApplicationSearchMode {
        get { defaults.string(forKey: key).flatMap(ApplicationSearchMode.init(rawValue:)) ?? .fuzzy }
        nonmutating set { defaults.set(newValue.rawValue, forKey: key) }
    }
}

public enum PermissionState: Equatable, Sendable {
    case ready
    case accessibilityRequired
    case screenRecordingRequired
    case bothRequired
}

public enum BrowserScreen: Hashable, Sendable {
    case applications
    case windows(applicationID: Int32)
}

public enum NavigationCommand: Equatable, Sendable {
    case moveLeft, moveRight, moveUp, moveDown, confirm, escape
    case chooseNumber(Int)
}

public enum BrowserEffect: Equatable, Sendable {
    case none
    case dismiss
    case refresh
    case activate(WindowID)
}
