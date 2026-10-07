import AppKit
import MergeportCore
import SwiftUI

@main
struct MergeportApp: App {
    @StateObject private var model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        LegacyMigration.run()
    }

    var body: some Scene {
        Window("Mergeport", id: "main") {
            MainWindow().environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1380, height: 900)
        .windowStyle(.titleBar)
        .commands { PullRequestCommands(model: model) }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

private struct PullRequestCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
        CommandGroup(before: .sidebar) {
            Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
            Divider()
            Button(model.tabLayout == .sidebar ? "Show Tabs in Top Bar" : "Show Tabs in Sidebar") {
                model.tabLayout = model.tabLayout == .sidebar ? .topBar : .sidebar
            }
            Divider()
        }
        CommandMenu("Go") {
            Button("Quick Open…") { model.showPalette.toggle() }.keyboardShortcut("k")
            Divider()
            Button("Overview") { model.selectTab(nil) }.keyboardShortcut("1")
            Button("Last Tab") { model.selectTab(number: 9) }.keyboardShortcut("9").disabled(model.tabs.isEmpty)
            Divider()
            ForEach(SidebarDestination.allCases, id: \.self) { destination in
                Button(destination.title) { model.go(to: destination) }
                    .keyboardShortcut(KeyEquivalent(destination.key))
            }
        }
        CommandMenu("Pull Requests") {
            Button("Previous Tab") { model.selectAdjacentTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Tab") { model.selectAdjacentTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Search Pull Requests") {
                model.selectTab(nil)
                model.searchFocusRequested = true
            }.keyboardShortcut("f")
            Button("Refresh Overview") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isConnected || model.isRefreshing)
            Button("Reload Current View") { model.reloadSelected() }.keyboardShortcut("r")
            Divider()
            Button("Close Review Tab") {
                if let id = model.selectedTab { model.closeTab(id) }
            }.keyboardShortcut("w")
            Button("Close Other Tabs") {
                if let id = model.selectedTab { model.closeOtherTabs(id) }
            }.disabled(model.selectedTab == nil || model.tabs.count < 2)
            Button("Close Merged and Closed Tabs") { model.closeFinishedTabs(all: true) }
                .disabled(model.finishedTabs.isEmpty)
            Divider()
            Button("Manage Repositories…") { model.showRepositories = true }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var smokeWindow: NSWindow?
    private var navigationMonitor: Any?
    private var modifierMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdates.shared.start()
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            Self.navigate(event) ? nil : event
        }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Only a bare ⌘ reveals hints; typing a shortcut hides them again.
            let show = event.type == .flagsChanged && flags == .command && AppModel.shortcutHintsEnabled
            if AppModel.shared.showShortcutHints != show { AppModel.shared.showShortcutHints = show }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.showShortcutHints = false }
        }
        guard ProcessInfo.processInfo.arguments.contains("--smoke-test") else { return }
        // Launched from a background shell, macOS may not activate the app and SwiftUI then does not
        // present the main window. Host the same view in an AppKit window so the smoke test can run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard !NSApp.windows.contains(where: { $0.title == "Mergeport" && $0.isVisible }) else { return }
            let root = MainWindow().environmentObject(AppModel.shared).frame(minWidth: 980, minHeight: 640)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Mergeport"
            window.setContentSize(NSSize(width: 1380, height: 900))
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            smokeWindow = window
        }
    }

    /// ⌘← / ⌘→ and the mouse's back/forward buttons, like a browser; ⌥⌘← / ⌥⌘→ switch tabs.
    /// Text fields keep these keys.
    private static func navigate(_ event: NSEvent) -> Bool {
        let model = AppModel.shared
        let back: Bool
        if event.type == .otherMouseDown {
            guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
            back = event.buttonNumber == 3
        } else {
            if handlesEscape(event) { return true }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            if flags == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit != 1, digit != 9,
               let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil {
                // ⌘0 is an alias for Overview (⌘1); ⌘2…⌘8 pick review tabs.
                if digit == 0 { model.selectTab(nil) } else { model.selectTab(number: digit) }
                return true
            }
            guard flags == .command || flags == [.command, .option],
                  event.keyCode == 123 || event.keyCode == 124,
                  let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil
            else { return false }
            if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
            back = event.keyCode == 123
            if flags.contains(.option) {
                model.selectAdjacentTab(back ? -1 : 1)
                return true
            }
        }
        guard back ? model.canGoBack : model.canGoForward else { return false }
        if back { model.goBack() } else { model.goForward() }
        return true
    }

    /// Esc closes the ⌘K palette. Elsewhere in the main window nothing handles it, and AppKit
    /// would beep at the end of the responder chain, so swallow it. Sheets and text editing keep Esc.
    static func handlesEscape(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, event.keyCode == 53, flags.isEmpty,
              let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              !(window is NSPanel)
        else { return false }
        if AppModel.shared.showPalette {
            AppModel.shared.showPalette = false
            return true
        }
        if let text = window.firstResponder as? NSTextView, text.isEditable {
            // Esc in the Overview search clears and leaves the field instead of beeping.
            guard text.isFieldEditor else { return false }
            if !AppModel.shared.search.isEmpty { AppModel.shared.search = "" }
            window.makeFirstResponder(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

