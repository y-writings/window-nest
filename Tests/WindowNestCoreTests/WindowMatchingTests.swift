import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import WindowNestCore

private let firstFrame = CGRect(x: 10, y: 20, width: 640, height: 480)
private let secondFrame = CGRect(x: 100, y: 200, width: 640, height: 480)

@Test(arguments: ["Document", ""])
func matchesTheSelectedWindowInsteadOfTheFirstCandidate(title: String) {
    let target = WindowAttributes(title: title, frame: secondFrame)
    let candidates = [
        WindowAttributes(title: title, frame: firstFrame),
        WindowAttributes(title: title, frame: secondFrame),
    ]
    #expect(target.uniqueMatch(in: candidates) == 1)
}

@Test(arguments: [(nil, "Document"), ("Document", nil), (nil, "")] as [(String?, String?)])
func matchesByGeometryWhenATitleIsUnavailable(titles: (String?, String?)) {
    let target = WindowAttributes(title: titles.0, frame: secondFrame)
    let candidates = [
        WindowAttributes(title: "Unrelated", frame: firstFrame),
        WindowAttributes(title: titles.1, frame: secondFrame),
    ]
    #expect(target.uniqueMatch(in: candidates) == 1)
}

@Test func doesNotTreatTheDisplayPlaceholderAsAnUntitledIdentity() {
    let target = WindowAttributes(title: "", frame: secondFrame)
    #expect(target.uniqueMatch(in: [WindowAttributes(title: "Untitled Window", frame: secondFrame)]) == nil)
}

@Test func acceptsDifferentTitlesWhenGeometryIsUnique() {
    let target = WindowAttributes(title: "CG title", frame: secondFrame)
    let candidates = [WindowAttributes(title: "Accessibility title — Dia", frame: secondFrame)]
    #expect(target.uniqueMatch(in: candidates) == 0)
}

@Test func usesTitlesToDisambiguateSharedGeometry() {
    let target = WindowAttributes(title: "Selected", frame: secondFrame)
    let candidates = [
        WindowAttributes(title: "Other", frame: secondFrame),
        WindowAttributes(title: "Selected", frame: secondFrame),
    ]
    #expect(target.uniqueMatch(in: candidates) == 1)
}

@Test func refusesMissingIdentityEvidence() {
    let target = WindowAttributes(title: "Selected", frame: secondFrame)
    #expect(target.uniqueMatch(in: []) == nil)
    #expect(target.uniqueMatch(in: [WindowAttributes(title: "Selected", frame: firstFrame)]) == nil)
    #expect(target.uniqueMatch(in: [WindowAttributes(title: "Selected", frame: nil)]) == nil)
    #expect(WindowAttributes(title: "Selected", frame: nil).uniqueMatch(in: [target]) == nil)
}

@Test func refusesIndistinguishableCandidatesInEitherDirection() {
    let target = WindowAttributes(title: nil, frame: secondFrame)
    let candidate = WindowAttributes(title: "Document", frame: secondFrame)
    #expect(target.uniqueMatch(in: [candidate, candidate]) == nil)
    #expect(candidate.uniqueMatch(in: [target, target]) == nil)
}
