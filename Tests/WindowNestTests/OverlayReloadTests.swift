#if os(macOS)
import AppKit
import Testing
import WindowNestCore
@testable import WindowNest

@Test(.timeLimit(.minutes(1))) @MainActor
func olderReloadCannotReplaceNewerSnapshot() async throws {
    let app = NSRunningApplication.current
    let pid = app.processIdentifier
    let current = ApplicationItem(id: pid, name: "Current", windows: [
        WindowItem(id: WindowID(processIdentifier: pid, windowNumber: 1), title: "Current")
    ])
    let old = ApplicationItem(id: pid + 1, name: "Old", windows: [
        WindowItem(id: WindowID(processIdentifier: pid + 1, windowNumber: 2), title: "Old")
    ])
    let newest = MacWindowSystem.Snapshot(applications: [current], icons: [:], permission: .ready,
                                          runningApplications: [pid: app])
    let stale = MacWindowSystem.Snapshot(applications: [old], icons: [:], permission: .screenRecordingRequired,
                                         runningApplications: [:])
    let (requests, continuation) = AsyncStream<CheckedContinuation<MacWindowSystem.Snapshot, Never>>.makeStream()
    let system = MacWindowSystem()
    let model = OverlayModel(system: system) { _ in
        await withCheckedContinuation { continuation.yield($0) }
    }
    var iterator = requests.makeAsyncIterator()

    let olderReload = Task { await model.reload() }
    let olderCompletion = try #require(await iterator.next())
    let newerReload = Task { await model.reload() }
    let newerCompletion = try #require(await iterator.next())
    newerCompletion.resume(returning: newest)
    await newerReload.value
    olderCompletion.resume(returning: stale)
    await olderReload.value

    #expect(model.state.applications.map(\.id) == [pid])
    #expect(model.permission == .ready)
    #expect(!model.loading)
    #expect(system.runningApplications[pid] === app)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func destructiveOperationRetreatsThenRestoresTheSameOverlaySession() async throws {
    let app = NSRunningApplication.current
    let pid = app.processIdentifier
    let item = ApplicationItem(id: pid, name: "Current", windows: [])
    let snapshot = MacWindowSystem.Snapshot(applications: [item], icons: [:], permission: .ready,
                                            runningApplications: [pid: app])
    let model = OverlayModel(system: MacWindowSystem()) { _ in snapshot }
    model.state = BrowserState(applications: [item])
    var events: [String] = []
    model.retreat = { events.append("retreat") }
    model.restore = { events.append("restore") }

    model.send(.terminateApplication)
    #expect(model.operationInProgress)
    #expect(events == ["retreat"])
    while model.operationInProgress { await Task.yield() }

    #expect(events == ["retreat", "restore"])
    #expect(model.state.applications.map(\.id) == [pid])
}
#endif
