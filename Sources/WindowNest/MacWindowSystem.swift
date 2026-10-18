#if os(macOS)
import AppKit
import ApplicationServices
import ScreenCaptureKit
import WindowNestCore

@MainActor
final class MacWindowSystem {
    struct Snapshot { let applications: [ApplicationItem]; let icons: [Int32: NSImage]; let permission: PermissionState }

    func snapshot(promptForAccessibility: Bool = false) async -> Snapshot {
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForAccessibility] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(axOptions)
        let screen = CGPreflightScreenCaptureAccess()
        let permission: PermissionState = accessibility ? (screen ? .ready : .screenRecordingRequired) : (screen ? .accessibilityRequired : .bothRequired)
        guard accessibility else { return Snapshot(applications: [], icons: [:], permission: permission) }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let descriptions = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]) ?? []
        var grouped: [Int32: [WindowItem]] = [:]
        for description in descriptions {
            guard let pid = description[kCGWindowOwnerPID] as? Int32, pid != ownPID,
                  let number = description[kCGWindowNumber] as? UInt32,
                  (description[kCGWindowLayer] as? Int) == 0,
                  running[pid]?.activationPolicy == .regular else { continue }
            let title = description[kCGWindowName] as? String ?? ""
            grouped[pid, default: []].append(WindowItem(id: WindowID(processIdentifier: pid, windowNumber: number), title: title))
        }
        let applications = grouped.compactMap { pid, windows -> ApplicationItem? in
            guard let app = running[pid], !windows.isEmpty else { return nil }
            return ApplicationItem(id: pid, name: app.localizedName ?? "Unknown App", bundleIdentifier: app.bundleIdentifier, windows: windows)
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
        let current = await snapshot()
        guard current.applications.flatMap(\.windows).contains(where: { $0.id == id }) else { return false }
        let appElement = AXUIElementCreateApplication(id.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return false }

        // CGWindow does not publish its AX element. Match stable public attributes, preferring
        // title and front-to-back order; validate the CG identity immediately before raising.
        let wantedTitle = current.applications.flatMap(\.windows).first { $0.id == id }?.title
        let element = elements.first { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return (title as? String ?? "Untitled Window") == wantedTitle
        } ?? elements.first
        guard let element else { return false }
        NSRunningApplication(processIdentifier: id.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    func requestScreenRecording() { CGRequestScreenCaptureAccess() }
    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
#endif
