import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct WindowAttributes: Equatable, Sendable {
    // Keep raw titles: nil is unavailable; an empty string is a titleless window.
    public let title: String?
    public let frame: CGRect?

    public init(title: String?, frame: CGRect?) {
        self.title = title
        self.frame = frame
    }

    public func uniqueMatch(in candidates: [WindowAttributes]) -> Int? {
        guard let frame else { return nil }
        let matches = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.frame == frame
                && (title == nil || candidate.title == nil || title == candidate.title)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
