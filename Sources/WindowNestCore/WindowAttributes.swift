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
        let geometryMatches = candidates.indices.filter { candidates[$0].frame == frame }
        // CGWindow and Accessibility titles are supplied independently. Some applications
        // (including Chromium-based ones) decorate them differently, so geometry is sufficient
        // when it identifies exactly one window. Titles only disambiguate shared geometry.
        if geometryMatches.count == 1 {
            let candidateTitle = candidates[geometryMatches[0]].title
            // An empty title is real identity evidence for a titleless window, not the same as an
            // unavailable title. Do not confuse it with a named window at the same geometry.
            if title == "" || candidateTitle == "" {
                return title == nil || candidateTitle == nil || title == candidateTitle
                    ? geometryMatches[0] : nil
            }
            return geometryMatches[0]
        }
        let titleMatches = geometryMatches.filter { index in
            title == nil || candidates[index].title == nil || title == candidates[index].title
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }
}
