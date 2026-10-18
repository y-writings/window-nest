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

    func snapshot(promptForAccessibility: Bool = false) async -> Snapshot {
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForAccessibility] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(axOptions)
        let screen = CGPreflightScreenCaptureAccess()
        let permission: PermissionState = accessibility ? (screen ? .ready : .screenRecordingRequired) : (screen ? .accessibilityRequired : .bothRequired)
        guard accessibility else { return Snapshot(applications: [], icons: [:], permission: permission) }

        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let grouped = Dictionary(grouping: windowDescriptions(running: running), by: \.id.processIdentifier)
        let applications = grouped.compactMap { pid, windows -> ApplicationItem? in
            guard let app = running[pid], !windows.isEmpty else { return nil }
            let axWindows = windows.contains { $0.attributes.title == nil } ? accessibilityWindows(for: pid) : []
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
        let windows = windowDescriptions(running: running)
        guard let target = windows.firstIndex(where: { $0.id == id }) else { return false }
        let axWindows = accessibilityWindows(for: id.processIdentifier)
        let attributes = windows.map(\.attributes)
        let axAttributes = axWindows.map(\.attributes)
        guard let match = attributes[target].uniqueMatch(in: axAttributes),
              axAttributes[match].uniqueMatch(in: attributes) == target else { return false }

        // Recheck after AX calls: the selected CG window may have closed or moved meanwhile.
        guard windowDescriptions(running: running).contains(where: { $0.id == id && $0.attributes == attributes[target] }),
              AXUIElementPerformAction(axWindows[match].element, kAXRaiseAction as CFString) == .success else { return false }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func windowDescriptions(running: [Int32: NSRunningApplication]) -> [WindowDescription] {
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

    private func accessibilityWindows(for pid: Int32) -> [AccessibilityWindow] {
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

    private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
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
