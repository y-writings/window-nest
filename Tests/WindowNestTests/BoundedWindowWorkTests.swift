#if os(macOS)
import AppKit
import Testing
@testable import WindowNest

private func waitFor(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

@Test @MainActor func boundedWindowWorkRunsOffTheMainThread() async {
    let ranOnMainThread = await MacWindowSystem.bounded(timeout: 2, fallback: true) {
        Thread.isMainThread
    }
    #expect(!ranOnMainThread)
}

@Test func boundedWindowWorkReturnsFallbackWhenWorkerStalls() async {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let task = Task.detached {
        await MacWindowSystem.bounded(timeout: 0.2, fallback: "visible") {
            started.signal()
            release.wait()
            finished.signal()
            return "late AX result"
        }
    }
    #expect(waitFor(started))
    let result = await task.value
    #expect(result == "visible")
    release.signal()
    #expect(waitFor(finished))
}
#endif
