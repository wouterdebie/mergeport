import AppKit
import Carbon.HIToolbox
import Combine
import MergeportCore
import SwiftUI

/// The always-on-top status panel and the menu bar item that toggles it.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = StatusPanelController()
    static let panelTitle = "Mergeport Status"

    private(set) var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var updateScheduled = false
    private var hovering = false
    private var model: AppModel { AppModel.shared }

    func start() {
        guard cancellables.isEmpty else { return }
        model.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: center.publisher(for: NSApplication.didResignActiveNotification))
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        GlobalHotKey.onPress = { AppModel.shared.showStatusPanel.toggle() }
        update()
    }

    /// Published properties notify before they change; apply the new state on the next run loop turn.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateScheduled = false
                self?.update()
            }
        }
    }

    private func update() {
        updatePanel()
        updateStatusItem()
        if model.panelHotKey, hotKey == nil {
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey))
        } else if !model.panelHotKey {
            hotKey = nil
        }
    }

    // MARK: Panel

    private func updatePanel() {
        guard model.showStatusPanel else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        let mainInFront = NSApp.isActive && NSApp.windows.contains {
            $0.title == "Mergeport" && $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel)
        }
        if model.panelHidesWithApp && mainInFront {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        applyFade(animated: false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = Self.panelTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 270, height: 220)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: StatusPanelView { [weak self] inside in
            self?.hovering = inside
            self?.applyFade(animated: true)
        }.environmentObject(model))
        if !panel.setFrameUsingName("MergeportStatusPanel"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - panel.frame.height - 16))
        }
        panel.setFrameAutosaveName("MergeportStatusPanel")
        self.panel = panel
        return panel
    }

    private func applyFade(animated: Bool) {
        guard let panel else { return }
        let alpha: CGFloat = model.panelFadesWhenIdle && !hovering ? 0.45 : 1
        guard panel.alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = alpha }
        } else {
            panel.alphaValue = alpha
        }
    }

    func windowWillClose(_ notification: Notification) {
        if model.showStatusPanel { model.showStatusPanel = false }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard model.showMenuBarItem else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? makeStatusItem()
        let count = model.pullRequests.filter { StatusPanel.needsYou($0, login: model.login) }.count
        let unseen = model.unseenChanges.count
        item.button?.title = count > 0 ? String(count) : ""
        item.button?.imagePosition = count > 0 ? .imageLeading : .imageOnly
        var help = count == 1 ? "1 pull request needs you" : "\(count) pull requests need you"
        if unseen > 0 { help += unseen == 1 ? " · 1 update" : " · \(unseen) updates" }
        item.button?.toolTip = help + "\nClick to toggle the status panel; right-click for more."
        // Tinted while there are updates you haven't seen.
        item.button?.contentTintColor = unseen > 0 ? .controlAccentColor : nil
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Mergeport")
        statusItem = item
        return item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let statusItem else { return }
            statusItem.menu = makeMenu()
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            model.showStatusPanel.toggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add(model.showStatusPanel ? "Hide Status Panel" : "Show Status Panel", #selector(togglePanel))
        add("Open Mergeport", #selector(openMain))
        add("Refresh", #selector(refreshNow))
        if !model.unseenChanges.isEmpty { add("Mark All as Seen", #selector(markAllSeen)) }
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        add("Quit Mergeport", #selector(quit), key: "q")
        return menu
    }

    @objc private func togglePanel() { model.showStatusPanel.toggle() }
    @objc private func openMain() { model.revealMainWindow() }
    @objc private func refreshNow() { Task { await model.refresh() } }
    @objc private func markAllSeen() { model.markAllSeen() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// A system-wide shortcut through Carbon; unlike an event monitor it needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static var onPress: (() -> Void)?
    nonisolated(unsafe) private var reference: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?

    init?(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4D52_4750), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct StatusPanelView: View {
    @EnvironmentObject var model: AppModel
    var onHover: (Bool) -> Void = { _ in }
    @AppStorage("panelCollapsedLanes") private var collapsedLanes = ""
    @State private var hoveredRow: String?

    private var prs: [PullRequest] {
        model.pullRequests.filter { $0.state == "OPEN" && model.panelFilter.includes($0, login: model.login) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onHover(perform: onHover)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pull requests").font(.callout.weight(.semibold))
            Spacer(minLength: 4)
            if !model.unseenChanges.isEmpty {
                Button { model.markAllSeen() } label: {
                    Label("\(model.unseenChanges.count) new", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless).help("Mark all updates as seen")
            }
            Menu {
                Picker("Show", selection: $model.panelFilter) {
                    ForEach(PanelFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Text(model.panelFilter.title).font(.caption)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Which pull requests to show")
            Button { Task { await model.refresh() } } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.borderless).disabled(model.isRefreshing || model.isDemo).help("Refresh now")
        }
        // The title bar is transparent; leave room for the close button.
        .padding(.leading, 30).padding(.trailing, 10).frame(height: 30)
    }

    @ViewBuilder private var content: some View {
        if !model.isConnected && !model.isDemo {
            placeholder("Connect GitHub in Mergeport to see your pull requests.", symbol: "person.crop.circle.badge.questionmark")
        } else if prs.isEmpty {
            placeholder(model.snapshot == nil ? "Loading pull requests…" : "Nothing open here. Enjoy the quiet.",
                        symbol: "checkmark.seal")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(StatusPanel.lanes, id: \.self) { stage in
                        let items = lane(stage)
                        if !items.isEmpty { laneSection(stage, items) }
                    }
                }.padding(8)
            }
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lane(_ stage: WorkflowStage) -> [PullRequest] {
        TabGroups.clustered(prs.filter { $0.stage == stage }.sorted(by: PullRequest.overviewOrder)) {
            model.tabsRelated($0, $1)
        }
    }

    private func isCollapsed(_ stage: WorkflowStage) -> Bool {
        collapsedLanes.split(separator: ",").contains { $0 == stage.rawValue }
    }

    private func toggle(_ stage: WorkflowStage) {
        var lanes = Set(collapsedLanes.split(separator: ",").map(String.init))
        if lanes.contains(stage.rawValue) { lanes.remove(stage.rawValue) } else { lanes.insert(stage.rawValue) }
        collapsedLanes = lanes.sorted().joined(separator: ",")
    }

    private func laneSection(_ stage: WorkflowStage, _ items: [PullRequest]) -> some View {
        let collapsed = isCollapsed(stage)
        let unseen = items.filter { model.unseenChanges[$0.id] != nil }.count
        return VStack(alignment: .leading, spacing: 2) {
            Button { toggle(stage) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(.tertiary).frame(width: 10)
                    Image(systemName: stage.symbol).foregroundStyle(YardPalette.color(stage))
                    Text(stage.title).fontWeight(.semibold)
                    Text(String(items.count)).monospacedDigit().foregroundStyle(.secondary)
                    if unseen > 0 { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Spacer()
                }
                .font(.caption).padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open All in Mergeport (\(items.count))") {
                    model.openAll(items)
                    if let first = items.first { model.open(first) }
                    model.revealMainWindow()
                }
            }
            if !collapsed {
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ pr: PullRequest) -> some View {
        let status = YardPalette.status(pr)
        let ticket = model.ticket(for: pr)
        let change = model.unseenChanges[pr.id]
        let detail = pr.stage == .ready ? "Ready to merge" : pr.waitingReason
        let multipleRepos = Set(prs.map(\.repository)).count > 1
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol).foregroundStyle(status.color).frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(TabGroups.title(pr.title, without: ticket)).lineLimit(1).truncationMode(.tail)
                        .fontWeight(change == nil ? .regular : .semibold)
                    Spacer(minLength: 4)
                    Text(StatusPanel.age(pr.updatedAt)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                HStack(spacing: 5) {
                    Text(pr.displayNumber).monospacedDigit()
                    if let ticket { Text(ticket).monospaced() }
                    if multipleRepos {
                        Text(pr.repository.split(separator: "/").last.map(String.init) ?? pr.repository)
                            .lineLimit(1).layoutPriority(-1)
                    }
                    Text("→ " + pr.base).monospaced().foregroundStyle(Color.branchBlue).lineLimit(1).layoutPriority(-1)
                    if !pr.isMine(model.login) { Text("@" + pr.author).lineLimit(1).layoutPriority(-2) }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let change {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text(change).fontWeight(.semibold).foregroundStyle(Color.accentColor).lineLimit(1)
                    } else {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    indicators(pr)
                }
                .font(.caption)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(hoveredRow == pr.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { inside in
            if inside { hoveredRow = pr.id } else if hoveredRow == pr.id { hoveredRow = nil }
        }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) {
                model.markSeen(pr.id)
                NSWorkspace.shared.open(pr.url)
            } else {
                model.open(pr)
                model.revealMainWindow()
            }
        }
        .contextMenu {
            Button("Open in Mergeport") { model.open(pr); model.revealMainWindow() }
            Button("Open on GitHub") { model.markSeen(pr.id); NSWorkspace.shared.open(pr.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            }
            if change != nil {
                Divider()
                Button("Mark as Seen") { model.markSeen(pr.id) }
            }
        }
        .help("\(pr.displayTitle)\nClick to open in Mergeport, ⌥-click to open on GitHub")
    }

    @ViewBuilder private func indicators(_ pr: PullRequest) -> some View {
        HStack(spacing: 6) {
            if pr.blockingUnresolved > 0 {
                Label(String(pr.blockingUnresolved), systemImage: "bubble.left")
                    .labelStyle(.titleAndIcon).foregroundStyle(.orange).help("\(pr.blockingUnresolved) unresolved threads")
            }
            if pr.copilot == .requested {
                Image(systemName: "sparkles").foregroundStyle(.purple).help(pr.copilot.title)
            }
            switch pr.checks {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(pr.checks.title)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(pr.checks.title)
            case .pending: Image(systemName: "clock.fill").foregroundStyle(.orange).help(pr.checks.title)
            case .none, .unknown: EmptyView()
            }
        }
        .font(.caption2).monospacedDigit()
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if let error = model.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1).truncationMode(.tail).help(error)
                } else if let last = model.lastRefreshed {
                    Text("Updated " + (StatusPanel.age(last, now: context.date) == "now"
                        ? "just now" : StatusPanel.age(last, now: context.date) + " ago"))
                }
                Spacer(minLength: 4)
                let count = model.pullRequests.filter { StatusPanel.needsYou($0, login: model.login) }.count
                Text(count == 1 ? "1 needs you" : "\(count) need you").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 26)
        }
    }
}
