#if os(macOS)
import AppKit
import Combine
import SwiftUI
import WindowNestCore

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state = BrowserState()
    @Published var icons: [Int32: NSImage] = [:]
    @Published var thumbnails: [WindowID: NSImage] = [:]
    @Published var permission: PermissionState = .ready
    @Published var loading = false
    @Published var navigationBindings: NavigationBindings = .standard
    @Published private(set) var operationInProgress = false
    var dismiss: () -> Void = {}
    var resetKeySequence: () -> Void = {}
    private let system: MacWindowSystem
    private var thumbnailTask: Task<Void, Never>?

    init(system: MacWindowSystem) { self.system = system }

    func reload(prompt: Bool = false) async {
        resetKeySequence()
        loading = true
        let snapshot = await system.snapshot(promptForAccessibility: prompt)
        permission = snapshot.permission
        icons = snapshot.icons
        state.replaceApplications(snapshot.applications)
        loading = false
        refreshThumbnails()
    }

    func send(_ command: NavigationCommand) {
        let priorScreen = state.screen
        let effect = state.handle(command)
        switch effect {
        case .none:
            if priorScreen != state.screen { refreshThumbnails() }
        case .dismiss: dismiss()
        case .refresh: Task { await reload() }
        case .activate(let id):
            Task {
                if await system.activate(id) { dismiss() }
                else { await reload() }
            }
        case .terminateApplication(let pid):
            performDestructiveOperation { [system] in await system.terminateApplication(pid) }
        case .closeWindow(let id):
            performDestructiveOperation { [system] in await system.closeWindow(id) }
        }
    }

    private func performDestructiveOperation(_ operation: @escaping @MainActor () async -> Bool) {
        guard !operationInProgress else { return }
        operationInProgress = true
        // Give the target application room to show save/review sheets unobscured.
        dismiss()
        Task {
            _ = await operation()
            // A successful API return is only acceptance of the request. Always reacquire the
            // real state; never optimistically remove the selected item.
            await reload()
            operationInProgress = false
        }
    }

    func requestPermissions() {
        dismiss()
        system.requestScreenRecording()
        Task { await reload(prompt: true) }
    }

    func openSettings() {
        dismiss()
        system.openPrivacySettings(for: permission)
    }

    func cancelThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private func refreshThumbnails() {
        cancelThumbnails()
        thumbnails = [:]
        let windows = state.visibleWindows
        thumbnailTask = Task {
            for window in windows {
                guard !Task.isCancelled else { return }
                let image = await system.thumbnail(for: window.id)
                guard !Task.isCancelled else { return }
                thumbnails[window.id] = image
            }
        }
    }
}

@MainActor
final class OverlayPanelController {
    private let model: OverlayModel
    private let panel: NSPanel
    private var keyMonitor: Any?
    private let settings: ShortcutSettings
    private var matcher: NavigationKeyMatcher
    private var navigationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var searchModeObserver: AnyCancellable?

    init(windowSystem: MacWindowSystem, settings: ShortcutSettings) {
        self.settings = settings
        matcher = NavigationKeyMatcher(bindings: settings.activeNavigationBindings)
        model = OverlayModel(system: windowSystem)
        model.state = BrowserState(searchMode: settings.applicationSearchMode)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(rootView: OverlayView(model: model))
        model.dismiss = { [weak self] in self?.close() }
        model.navigationBindings = settings.activeNavigationBindings
        model.resetKeySequence = { [weak self] in self?.matcher.reset() }
        navigationObserver = NotificationCenter.default.addObserver(forName: .navigationBindingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.matcher.update(self.settings.activeNavigationBindings); self.model.navigationBindings = self.settings.activeNavigationBindings }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.matcher.reset() }
        }
        searchModeObserver = NotificationCenter.default
            .publisher(for: .applicationSearchModeDidChange)
            .sink { [weak self, weak settings] _ in
                // ShortcutSettings posts search-mode changes on the main actor.
                MainActor.assumeIsolated {
                    guard let mode = settings?.applicationSearchMode else { return }
                    self?.matcher.reset()
                    self?.model.state.updateSearchMode(mode)
                }
            }
    }

    func present() {
        guard !panel.isVisible else { close(); return }
        model.state = BrowserState(searchMode: model.state.searchMode)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let priorScreen = self.model.state.screen
            let result = Self.match(for: event, screen: priorScreen,
                firstResponder: self.panel.firstResponder, matcher: &self.matcher)
            switch result {
            case .unhandled: return event
            case .consumed: break
            case .command(let command):
                self.model.send(command)
                if priorScreen != self.model.state.screen { self.matcher.reset() }
            }
            return nil
        }
        Task { await model.reload() }
    }

    private func close() {
        matcher.reset()
        model.cancelThumbnails()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    static func match(for event: NSEvent, screen: BrowserScreen, firstResponder: NSResponder?,
                      matcher: inout NavigationKeyMatcher) -> NavigationKeyMatcher.MatchResult {
        let searchEditor = screen == .applications ? firstResponder as? NSTextView : nil
        if searchEditor?.hasMarkedText() == true {
            matcher.reset()
            return .unhandled
        }
        if event.isARepeat, event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
           [12, 13, 36, 76].contains(Int(event.keyCode)) {
            matcher.reset()
            return .consumed
        }
        if let builtIn = command(for: event) {
            matcher.reset()
            if screen == .applications, case .chooseNumber = builtIn { return .unhandled }
            return .command(builtIn)
        }
        // Let AppKit handle text and editing shortcuts while the search field has focus.
        if searchEditor != nil {
            matcher.reset()
            return .unhandled
        }
        guard let stroke = event.navigationStroke else { return .unhandled }
        return matcher.process(stroke, at: event.timestamp, isRepeat: event.isARepeat)
    }

    private static func command(for event: NSEvent) -> NavigationCommand? {
        let explicitModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let modifiers = event.modifierFlags.intersection(explicitModifiers)
        if modifiers == .command, !event.isARepeat {
            switch event.keyCode {
            case 12: return .terminateApplication // Q
            case 13: return .closeWindow // W
            case 36, 76: return .showWindows
            default: break
            }
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .moveLeft
        case 124: return .moveRight
        case 125: return .moveDown
        case 126: return .moveUp
        case 36, 76: return .confirm
        case 53: return .escape
        default:
            guard let character = event.charactersIgnoringModifiers, let number = Int(character), (1...9).contains(number) else { return nil }
            return .chooseNumber(number)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var searchFocused: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dragHandle
            header
            if model.permission != .ready { permissionView }
            if model.permission == .accessibilityRequired || model.permission == .bothRequired {
                Spacer()
            } else if model.loading && model.state.applications.isEmpty { ProgressView("Finding windows…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.state.applications.isEmpty { ContentUnavailableView("No Windows", systemImage: "macwindow", description: Text("Open a regular window on the current desktop.")) }
            else if case .applications = model.state.screen, model.state.visibleApplications.isEmpty {
                ContentUnavailableView.search(text: model.state.searchQuery)
            }
            else { cards }
            footer
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 480)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { focusSearchIfNeeded() }
        .onChange(of: model.state.screen) { _, _ in focusSearchIfNeeded() }
    }

    private var dragHandle: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text("Drag to move")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag to move WindowNest")
    }

    private var header: some View {
        HStack {
            if case .windows(let id) = model.state.screen {
                Button { model.send(.escape) } label: { Label("Applications", systemImage: "chevron.left") }.buttonStyle(.plain)
                Text(model.state.applications.first { $0.id == id }?.name ?? "Windows").font(.title.bold())
            } else {
                Text("Applications").font(.title.bold())
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search applications", text: Binding(
                        get: { model.state.searchQuery },
                        set: { model.state.updateSearchQuery($0) }
                    ))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    if !model.state.searchQuery.isEmpty {
                        Button { model.state.updateSearchQuery(""); searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(width: 260)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    if case .applications = model.state.screen {
                        ForEach(Array(model.state.visibleApplications.enumerated()), id: \.element.id) { index, app in
                            AppCard(app: app, icon: model.icons[app.id], selected: index == model.state.selectedIndex)
                                .id(index)
                        }
                    } else {
                        ForEach(Array(model.state.visibleWindows.enumerated()), id: \.element.id) { index, window in
                            WindowCard(window: window, thumbnail: model.thumbnails[window.id], number: index < 9 ? index + 1 : nil, selected: index == model.state.selectedIndex)
                                .id(index)
                        }
                    }
                }.padding(4)
            }
            .id(model.state.screen)
            .onAppear { proxy.scrollTo(model.state.selectedIndex, anchor: .center) }
            .onChange(of: model.state.selectedIndex) { _, index in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: model.state.searchQuery) { _, _ in
                proxy.scrollTo(0, anchor: .top)
            }
            .onChange(of: model.state.searchMode) { _, _ in
                if case .applications = model.state.screen { proxy.scrollTo(0, anchor: .top) }
            }
        }
    }

    private func focusSearchIfNeeded() {
        if case .applications = model.state.screen {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var footer: some View {
        HStack {
            Text("← ↑ ↓ → Select   ⏎ Confirm   esc Back")
            let custom = modelFooterBindings
            if !custom.isEmpty { Text(custom) }
            if case .windows = model.state.screen {
                Spacer()
                Text("⌘W Close window   1–9 Quick select")
            } else {
                Spacer()
                Text("⌘Q Quit app   ⌘⏎ Show windows")
            }
        }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var modelFooterBindings: String {
        return NavigationAction.allCases.compactMap { action in
            let keys = model.navigationBindings.assignments[action, default: []].map(\.description).joined(separator: ",")
            return keys.isEmpty ? nil : "\(keys):\(action.rawValue)"
        }.joined(separator: "  ")
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 42))
            Text("Permissions Required").font(.title2.bold())
            Text(permissionMessage).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack { Button("Request Permissions") { model.requestPermissions() }; Button("Open System Settings") { model.openSettings() } }
            Text("Already enabled? Quit WindowNest, remove it from the relevant permission lists in System Settings, add this copy of the app again, then relaunch.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var permissionMessage: String {
        switch model.permission {
        case .accessibilityRequired: "Enable Accessibility so WindowNest can discover and raise windows."
        case .screenRecordingRequired: "Enable Screen & System Audio Recording to show thumbnails."
        case .bothRequired: "Enable Accessibility and Screen & System Audio Recording, then reopen WindowNest."
        case .ready: ""
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct AppCard: View {
    let app: ApplicationItem; let icon: NSImage?; let selected: Bool
    var body: some View {
        HStack(spacing: 14) {
            Group { if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app").resizable() } }.frame(width: 52, height: 52)
            VStack(alignment: .leading) { Text(app.name).font(.headline).lineLimit(1); Text("\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, minHeight: 92).cardStyle(selected: selected)
    }
}

private struct WindowCard: View {
    let window: WindowItem; let thumbnail: NSImage?; let number: Int?; let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.18))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() } else { Image(systemName: "rectangle.slash").font(.largeTitle).foregroundStyle(.secondary) }
                if let number { Text("\(number)").font(.caption.bold()).padding(7).background(.black.opacity(0.75), in: Circle()).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8) }
            }.aspectRatio(16 / 10, contentMode: .fit)
            Text(window.title).font(.headline).lineLimit(1)
        }.padding(12).cardStyle(selected: selected)
    }
}

private extension View {
    func cardStyle(selected: Bool) -> some View {
        background(.white.opacity(selected ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            .shadow(color: selected ? Color.accentColor.opacity(0.25) : .clear, radius: 8)
    }
}
#endif
