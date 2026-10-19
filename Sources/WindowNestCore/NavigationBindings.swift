import Foundation

public enum NavigationAction: String, CaseIterable, Codable, Sendable {
    case left, down, up, right, rowStart, rowEnd, listStart, listEnd
    public var command: NavigationCommand {
        switch self {
        case .left: .moveLeft
        case .down: .moveDown
        case .up: .moveUp
        case .right: .moveRight
        case .rowStart: .moveToRowStart
        case .rowEnd: .moveToRowEnd
        case .listStart: .moveToListStart
        case .listEnd: .moveToListEnd
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public struct KeyStroke: Codable, Hashable, Sendable, CustomStringConvertible {
    public let key: String
    public let modifiers: KeyModifiers
    public init(key: String, modifiers: KeyModifiers = []) {
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
            self.key = key.lowercased(); self.modifiers = modifiers.union(.shift)
        } else { self.key = key; self.modifiers = modifiers }
    }
    public var description: String {
        let values: [(KeyModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return values.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }
}

public struct KeySequence: Codable, Hashable, Sendable, CustomStringConvertible {
    public let strokes: [KeyStroke]
    public init(_ strokes: [KeyStroke]) { self.strokes = strokes }
    public var description: String { strokes.map(\.description).joined(separator: " ") }
}

public struct NavigationBindings: Codable, Equatable, Sendable {
    public var assignments: [NavigationAction: [KeySequence]]
    public init(assignments: [NavigationAction: [KeySequence]] = [:]) { self.assignments = assignments }
    public static let standard = Self()
    public static let vim = Self(assignments: [
        .left: [KeySequence([KeyStroke(key: "h")])], .down: [KeySequence([KeyStroke(key: "j")])],
        .up: [KeySequence([KeyStroke(key: "k")])], .right: [KeySequence([KeyStroke(key: "l")])],
        .rowStart: [KeySequence([KeyStroke(key: "0")])], .rowEnd: [KeySequence([KeyStroke(key: "$", modifiers: .shift)])],
        .listStart: [KeySequence([KeyStroke(key: "g"), KeyStroke(key: "g")])],
        .listEnd: [KeySequence([KeyStroke(key: "g", modifiers: .shift)])],
    ])
}

public enum BindingConflict: Error, Equatable, CustomStringConvertible {
    case invalidLength, reserved(KeyStroke), globalShortcut(KeyStroke)
    case duplicate(KeySequence, NavigationAction), ambiguousPrefix(KeySequence, NavigationAction)
    public var description: String {
        switch self {
        case .invalidLength: "A binding must contain one or two non-modifier keystrokes."
        case .reserved(let key): "\(key) is reserved for a built-in action."
        case .globalShortcut(let key): "\(key) is the WindowNest global shortcut."
        case .duplicate(let sequence, let action): "\(sequence) is already assigned to \(action.rawValue)."
        case .ambiguousPrefix(let sequence, let action): "\(sequence) conflicts with the prefix assigned to \(action.rawValue)."
        }
    }
}

public enum NavigationBindingValidator {
    public static let reservedKeys: Set<String> = ["left", "right", "up", "down", "return", "keypadEnter", "escape", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    public static func validate(_ bindings: NavigationBindings, globalShortcut: KeyStroke? = nil) -> BindingConflict? {
        var seen: [(KeySequence, NavigationAction)] = []
        for action in NavigationAction.allCases {
            for sequence in bindings.assignments[action] ?? [] {
                guard (1...2).contains(sequence.strokes.count), sequence.strokes.allSatisfy({ !$0.key.isEmpty }) else { return .invalidLength }
                if let stroke = sequence.strokes.first(where: { $0.modifiers.isEmpty && reservedKeys.contains($0.key) }) { return .reserved(stroke) }
                if let globalShortcut, let stroke = sequence.strokes.first(where: { $0 == globalShortcut }) { return .globalShortcut(stroke) }
                for (other, otherAction) in seen {
                    if sequence == other { return .duplicate(sequence, otherAction) }
                    if sequence.strokes.starts(with: other.strokes) || other.strokes.starts(with: sequence.strokes) { return .ambiguousPrefix(sequence, otherAction) }
                }
                seen.append((sequence, action))
            }
        }
        return nil
    }
}

public struct NavigationKeyMatcher: Sendable {
    public static let timeout: TimeInterval = 1
    private var bindings: NavigationBindings
    private var pending: (stroke: KeyStroke, time: TimeInterval)?
    public init(bindings: NavigationBindings) { self.bindings = bindings }
    public mutating func update(_ bindings: NavigationBindings) { self.bindings = bindings; reset() }
    public mutating func reset() { pending = nil }
    public mutating func match(_ stroke: KeyStroke, at time: TimeInterval, isRepeat: Bool = false) -> NavigationCommand? {
        if let pending {
            self.pending = nil
            if time - pending.time <= Self.timeout, !isRepeat, let action = action(for: [pending.stroke, stroke]) { return action.command }
        }
        if let action = action(for: [stroke]) { return action.command }
        if !isRepeat, hasPrefix(stroke) { pending = (stroke, time) }
        return nil
    }
    private func action(for strokes: [KeyStroke]) -> NavigationAction? {
        NavigationAction.allCases.first { bindings.assignments[$0]?.contains(KeySequence(strokes)) == true }
    }
    private func hasPrefix(_ stroke: KeyStroke) -> Bool {
        bindings.assignments.values.joined().contains { $0.strokes.count == 2 && $0.strokes[0] == stroke }
    }
}

public final class NavigationBindingsStore: @unchecked Sendable {
    private let defaults: UserDefaults; private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "navigationBindings") { self.defaults = defaults; self.key = key }
    public func load() -> NavigationBindings {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(NavigationBindings.self, from: data), NavigationBindingValidator.validate(value) == nil else { return .standard }
        return value
    }
    public func save(_ value: NavigationBindings) throws {
        if let conflict = NavigationBindingValidator.validate(value) { throw conflict }
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
