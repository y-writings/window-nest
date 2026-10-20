#if os(macOS)
import Carbon
import SwiftUI

@MainActor
struct GlobalShortcutControls: View {
    @ObservedObject var settings: ShortcutSettings
    @State private var draft: GlobalShortcutConfiguration

    init(settings: ShortcutSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.globalShortcut)
    }

    private var hasChanges: Bool { draft != settings.globalShortcut }

    var body: some View {
        Section {
            Picker("Key", selection: $draft.keyCode) {
                Text("W").tag(UInt32(kVK_ANSI_W))
                Text("Space").tag(UInt32(kVK_Space))
                Text("Tab").tag(UInt32(kVK_Tab))
            }
            Picker("Modifiers", selection: $draft.modifiers) {
                Text("⌘⌥").tag(UInt32(cmdKey | optionKey))
                Text("⌃⌥").tag(UInt32(controlKey | optionKey))
                Text("⌃⌘").tag(UInt32(controlKey | cmdKey))
            }
            HStack {
                Button("Apply") {
                    settings.updateGlobal(keyCode: draft.keyCode, modifiers: draft.modifiers)
                }
                Button("Cancel") {
                    draft = settings.globalShortcut
                    settings.refreshActiveNavigationBindings()
                }
            }
            .disabled(!hasChanges)
            Text("Global shortcut changes take effect when you click Apply. Cursor movement changes below are saved immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Global shortcut").font(.headline)
        }
        .onAppear { draft = settings.globalShortcut }
        .onChange(of: settings.globalShortcut) { _, value in draft = value }
        .onChange(of: ObjectIdentifier(settings)) { _, _ in draft = settings.globalShortcut }
    }
}
#endif
