#if os(macOS)
import AppKit
import SwiftUI
import WindowNestCore

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state = BrowserState()
    @Published var icons: [Int32: NSImage] = [:]
    @Published var thumbnails: [WindowID: NSImage] = [:]
    @Published var permission: PermissionState = .ready
    @Published var loading = false
    var dismiss: () -> Void = {}
    private let system: MacWindowSystem
    private var thumbnailTask: Task<Void, Never>?

    init(system: MacWindowSystem) { self.system = system }

    func reload(prompt: Bool = false) async {
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
        }
    }

    func requestPermissions() {
        system.requestScreenRecording()
        Task { await reload(prompt: true) }
    }

    func openSettings() { system.openPrivacySettings(for: permission) }

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

    init(windowSystem: MacWindowSystem) {
        model = OverlayModel(system: windowSystem)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(rootView: OverlayView(model: model))
        model.dismiss = { [weak self] in self?.close() }
    }

    func present() {
        guard !panel.isVisible else { close(); return }
        model.state = BrowserState()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  let command = Self.command(for: event) else { return event }
            self.model.send(command)
            return nil
        }
        Task { await model.reload() }
    }

    private func close() {
        model.cancelThumbnails()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private static func command(for event: NSEvent) -> NavigationCommand? {
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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.permission != .ready { permissionView }
            if model.permission == .accessibilityRequired || model.permission == .bothRequired {
                Spacer()
            } else if model.loading && model.state.applications.isEmpty { ProgressView("Finding windows…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.state.applications.isEmpty { ContentUnavailableView("No Windows", systemImage: "macwindow", description: Text("Open a regular window on the current desktop.")) }
            else { cards }
            footer
        }
        .padding(26)
        .frame(minWidth: 760, minHeight: 480)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack {
            if case .windows(let id) = model.state.screen {
                Button { model.send(.escape) } label: { Label("Applications", systemImage: "chevron.left") }.buttonStyle(.plain)
                Text(model.state.applications.first { $0.id == id }?.name ?? "Windows").font(.title.bold())
            } else { Text("Applications").font(.title.bold()) }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    if case .applications = model.state.screen {
                        ForEach(Array(model.state.applications.enumerated()), id: \.element.id) { index, app in
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
            .onAppear { proxy.scrollTo(model.state.selectedIndex) }
            .onChange(of: model.state.selectedIndex) { _, index in proxy.scrollTo(index) }
        }
    }

    private var footer: some View {
        HStack { Text("← ↑ ↓ → Select   ⏎ Confirm   esc Back"); Spacer(); Text("1–9 Quick select") }
            .font(.caption).foregroundStyle(.secondary)
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 42))
            Text("Permissions Required").font(.title2.bold())
            Text(permissionMessage).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack { Button("Request Permissions") { model.requestPermissions() }; Button("Open System Settings") { model.openSettings() } }
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
