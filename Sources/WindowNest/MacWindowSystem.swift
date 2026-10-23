#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ScreenCaptureKit
import WindowNestCore

@MainActor
final class MacWindowSystem {
    struct Snapshot { let applications: [ApplicationItem]; let icons: [Int32: NSImage]; let permission: PermissionState }
    private struct WindowDescription { let id: WindowID; let attributes: WindowAttributes }
    private struct AccessibilityWindow { let element: AXUIElement; let attributes: WindowAttributes }
    private var runningApplications: [Int32: NSRunningApplication] = [:]

    func snapshot(promptForAccessibility: Bool = false) async -> Snapshot {
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForAccessibility] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(axOptions)
        let screen = CGPreflightScreenCaptureAccess()
        let permission: PermissionState = accessibility ? (screen ? .ready : .screenRecordingRequired) : (screen ? .accessibilityRequired : .bothRequired)
        guard accessibility else { return Snapshot(applications: [], icons: [:], permission: permission) }

        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let grouped = Dictionary(grouping: Self.windowDescriptions(running: running), by: \.id.processIdentifier)
        let applications = grouped.compactMap { pid, windows -> ApplicationItem? in
            guard let app = running[pid], !windows.isEmpty else { return nil }
            let axWindows = windows.contains { $0.attributes.title == nil } ? Self.accessibilityWindows(for: pid) : []
            let attributes = windows.map(\.attributes)
            let axAttributes = axWindows.map(\.attributes)
            let items = windows.enumerated().map { index, window in
                var title = window.attributes.title
                if title == nil, let match = window.attributes.uniqueMatch(in: axAttributes),
                   axAttributes[match].uniqueMatch(in: attributes) == index {
                    title = axAttributes[match].title
                }
                return WindowItem(id: window.id, title: title ?? "")
            }
            return ApplicationItem(id: pid, name: app.localizedName ?? "Unknown App", bundleIdentifier: app.bundleIdentifier, windows: items)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let icons = Dictionary(uniqueKeysWithValues: applications.compactMap { item in running[item.id]?.icon.map { (item.id, $0) } })
        // Preserve the exact object selected from this snapshot. Termination must not look an
        // application up again by a PID which the OS could have reused in the meantime.
        runningApplications = Dictionary(uniqueKeysWithValues: applications.compactMap { item in
            running[item.id].map { (item.id, $0) }
        })
        return Snapshot(applications: applications, icons: icons, permission: permission)
    }

    func thumbnail(for id: WindowID) async -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id.windowNumber && $0.owningApplication?.processID == id.processIdentifier }) else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = max(Int(window.frame.width * 0.5), 1)
            configuration.height = max(Int(window.frame.height * 0.5), 1)
            configuration.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            return NSImage(cgImage: image, size: window.frame.size)
        } catch { return nil }
    }

    func activate(_ id: WindowID) async -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: id.processIdentifier) else { return false }
        let running = [id.processIdentifier: app]
        let windows = Self.windowDescriptions(running: running)
        guard let target = windows.firstIndex(where: { $0.id == id }) else { return false }
        let axWindows = Self.accessibilityWindows(for: id.processIdentifier)
        let attributes = windows.map(\.attributes)
        let axAttributes = axWindows.map(\.attributes)
        guard let match = attributes[target].uniqueMatch(in: axAttributes),
              axAttributes[match].uniqueMatch(in: attributes) == target else { return false }

        // Recheck after AX calls: the selected CG window may have closed or moved meanwhile.
        guard Self.windowDescriptions(running: running).contains(where: { $0.id == id && $0.attributes == attributes[target] }),
              AXUIElementPerformAction(axWindows[match].element, kAXRaiseAction as CFString) == .success else { return false }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    func terminateApplication(_ pid: Int32) async -> Bool {
        guard let application = runningApplications[pid],
              application.processIdentifier == pid, !application.isTerminated else { return false }
        return application.terminate()
    }

    enum CloseResult: Equatable, Sendable { case requested, unavailable, timedOut }

    private final class CloseCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CloseResult, Never>?
        private var result: CloseResult?
        func install(_ continuation: CheckedContinuation<CloseResult, Never>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func finish(_ result: CloseResult) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    func closeWindow(_ id: WindowID) async -> Bool {
        let completion = CloseCompletion()
        let result = await withCheckedContinuation { continuation in
            completion.install(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                completion.finish(Self.closeWindowSynchronously(id))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                completion.finish(.timedOut)
            }
        }
        return result == .requested
    }

    /// Runs outside the main actor because AX calls can wait for an unresponsive target. A timeout
    /// releases the UI even though the system call itself cannot safely be cancelled.
    nonisolated private static func closeWindowSynchronously(_ id: WindowID) -> CloseResult {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: id.processIdentifier) else { return .unavailable }
        let running = [id.processIdentifier: app]
        let windows = windowDescriptions(running: running)
        guard let target = windows.firstIndex(where: { $0.id == id }) else { return .unavailable }
        let axWindows = accessibilityWindows(for: id.processIdentifier)
        let attributes = windows.map(\.attributes)
        let axAttributes = axWindows.map(\.attributes)
        guard let match = attributes[target].uniqueMatch(in: axAttributes),
              axAttributes[match].uniqueMatch(in: attributes) == target else { return .unavailable }

        // Repeat the CG half of the identity check immediately before pressing Close.
        guard windowDescriptions(running: running).contains(where: {
            $0.id == id && $0.attributes == attributes[target]
        }) else { return .unavailable }
        var closeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindows[match].element, kAXCloseButtonAttribute as CFString, &closeValue) == .success,
              let closeButton = closeValue, CFGetTypeID(closeButton) == AXUIElementGetTypeID() else { return .unavailable }
        let button = unsafeBitCast(closeButton, to: AXUIElement.self)
        var enabledValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabledValue) == .success,
              (enabledValue as? Bool) == true else { return .unavailable }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? .requested : .unavailable
    }

    private nonisolated static func windowDescriptions(running: [Int32: NSRunningApplication]) -> [WindowDescription] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let descriptions = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]) ?? []
        return descriptions.compactMap { description in
            guard let pid = description[kCGWindowOwnerPID] as? Int32, pid != ownPID,
                  let number = description[kCGWindowNumber] as? UInt32,
                  (description[kCGWindowLayer] as? Int) == 0,
                  running[pid]?.activationPolicy == .regular else { return nil }
            let frame = (description[kCGWindowBounds] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return WindowDescription(id: WindowID(processIdentifier: pid, windowNumber: number),
                                     attributes: WindowAttributes(title: description[kCGWindowName] as? String, frame: frame))
        }
    }

    private nonisolated static func accessibilityWindows(for pid: Int32) -> [AccessibilityWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.map { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return AccessibilityWindow(element: element, attributes: WindowAttributes(title: title as? String, frame: accessibilityFrame(of: element)))
        }
    }

    private nonisolated static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func requestScreenRecording() { CGRequestScreenCaptureAccess() }
    func openPrivacySettings(for permission: PermissionState) {
        let pane = permission == .screenRecordingRequired ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
#endif
