#if os(macOS)
import Carbon
import Foundation

extension Notification.Name { static let shortcutDidChange = Notification.Name("shortcutDidChange") }

@MainActor
final class ShortcutSettings: ObservableObject {
    @Published var keyCode: UInt32 {
        didSet { defaults.set(Int(keyCode), forKey: "shortcutKeyCode"); notify() }
    }
    @Published var modifiers: UInt32 {
        didSet { defaults.set(Int(modifiers), forKey: "shortcutModifiers"); notify() }
    }
    private let defaults = UserDefaults.standard

    init() {
        keyCode = UInt32(defaults.object(forKey: "shortcutKeyCode") as? Int ?? kVK_ANSI_W)
        modifiers = UInt32(defaults.object(forKey: "shortcutModifiers") as? Int ?? (cmdKey | optionKey))
    }

    private func notify() { NotificationCenter.default.post(name: .shortcutDidChange, object: nil) }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, pointer, &handler)
        let signature = OSType(0x574E5354) // WNST
        var identifier = EventHotKeyID(signature: signature, id: 1)
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
            Picker("Key", selection: $settings.keyCode) {
                Text("W").tag(UInt32(kVK_ANSI_W)); Text("Space").tag(UInt32(kVK_Space)); Text("Tab").tag(UInt32(kVK_Tab))
            }
            Picker("Modifiers", selection: $settings.modifiers) {
                Text("⌘⌥").tag(UInt32(cmdKey | optionKey)); Text("⌃⌥").tag(UInt32(controlKey | optionKey)); Text("⌃⌘").tag(UInt32(controlKey | cmdKey))
            }
            Text("Changes are saved and take effect immediately.").foregroundStyle(.secondary)
        }.padding(24).frame(width: 360)
    }
}
#endif
