import AppKit
import MergeportCore
import SwiftUI

/// Sidebar destinations with fixed ⌘-letter shortcuts. Letters avoid standard
/// macOS keys (⌘A select all, ⌘M minimize, ⌘W close, ⌘R reload, ⌘F find).
enum SidebarDestination: CaseIterable, Hashable {
    case all, mine, requested, draft, attention, review, waiting, ready

    var key: Character {
        switch self {
        case .all: "o"
        case .mine: "p"
        case .requested: "i"
        case .draft: "d"
        case .attention: "n"
        case .review: "y"
        case .waiting: "t"
        case .ready: "g"
        }
    }

    var keyLabel: String { "⌘" + String(key).uppercased() }

    var scope: InboxScope? {
        switch self {
        case .all: .all
        case .mine: .mine
        case .requested: .review
        default: nil
        }
    }

    var stage: WorkflowStage? {
        switch self {
        case .draft: .draft
        case .attention: .attention
        case .review: .review
        case .waiting: .waiting
        case .ready: .ready
        default: nil
        }
    }

    var title: String { scope?.title ?? stage?.title ?? "" }
    var symbol: String {
        if let stage { return stage.symbol }
        return self == .all ? "tray.full" : self == .mine ? "person" : "text.bubble"
    }

    static func forScope(_ scope: InboxScope) -> Self {
        allCases.first { $0.scope == scope }!
    }

    static func forStage(_ stage: WorkflowStage) -> Self {
        allCases.first { $0.stage == stage }!
    }
}

extension AppModel {
    static let shortcutHintsKey = "showShortcutHints"

    static var shortcutHintsEnabled: Bool {
        UserDefaults.standard.object(forKey: shortcutHintsKey) as? Bool ?? true
    }

    func go(to destination: SidebarDestination) {
        if let stage = destination.stage {
            showOverview(scope: .all, stage: stage)
        } else {
            showOverview(scope: destination.scope)
        }
    }

    /// ⌘2…⌘8 select review tabs 1…7; ⌘9 selects the last tab, like Safari.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 2
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    static func tabShortcut(index: Int, count: Int) -> String? {
        if index < 7 { return "⌘\(index + 2)" }
        return index == count - 1 ? "⌘9" : nil
    }
}

struct ShortcutHint: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            .fixedSize()
    }
}

// MARK: - ⌘K palette

private struct PaletteItem: Identifiable {
    enum Action {
        case pr(PullRequest)
        case linear(LinearIssue)
        case destination(SidebarDestination)
        case repository(String)
        case run(() -> Void)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let shortcut: String?
    let score: Int
    let action: Action
    var pr: PullRequest? { if case .pr(let pr) = action { pr } else { nil } }
}

struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Jump to a PR, ticket, repository or view…", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { run(items, external: NSEvent.modifierFlags.contains(.command)) }
                ShortcutHint(label: "esc")
            }.padding(14)
            Divider()
            if items.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { selection = index; run(items, external: false) }
                            }
                        }.padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "select"); hint("↩", "open")
                if items.indices.contains(selection), items[selection].pr != nil {
                    hint("⌘↩", "open on GitHub")
                }
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .onAppear(perform: focusField)
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { model.showPalette = false; return .handled }
    }

    /// The previous first responder (Overview search, diff, web view) can keep focus when the
    /// overlay appears, so resign it first and retry once after layout.
    private func focusField() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { focused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { ShortcutHint(label: key); Text(label) }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 20)
            if let pr = item.pr {
                VStack(alignment: .leading, spacing: 4) {
                    PRKeyFacts(pr: pr, ticket: model.ticket(for: pr), issue: model.linearIssue(for: pr)).fixedSize()
                    Text(pr.title).lineLimit(1)
                }
            } else {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty { Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut { ShortcutHint(label: shortcut) }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func run(_ items: [PaletteItem], external: Bool) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        model.showPalette = false
        switch item.action {
        case .pr(let pr):
            if external { model.openExternal(pr.url) } else { model.open(pr) }
        case .linear(let issue):
            model.openExternal(issue.url)
        case .destination(let destination):
            model.go(to: destination)
        case .repository(let repo):
            model.showOverview(scope: .all, repository: repo)
        case .run(let action):
            action()
        }
    }

    private var results: [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ id: String, _ title: String, _ subtitle: String = "", symbol: String, color: Color = .secondary,
                 shortcut: String? = nil, identifiers: [String] = [], details: [String] = [], boost: Int = 0,
                 _ action: PaletteItem.Action) {
            guard let score = QuickSearch.score(query, identifiers: identifiers, title: title, details: details + [subtitle])
            else { return }
            items.append(PaletteItem(id: id, title: title, subtitle: subtitle, symbol: symbol, color: color,
                                     shortcut: shortcut, score: score + boost, action: action))
        }
        let tabIDs = Dictionary(model.tabs.enumerated().map { ($1.pr.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let prs = (model.tabs.map(\.pr) + model.pullRequests.sorted { $0.updatedAt > $1.updatedAt })
            .filter { seen.insert("\($0.repository)#\($0.number)").inserted }
        for (rank, pr) in prs.enumerated() {
            let ticket = model.ticket(for: pr)
            let issue = model.linearIssue(for: pr)
            let tabIndex = model.tabs.firstIndex { $0.pr.repository == pr.repository && $0.pr.number == pr.number }
            let status = YardPalette.status(pr)
            add("pr:\(pr.repository)#\(pr.number)", pr.title, symbol: status.symbol, color: status.color,
                shortcut: tabIndex.flatMap { AppModel.tabShortcut(index: $0, count: model.tabs.count) },
                identifiers: [String(pr.number), "#" + String(pr.number)] + (ticket.map { [$0] } ?? []),
                details: [pr.repository, pr.head, pr.base, pr.author, issue?.title ?? ""],
                boost: (tabIDs[pr.id] != nil ? 40 : 0) + max(0, 30 - rank), .pr(pr))
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty || items.count < 12 else {
            return navigationItems() + Array(items.prefix(12))
        }
        var tickets = Set<String>()
        for pr in prs {
            guard let issue = model.linearIssue(for: pr), tickets.insert(issue.identifier).inserted else { continue }
            add("linear:\(issue.identifier)", "Open \(issue.identifier) in Linear", issue.title,
                symbol: "arrow.up.forward.square", color: .ticketInk,
                identifiers: [issue.identifier], details: ["linear", issue.state], boost: -50, .linear(issue))
        }
        items += navigationItems()
        return items.sorted { $0.score > $1.score }.prefix(60).map { $0 }
    }

    private func navigationItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ id: String, _ title: String, _ subtitle: String, symbol: String, color: Color = .secondary,
                 shortcut: String? = nil, _ action: PaletteItem.Action) {
            guard let score = QuickSearch.score(query, identifiers: [], title: title, details: [subtitle]) else { return }
            items.append(PaletteItem(id: id, title: title, subtitle: subtitle, symbol: symbol, color: color,
                                     shortcut: shortcut, score: score, action: action))
        }
        add("overview", "Overview", "Go to", symbol: "square.grid.2x2", shortcut: "⌘1", .run { [model] in model.selectTab(nil) })
        for destination in SidebarDestination.allCases {
            add("dest:\(destination)", destination.title, "Show in Overview", symbol: destination.symbol,
                color: destination.stage.map(YardPalette.color) ?? .secondary,
                shortcut: destination.keyLabel, .destination(destination))
        }
        for repo in model.knownRepositories {
            add("repo:\(repo)", repo, "Repository", symbol: "shippingbox", .repository(repo))
        }
        add("refresh", "Refresh", "Reload pull requests from GitHub", symbol: "arrow.clockwise", shortcut: "⇧⌘R",
            .run { [model] in Task { await model.refresh() } })
        add("repos", "Manage repositories…", "Follow repositories", symbol: "plus", .run { [model] in model.showRepositories = true })
        return items
    }
}
