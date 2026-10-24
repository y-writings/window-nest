#if os(macOS)
import Carbon
import Combine
import Foundation
import SwiftUI
import WindowNestCore

extension Notification.Name { static let shortcutDidChange = Notification.Name("shortcutDidChange") }
extension Notification.Name { static let navigationBindingsDidChange = Notification.Name("navigationBindingsDidChange") }
extension Notification.Name { static let applicationSearchModeDidChange = Notification.Name("applicationSearchModeDidChange") }

struct GlobalShortcutConfiguration: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

@MainActor
final class ShortcutSettings: ObservableObject {
    @Published private(set) var globalShortcut: GlobalShortcutConfiguration
    var keyCode: UInt32 { globalShortcut.keyCode }
    var modifiers: UInt32 { globalShortcut.modifiers }
    private let defaults: UserDefaults
    private let navigationStore: NavigationBindingsStore
    private let searchModeStore: ApplicationSearchModeStore
    private let keyForVirtualKeyCode: @MainActor (UInt16) -> String?
    private var layoutObserver: AnyCancellable?
    @Published private(set) var navigationBindings: NavigationBindings
    @Published private(set) var activeNavigationBindings: NavigationBindings = .standard
    @Published var bindingError: String?
    @Published var applicationSearchMode: ApplicationSearchMode {
        didSet {
            searchModeStore.value = applicationSearchMode
            NotificationCenter.default.post(name: .applicationSearchModeDidChange, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard,
         keyForVirtualKeyCode: @escaping @MainActor (UInt16) -> String? = KeyboardLayout.character) {
        self.defaults = defaults
        self.keyForVirtualKeyCode = keyForVirtualKeyCode
        navigationStore = NavigationBindingsStore(defaults: defaults)
        navigationBindings = navigationStore.load()
        searchModeStore = ApplicationSearchModeStore(defaults: defaults)
        applicationSearchMode = searchModeStore.value
        globalShortcut = GlobalShortcutConfiguration(
            keyCode: UInt32(defaults.object(forKey: "shortcutKeyCode") as? Int ?? kVK_ANSI_W),
            modifiers: UInt32(defaults.object(forKey: "shortcutModifiers") as? Int ?? (cmdKey | optionKey)))
        refreshActiveNavigationBindings()
        layoutObserver = NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActiveNavigationBindings() }
            }
    }

    var globalKeyStroke: KeyStroke? {
        globalKeyStroke(keyCode: keyCode, modifiers: modifiers)
    }

    private func globalKeyStroke(keyCode: UInt32, modifiers: UInt32) -> KeyStroke? {
        let key: String
        switch Int(keyCode) {
        case kVK_ANSI_W:
            guard let character = keyForVirtualKeyCode(UInt16(keyCode)), !character.isEmpty else { return nil }
            key = character
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

    @discardableResult
    func updateGlobal(keyCode newKeyCode: UInt32? = nil, modifiers newModifiers: UInt32? = nil) -> Bool {
        let candidateKey = newKeyCode ?? keyCode, candidateModifiers = newModifiers ?? modifiers
        guard let stroke = globalKeyStroke(keyCode: candidateKey, modifiers: candidateModifiers) else {
            bindingError = "The current keyboard layout cannot translate this shortcut."; return false
        }
        if let conflict = NavigationBindingValidator.validate(navigationBindings, globalShortcut: stroke) {
            bindingError = conflict.description; return false
        }
        globalShortcut = GlobalShortcutConfiguration(keyCode: candidateKey, modifiers: candidateModifiers)
        defaults.set(Int(candidateKey), forKey: "shortcutKeyCode")
        defaults.set(Int(candidateModifiers), forKey: "shortcutModifiers")
        refreshActiveNavigationBindings()
        notify()
        return true
    }

    @discardableResult
    func applyNavigationBindings(_ value: NavigationBindings) -> Bool {
        guard let globalKeyStroke else {
            bindingError = "The current keyboard layout cannot translate this shortcut."; return false
        }
        if let conflict = NavigationBindingValidator.validate(value, globalShortcut: globalKeyStroke) {
            bindingError = conflict.description; return false
        }
        do {
            try navigationStore.save(value)
            navigationBindings = value
            refreshActiveNavigationBindings()
            return true
        } catch { bindingError = error.localizedDescription; return false }
    }

    func refreshActiveNavigationBindings() {
        // A layout change can introduce conflicts without a settings edit. Keep the
        // saved bindings intact and restore them automatically when the conflict clears.
        if let globalKeyStroke {
            activeNavigationBindings = NavigationBindings(assignments: navigationBindings.assignments.mapValues {
                $0.filter { !$0.strokes.contains(globalKeyStroke) }
            })
            if activeNavigationBindings != navigationBindings {
                bindingError = "\(globalKeyStroke) is the global shortcut on this keyboard layout. Conflicting cursor bindings are temporarily disabled; saved bindings are unchanged."
            } else { bindingError = nil }
        } else {
            activeNavigationBindings = .standard
            bindingError = "The current keyboard layout cannot translate the global shortcut. Custom cursor bindings are temporarily disabled; saved bindings are unchanged."
        }
        NotificationCenter.default.post(name: .navigationBindingsDidChange, object: nil)
    }

    private func notify() { NotificationCenter.default.post(name: .shortcutDidChange, object: nil) }
}

@MainActor
enum KeyboardLayout {
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 16)
        // Match NSEvent.charactersIgnoringModifiers: the global choices have no Shift modifier.
        let status = withExtendedLifetime(data) {
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
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
            GlobalShortcutControls(settings: settings)
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
            Section("Application search") {
                Picker("Matching", selection: $settings.applicationSearchMode) {
                    Text("Fuzzy").tag(ApplicationSearchMode.fuzzy)
                    Text("Prefix").tag(ApplicationSearchMode.prefix)
                }
                .pickerStyle(.radioGroup)
                Text("Fuzzy finds characters in order, so ‘pass’ finds 1Password. Prefix only matches the beginning, so ‘pass’ does not; ‘1pa’ does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 520)
    }
}

private struct NavigationBindingRow: View {
    @ObservedObject var settings: ShortcutSettings
    let action: NavigationAction
    // Spell out the property-wrapper initializer so Swift does not select the
    // zero-argument SwiftUIMacros.StateMacro shipped in newer macOS SDKs.
    @State(initialValue: NavigationKeyRecording()) private var recording: NavigationKeyRecording
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
        .onReceive(settings.$navigationBindings) { _ in recording.reset() }
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
