#if os(macOS)
import Carbon
import Foundation
import SwiftUI
import WindowNestCore

extension Notification.Name { static let shortcutDidChange = Notification.Name("shortcutDidChange") }
extension Notification.Name { static let navigationBindingsDidChange = Notification.Name("navigationBindingsDidChange") }

@MainActor
final class ShortcutSettings: ObservableObject {
    @Published var keyCode: UInt32 {
        didSet { defaults.set(Int(keyCode), forKey: "shortcutKeyCode"); notify() }
    }
    @Published var modifiers: UInt32 {
        didSet { defaults.set(Int(modifiers), forKey: "shortcutModifiers"); notify() }
    }
    private let defaults = UserDefaults.standard
    private let navigationStore = NavigationBindingsStore()
    @Published private(set) var navigationBindings: NavigationBindings
    @Published var bindingError: String?

    init() {
        navigationBindings = navigationStore.load()
        keyCode = UInt32(defaults.object(forKey: "shortcutKeyCode") as? Int ?? kVK_ANSI_W)
        modifiers = UInt32(defaults.object(forKey: "shortcutModifiers") as? Int ?? (cmdKey | optionKey))
    }

    var globalKeyStroke: KeyStroke? {
        globalKeyStroke(keyCode: keyCode, modifiers: modifiers)
    }

    private func globalKeyStroke(keyCode: UInt32, modifiers: UInt32) -> KeyStroke? {
        let key: String
        switch Int(keyCode) {
        case kVK_ANSI_W: key = "w"
        case kVK_Space: key = " "
        case kVK_Tab: key = "tab"
        default: return nil
        }
        var flags: KeyModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return KeyStroke(key: key, modifiers: flags)
    }

    func updateGlobal(keyCode newKeyCode: UInt32? = nil, modifiers newModifiers: UInt32? = nil) {
        let candidateKey = newKeyCode ?? keyCode, candidateModifiers = newModifiers ?? modifiers
        if let stroke = globalKeyStroke(keyCode: candidateKey, modifiers: candidateModifiers),
           let conflict = NavigationBindingValidator.validate(navigationBindings, globalShortcut: stroke) {
            bindingError = conflict.description; return
        }
        keyCode = candidateKey; modifiers = candidateModifiers; bindingError = nil
    }

    @discardableResult
    func applyNavigationBindings(_ value: NavigationBindings) -> Bool {
        if let conflict = NavigationBindingValidator.validate(value, globalShortcut: globalKeyStroke) {
            bindingError = conflict.description; return false
        }
        do {
            try navigationStore.save(value)
            navigationBindings = value; bindingError = nil
            NotificationCenter.default.post(name: .navigationBindingsDidChange, object: nil)
            return true
        } catch { bindingError = error.localizedDescription; return false }
    }

    private func notify() { NotificationCenter.default.post(name: .shortcutDidChange, object: nil) }
}

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    @MainActor
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            // Application-target Carbon events are dispatched on the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &eventType, pointer, &handler)
        let signature = OSType(0x574E5354) // WNST
        let identifier = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: ShortcutSettings
    var body: some View {
        Form {
            Text("Global shortcut").font(.headline)
            Picker("Key", selection: Binding(get: { settings.keyCode }, set: { settings.updateGlobal(keyCode: $0) })) {
                Text("W").tag(UInt32(kVK_ANSI_W)); Text("Space").tag(UInt32(kVK_Space)); Text("Tab").tag(UInt32(kVK_Tab))
            }
            Picker("Modifiers", selection: Binding(get: { settings.modifiers }, set: { settings.updateGlobal(modifiers: $0) })) {
                Text("⌘⌥").tag(UInt32(cmdKey | optionKey)); Text("⌃⌥").tag(UInt32(controlKey | optionKey)); Text("⌃⌘").tag(UInt32(controlKey | cmdKey))
            }
            Text("Changes are saved and take effect immediately.").foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Cursor movement").font(.headline)
                Spacer()
                Button("Standard") { settings.applyNavigationBindings(.standard) }
                Button("Vim") { settings.applyNavigationBindings(.vim) }
            }
            ForEach(NavigationAction.allCases, id: \.self) { action in
                NavigationBindingRow(settings: settings, action: action)
            }
            if let error = settings.bindingError { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(24).frame(width: 520)
    }
}

private struct NavigationBindingRow: View {
    @ObservedObject var settings: ShortcutSettings
    let action: NavigationAction
    @State private var recording = NavigationKeyRecording()
    private var title: String {
        switch action {
        case .left: "Left"; case .down: "Down"; case .up: "Up"; case .right: "Right"
        case .rowStart: "Row start"; case .rowEnd: "Row end"; case .listStart: "List start"; case .listEnd: "List end"
        }
    }
    var body: some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Text((settings.navigationBindings.assignments[action] ?? []).map(\.description).joined(separator: ", ")).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $recording.strokeCount) { Text("1 key").tag(1); Text("2 keys").tag(2) }.frame(width: 90)
            KeyRecorder(active: recording.strokes.count < recording.strokeCount) { stroke in
                guard let sequence = recording.record(stroke) else { return }
                var value = settings.navigationBindings
                value.assignments[action, default: []].append(sequence)
                _ = settings.applyNavigationBindings(value)
            }.frame(width: 62, height: 24)
            Button("Clear") {
                recording.reset()
                var value = settings.navigationBindings
                value.assignments[action] = []
                settings.applyNavigationBindings(value)
            }
        }
    }
}

private struct KeyRecorder: NSViewRepresentable {
    let active: Bool; let onKey: (KeyStroke) -> Void
    func makeNSView(context: Context) -> RecorderView { let view = RecorderView(); view.onKey = onKey; return view }
    func updateNSView(_ view: RecorderView, context: Context) { view.onKey = onKey; view.active = active }
    final class RecorderView: NSView {
        var onKey: ((KeyStroke) -> Void)?; var active = true
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            let label = window?.firstResponder === self ? "Press key" : "Record"
            label.draw(at: NSPoint(x: 7, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        }
        override func keyDown(with event: NSEvent) { if active, let stroke = event.navigationStroke { onKey?(stroke) } }
    }
}

extension NSEvent {
    var navigationStroke: KeyStroke? {
        let special: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "keypadEnter", 53: "escape", 48: "tab"]
        guard let key = special[keyCode] ?? charactersIgnoringModifiers, !key.isEmpty else { return nil }
        var modifiers: KeyModifiers = []
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { modifiers.insert(.shift) }; if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }; if flags.contains(.command) { modifiers.insert(.command) }
        return KeyStroke(key: key, modifiers: modifiers)
    }
}
#endif
