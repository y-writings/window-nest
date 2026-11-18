#if os(macOS)
import AppKit
import Combine
import SwiftUI
import WindowNestCore

@MainActor
final class OverlayModel: ObservableObject {
    enum InputMode { case list, search }
    @Published var state = BrowserState()
    @Published var icons: [Int32: NSImage] = [:]
    @Published var thumbnails: [WindowID: NSImage] = [:]
    @Published var permission: PermissionState = .ready
    @Published var loading = false
    @Published var navigationBindings: NavigationBindings = .standard
    @Published var inputMode: InputMode = .search
    @Published var viewportMaxWidth: Double = 1440
    @Published var viewportMaxHeight: Double = 900
    @Published private(set) var operationInProgress = false
    @Published private(set) var activationFailure: String?

    var switcherLayout: SwitcherLayout {
        let blocksList = permission == .accessibilityRequired || permission == .bothRequired
        let content: SwitcherLayout.Content
        if blocksList {
            content = .permission
        } else if case .windows = state.screen {
            content = .fullWindowList
        } else if state.applications.isEmpty || state.visibleApplications.isEmpty {
            content = .message
        } else {
            content = .icons
        }
        return SwitcherLayout.make(
            appCount: state.visibleApplications.count,
            selectedIndex: state.selectedIndex,
            windowCount: state.visibleWindows.count,
            windowsRevealed: state.windowsRevealed,
            content: content,
            showsPermissionBanner: permission == .screenRecordingRequired,
            maxPanelWidth: viewportMaxWidth,
            maxPanelHeight: viewportMaxHeight
        )
    }
    var dismiss: () -> Void = {}
    var retreat: () -> Void = {}
    var restore: () -> Void = {}
    var resetKeySequence: () -> Void = {}
    private let system: MacWindowSystem
    private let loadSnapshot: @MainActor (Bool) async -> MacWindowSystem.Snapshot
    private var thumbnailTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var operationGeneration = 0

    init(system: MacWindowSystem, loadSnapshot: (@MainActor (Bool) async -> MacWindowSystem.Snapshot)? = nil) {
        self.system = system
        self.loadSnapshot = loadSnapshot ?? { [system] prompt in await system.snapshot(promptForAccessibility: prompt) }
    }

    func reload(prompt: Bool = false) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        resetKeySequence()
        loading = true
        let snapshot = await loadSnapshot(prompt)
        // Keep the visible list and its termination targets from the same reload.
        guard generation == reloadGeneration else { return }
        system.accept(snapshot)
        permission = snapshot.permission
        icons = snapshot.icons
        let priorScreen = state.screen
        let wasRevealed = state.windowsRevealed
        state.replaceApplications(snapshot.applications)
        syncInputMode(from: priorScreen, wasRevealed: wasRevealed)
        loading = false
        refreshThumbnails()
    }

    func send(_ command: NavigationCommand) {
        let priorScreen = state.screen
        let wasRevealed = state.windowsRevealed
        let priorWindowIDs = state.visibleWindows.map(\.id)
        let effect = state.handle(command)
        syncInputMode(from: priorScreen, wasRevealed: wasRevealed)
        if state.visibleWindows.map(\.id) != priorWindowIDs { refreshThumbnails() }
        switch effect {
        case .none: break
        case .dismiss: dismiss()
        case .refresh: Task { await reload() }
        case .activate(let id):
            activationFailure = nil
            Task {
                switch await system.activate(id) {
                case .activated: dismiss()
                case .failed(let reason):
                    activationFailure = reason
                    await reload()
                }
            }
        case .terminateApplication(let pid):
            let application = system.runningApplications[pid]
            performDestructiveOperation({ [system] in await system.terminateApplication(pid) },
                                        completed: { application?.isTerminated == true })
        case .closeWindow(let id):
            let windowWasObservable = system.windowExists(id) == true
            performDestructiveOperation({ [system] in await system.closeWindow(id) },
                                        completed: { [system] in windowWasObservable && system.windowExists(id) == false })
        }
    }

    private func syncInputMode(from priorScreen: BrowserScreen, wasRevealed: Bool) {
        guard priorScreen != state.screen || wasRevealed != state.windowsRevealed else { return }
        resetKeySequence()
        if state.windowsRevealed {
            inputMode = .list
        } else {
            inputMode = state.screen == .applications && !navigationBindings.hasAdditionalKeys ? .search : .list
        }
    }

    func performDestructiveOperation(_ operation: @escaping @MainActor () async -> Bool,
                                     completed: @escaping @MainActor () -> Bool) {
        guard !operationInProgress else { return }
        operationGeneration += 1
        let generation = operationGeneration
        operationInProgress = true
        retreat()
        Task {
            _ = await operation()
            // The request can return while a save confirmation is still open.
            // shortcut: Stop polling after 30 seconds; the shortcut can restore the preserved session.
            for _ in 0..<60 {
                guard generation == operationGeneration else { return }
                if completed() {
                    await reload()
                    guard generation == operationGeneration else { return }
                    operationInProgress = false
                    restore()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            operationInProgress = false
        }
    }

    func cancelPendingOperation() {
        operationGeneration += 1
        operationInProgress = false
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
    enum EventResult: Equatable {
        case unhandled, consumed, command(NavigationCommand), startSearch, leaveSearch
    }
    let model: OverlayModel
    let panel: NSPanel
    private var keyMonitor: Any?
    private let settings: ShortcutSettings
    private var matcher: NavigationKeyMatcher
    private var layoutObserver: AnyCancellable?
    private var navigationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var searchModeObserver: AnyCancellable?
    private var isRetreated = false

    init(windowSystem: MacWindowSystem, settings: ShortcutSettings) {
        self.settings = settings
        matcher = NavigationKeyMatcher(bindings: settings.activeNavigationBindings)
        model = OverlayModel(system: windowSystem)
        model.state = BrowserState(searchMode: settings.applicationSearchMode)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CGFloat(SwitcherLayout.minimumPanelWidth), height: 320), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
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
        model.retreat = { [weak self] in self?.retreat() }
        model.restore = { [weak self] in self?.restore() }
        model.navigationBindings = settings.activeNavigationBindings
        model.resetKeySequence = { [weak self] in self?.matcher.reset() }
        layoutObserver = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.resizePanelToLayout() }
            }
        navigationObserver = NotificationCenter.default.addObserver(forName: .navigationBindingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bindings = self.settings.activeNavigationBindings
                self.matcher.update(bindings)
                self.model.navigationBindings = bindings
                if self.panel.isVisible, case .applications = self.model.state.screen, !self.model.state.windowsRevealed {
                    self.model.inputMode = bindings.hasAdditionalKeys ? .list : .search
                }
            }
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
        if isRetreated {
            model.cancelPendingOperation()
            restore()
            Task { await model.reload() }
            return
        }
        guard !panel.isVisible else { close(); return }
        model.state = BrowserState(searchMode: model.state.searchMode)
        model.inputMode = settings.activeNavigationBindings.hasAdditionalKeys ? .list : .search
        matcher.reset()
        panel.center()
        updateViewportFromScreen()
        resizePanelToLayout()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let result = Self.match(for: event, screen: self.model.state.screen,
                firstResponder: self.panel.firstResponder,
                hasAdditionalKeys: self.settings.activeNavigationBindings.hasAdditionalKeys,
                windowsRevealed: self.model.state.windowsRevealed,
                matcher: &self.matcher)
            switch result {
            case .unhandled: return event
            case .consumed: break
            case .startSearch:
                self.matcher.reset()
                self.model.inputMode = .search
            case .leaveSearch:
                self.matcher.reset()
                self.model.inputMode = .list
            case .command(let command):
                self.model.send(command)
            }
            return nil
        }
        Task { await model.reload() }
    }

    private func close() {
        model.cancelPendingOperation()
        isRetreated = false
        matcher.reset()
        model.cancelThumbnails()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private func retreat() {
        matcher.reset()
        isRetreated = true
        panel.orderOut(nil)
    }

    private func restore() {
        guard isRetreated else { return }
        isRetreated = false
        panel.makeKeyAndOrderFront(nil)
    }

    func updateViewportFromScreen() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let maxWidth = max(640.0, Double(visible.width) - 48)
        let maxHeight = max(480.0, Double(visible.height) - 80)
        if model.viewportMaxWidth != maxWidth { model.viewportMaxWidth = maxWidth }
        if model.viewportMaxHeight != maxHeight { model.viewportMaxHeight = maxHeight }
    }

    /// Sizes the panel from `model.switcherLayout` and keeps that frame inside the visible screen.
    func resizePanelToLayout() {
        let layout = model.switcherLayout
        let current = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        let placed = PanelPlacement.frame(
            current: PanelRect(current),
            width: layout.panelWidth,
            height: layout.panelHeight,
            visible: visible.map(PanelRect.init)
        )
        let next = placed.nsRect
        guard abs(current.width - next.width) >= 1 || abs(current.height - next.height) >= 1
            || abs(current.minX - next.minX) >= 1 || abs(current.minY - next.minY) >= 1 else { return }
        panel.setFrame(next, display: true, animate: false)
    }

    static func match(for event: NSEvent, screen: BrowserScreen, firstResponder: NSResponder?,
                      hasAdditionalKeys: Bool = false,
                      windowsRevealed: Bool = false,
                      matcher: inout NavigationKeyMatcher) -> EventResult {
        let searchEditor = screen == .applications ? firstResponder as? NSTextView : nil
        let builtIn = command(for: event)
        if event.isARepeat, builtIn == .terminateApplication || builtIn == .closeWindow || builtIn == .showWindows {
            matcher.reset()
            return .consumed
        }
        if searchEditor?.hasMarkedText() == true {
            matcher.reset()
            if builtIn == .terminateApplication || builtIn == .closeWindow { return .consumed }
            return .unhandled
        }
        if searchEditor != nil, builtIn == .escape, hasAdditionalKeys {
            matcher.reset()
            return .leaveSearch
        }
        if let builtIn {
            matcher.reset()
            if case .chooseNumber = builtIn {
                let typingInSearch = searchEditor != nil
                let appsWithoutChoices = screen == .applications && !windowsRevealed
                if typingInSearch || appsWithoutChoices { return .unhandled }
            }
            return .command(builtIn)
        }
        // Let AppKit handle text and editing shortcuts while the search field has focus.
        if searchEditor != nil {
            matcher.reset()
            return .unhandled
        }
        if screen == .applications, isSearchShortcut(event) {
            matcher.reset()
            return .startSearch
        }
        guard let stroke = event.navigationStroke else { return .unhandled }
        switch matcher.process(stroke, at: event.timestamp, isRepeat: event.isARepeat) {
        case .unhandled: return .unhandled
        case .consumed: return .consumed
        case .command(let command): return .command(command)
        }
    }

    /// Search shortcuts win over custom movement sequences in the Applications list. This keeps
    /// search keyboard-accessible even when `/` and Command-F were saved as movement bindings;
    /// those bindings remain available in the Windows list and are never removed from settings.
    private static func isSearchShortcut(_ event: NSEvent) -> Bool {
        let explicitModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let modifiers = event.modifierFlags.intersection(explicitModifiers)
        let stroke = event.navigationStroke
        return (modifiers.isEmpty && stroke == KeyStroke(key: "/"))
            || (modifiers == .command && stroke == KeyStroke(key: "f", modifiers: .command))
    }

    private static func command(for event: NSEvent) -> NavigationCommand? {
        let explicitModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let modifiers = event.modifierFlags.intersection(explicitModifiers)
        if modifiers == .command {
            if event.navigationStroke == KeyStroke(key: "q", modifiers: .command) { return .terminateApplication }
            if event.navigationStroke == KeyStroke(key: "w", modifiers: .command) { return .closeWindow }
            if event.keyCode == 36 || event.keyCode == 76 { return .showWindows }
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .moveLeft
        case 124: return .moveRight
        case 125: return .revealWindows
        case 126: return .concealWindows
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

    enum CardID: Hashable {
        case application(Int32)
        case window(WindowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: cg(SwitcherLayout.stackSpacing)) {
            dragHandle
            header
            if model.permission == .screenRecordingRequired, model.switcherLayout.permissionBannerHeight > 0 {
                permissionView
                    .frame(height: cg(model.switcherLayout.permissionBannerHeight))
                    .clipped()
            } else if model.permission != .ready {
                permissionView
            }
            if model.permission == .accessibilityRequired || model.permission == .bothRequired {
                Spacer()
            } else if model.loading && model.state.applications.isEmpty { ProgressView("Finding windows…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.state.applications.isEmpty { ContentUnavailableView("No Windows", systemImage: "macwindow", description: Text("Open a regular window on the current desktop.")) }
            else if case .applications = model.state.screen, model.state.visibleApplications.isEmpty {
                ContentUnavailableView.search(text: model.state.searchQuery)
            }
            else { cards }
            if let failure = model.activationFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Window activation failed: \(failure)")
            }
            footer
        }
        .padding(cg(SwitcherLayout.outerPadding))
        .frame(width: cg(model.switcherLayout.panelWidth), height: cg(model.switcherLayout.panelHeight), alignment: .top)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { focusSearchIfNeeded() }
        .onChange(of: model.state.screen) { _, _ in focusSearchIfNeeded() }
        .onChange(of: model.inputMode) { _, _ in focusSearchIfNeeded() }
        .onChange(of: searchFocused) { _, focused in
            guard case .applications = model.state.screen else { return }
            model.inputMode = focused ? .search : .list
            model.resetKeySequence()
        }
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
        .frame(maxWidth: .infinity, minHeight: cg(SwitcherLayout.dragHandleHeight), maxHeight: cg(SwitcherLayout.dragHandleHeight))
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
                    .accessibilityHint(searchFocused
                        ? "Type to filter applications. Press Escape to return to the application list."
                        : "Press slash or Command-F to search applications.")
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
        .frame(height: cg(SwitcherLayout.headerHeight))
    }

    private var cards: some View {
        let layout = model.switcherLayout
        return Group {
            if case .windows = model.state.screen {
                fullWindowList
            } else {
                VStack(alignment: .leading, spacing: cg(SwitcherLayout.stackSpacing)) {
                    iconRow(layout)
                    if model.state.windowsRevealed, !model.state.visibleWindows.isEmpty {
                        revealedWindowList(layout)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func iconRow(_ layout: SwitcherLayout) -> some View {
        HStack(spacing: cg(layout.iconSpacing)) {
            ForEach(Array(model.state.visibleApplications.enumerated()), id: \.element.id) { index, app in
                AppIcon(app: app, icon: model.icons[app.id], selected: index == model.state.selectedIndex)
                    .frame(width: cg(layout.iconSize), height: cg(layout.iconSize))
                    .id(CardID.application(app.id))
            }
        }
        .padding(.leading, cg(layout.iconRowOrigin))
        .frame(width: cg(layout.contentWidth), height: cg(layout.iconSize), alignment: .leading)
    }

    private func revealedWindowList(_ layout: SwitcherLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: cg(SwitcherLayout.windowListSpacing)) {
                    ForEach(Array(model.state.visibleWindows.enumerated()), id: \.element.id) { index, window in
                        WindowChoice(window: window, thumbnail: model.thumbnails[window.id], number: index < 9 ? index + 1 : nil, selected: index == model.state.selectedWindowIndex)
                            .id(CardID.window(window.id))
                    }
                }
            }
            .frame(width: cg(layout.windowColumnWidth), height: cg(layout.windowListHeight), alignment: .top)
            .padding(.leading, cg(layout.windowColumnOrigin))
            .frame(width: cg(layout.contentWidth), alignment: .leading)
            .onAppear { scrollToSelection(with: proxy) }
            .onChange(of: model.state.selectedWindowIndex) { _, _ in scrollToSelection(with: proxy) }
            .onChange(of: model.state.selectedApplication?.id) { _, _ in scrollToSelection(with: proxy) }
        }
    }

    private var fullWindowList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(model.state.visibleWindows.enumerated()), id: \.element.id) { index, window in
                        WindowCard(window: window, thumbnail: model.thumbnails[window.id], number: index < 9 ? index + 1 : nil, selected: index == model.state.selectedIndex)
                            .frame(width: 280)
                            .id(CardID.window(window.id))
                    }
                }.padding(4)
            }
            .frame(maxHeight: .infinity)
            .onAppear { scrollToSelection(with: proxy) }
            .onChange(of: model.state.selectedIndex) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { scrollToSelection(with: proxy) }
            }
        }
    }

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        if let id = selectedCardID { proxy.scrollTo(id, anchor: .center) }
    }

    var selectedCardID: CardID? {
        switch model.state.screen {
        case .applications:
            if model.state.windowsRevealed {
                let windows = model.state.visibleWindows
                if windows.indices.contains(model.state.selectedWindowIndex) {
                    return .window(windows[model.state.selectedWindowIndex].id)
                }
            }
            let applications = model.state.visibleApplications
            guard applications.indices.contains(model.state.selectedIndex) else { return nil }
            return .application(applications[model.state.selectedIndex].id)
        case .windows:
            let windows = model.state.visibleWindows
            guard windows.indices.contains(model.state.selectedIndex) else { return nil }
            return .window(windows[model.state.selectedIndex].id)
        }
    }

    private func focusSearchIfNeeded() {
        let shouldFocus = model.state.screen == .applications && model.inputMode == .search
        guard searchFocused != shouldFocus else { return }
        // Defer only the requested transition. Later data and thumbnail updates do not schedule
        // another focus operation, so they cannot steal focus back from the list.
        DispatchQueue.main.async {
            guard model.state.screen == .applications,
                  model.inputMode == (shouldFocus ? .search : .list) else { return }
            searchFocused = shouldFocus
        }
    }

    private var footer: some View {
        HStack {
            Text(primaryFooterHint)
            let custom = modelFooterBindings
            if !custom.isEmpty { Text(custom) }
            if model.state.windowsRevealed || model.state.screen != .applications {
                Spacer()
                Text("⌘W Close window   1–9 Quick select")
            } else {
                Spacer()
                Text("⌘Q Quit app   ⌘⏎ Show windows")
            }
        }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: cg(SwitcherLayout.footerHeight))
    }

    private var primaryFooterHint: String {
        if model.state.windowsRevealed {
            return "← → Switch app   ↑↓ Choose window   ⏎ Open   esc Back"
        }
        if case .applications = model.state.screen {
            if model.inputMode == .search {
                return model.navigationBindings.hasAdditionalKeys
                    ? "Type to search   ← → Select   ↓ Windows   ⏎ Confirm   esc List"
                    : "Type to search   ← → Select   ↓ Windows   ⏎ Confirm   esc Close"
            }
            return "/ or ⌘F Search   ← → Select   ↓ Windows   ⏎ Confirm   esc Close"
        }
        return "← → Select   ⏎ Confirm   esc Applications"
    }

    private var modelFooterBindings: String {
        guard model.inputMode == .list else { return "" }
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

private func cg(_ value: Double) -> CGFloat { CGFloat(value) }

private extension PanelRect {
    init(_ rect: NSRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.size.width), height: Double(rect.size.height))
    }

    var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
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

private struct AppIcon: View {
    let app: ApplicationItem
    let icon: NSImage?
    let selected: Bool
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().padding(8)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: selected ? 8 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(app.windows.count) windows")
        .accessibilityAddTraits(selected ? [.isImage, .isSelected] : .isImage)
        .help(app.name)
    }
}

private struct WindowChoice: View {
    let window: WindowItem
    let thumbnail: NSImage?
    let number: Int?
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.18))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                }
                if let number {
                    Text("\(number)").font(.caption2.bold()).padding(4)
                        .background(.black.opacity(0.75), in: Circle()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(window.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: cg(SwitcherLayout.windowRowHeight), maxHeight: cg(SwitcherLayout.windowRowHeight), alignment: .leading)
        .cardStyle(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
