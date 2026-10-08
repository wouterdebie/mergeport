import AppKit
import Combine
import Foundation
import MergeportCore
import WebKit

struct ReviewTab: Identifiable, Codable {
    var pr: PullRequest
    var location: URL
    /// When a refresh first saw this PR merged or closed; nil if it was already finished when opened.
    var finishedAt: Date? = nil
    var id: String { pr.id }
}

private struct SavedWorkspace: Codable {
    var snapshot: InboxSnapshot?
    var tabs: [ReviewTab]
    var selectedTab: String?
    var drafts: [String: ReviewDraft]?
    var changes: [String: String]?
}

/// Where the user is in the app, for back/forward navigation.
struct NavigationPlace: Equatable {
    var tab: String?
    var section: ReviewSection?
    var scope: InboxScope
    var stage: WorkflowStage?
    var repository: String?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var snapshot: InboxSnapshot?
    @Published var tabs: [ReviewTab] = []
    @Published var selectedTab: String?
    @Published var scope: InboxScope = .all
    @Published var stageFilter: WorkflowStage?
    @Published var repositoryFilter: String?
    @Published var search = ""
    @Published var searchFocusRequested = false
    @Published var customClientID: String
    @Published var settingsTab: SettingsTab = .general
    @Published var repositories: [String]
    @Published var refreshInterval: Int
    @Published var tabGrouping: TabGrouping {
        didSet {
            guard tabGrouping != oldValue else { return }
            defaults.set(tabGrouping.rawValue, forKey: "tabGrouping")
            tabs = TabGroups.clustered(tabs) { tabsRelated($0.pr, $1.pr) }
            persistWorkspace()
        }
    }
    @Published var tabLayout: TabLayout {
        didSet { if !isDemo { defaults.set(tabLayout.rawValue, forKey: "tabLayout") } }
    }
    @Published var tabAutoClose: TabAutoClose {
        didSet {
            if !isDemo { defaults.set(tabAutoClose.rawValue, forKey: "tabAutoClose") }
            closeFinishedTabs()
        }
    }
    @Published var showStatusPanel: Bool {
        didSet { if !isDemo { defaults.set(showStatusPanel, forKey: "showStatusPanel") } }
    }
    @Published var showMenuBarItem: Bool {
        didSet { if !isDemo { defaults.set(showMenuBarItem, forKey: "showMenuBarItem") } }
    }
    @Published var panelFilter: PanelFilter {
        didSet { if !isDemo { defaults.set(panelFilter.rawValue, forKey: "panelFilter") } }
    }
    @Published var panelFadesWhenIdle: Bool {
        didSet { if !isDemo { defaults.set(panelFadesWhenIdle, forKey: "panelFadesWhenIdle") } }
    }
    @Published var panelHidesWithApp: Bool {
        didSet { if !isDemo { defaults.set(panelHidesWithApp, forKey: "panelHidesWithApp") } }
    }
    @Published var panelHotKey: Bool {
        didSet { if !isDemo { defaults.set(panelHotKey, forKey: "panelHotKey") } }
    }
    /// What a refresh changed on PRs you haven't opened since, keyed by PR id.
    @Published private(set) var unseenChanges: [String: String] = [:]
    @Published private(set) var lastRefreshed: Date?
    /// The main window is on screen and in front; auto-refresh also runs while the status panel shows.
    var mainWindowActive = false
    /// Set by the main window so AppKit code (status panel, menu bar) can reopen it after it was closed.
    var openMainWindow: (() -> Void)?
    private var autoRefreshTask: Task<Void, Never>?
    @Published var isConnected = false
    @Published var isRefreshing = false
    @Published var isSigningIn = false
    @Published var isSigningOut = false
    @Published var deviceCode: DeviceCode?
    @Published var error: String?
    @Published var showConnection = false
    @Published var tabToClose: ReviewTab?
    @Published var showRepositories = false
    @Published var isDemo = false
    @Published private(set) var groupingPreferences = GroupingPreferences()
    @Published var branchGroupingTarget: PullRequest?
    @Published var showGroupingSettings = false
    @Published private(set) var backStack: [NavigationPlace] = []
    @Published private(set) var forwardStack: [NavigationPlace] = []
    @Published var linearIssues: [String: LinearIssue] = [:]
    @Published var linearViewer: LinearViewer?
    @Published var isConnectingLinear = false
    @Published var linearError: String?
    @Published var showPalette = false
    /// True while ⌘ is held, to reveal shortcut hints in the sidebar and tab bar.
    @Published var showShortcutHints = false
    private var currentPlace: NavigationPlace?
    private var navigationObserver: AnyCancellable?
    private var canonicalBranches: [BranchIdentity: String] = [:]

    let bundledClientID: String?
    private var reviewModels: [String: ReviewModel] = [:]
    private var reviewDrafts: [String: ReviewDraft] = [:]
    private let defaults: UserDefaults
    private var token: String?
    private var authTask: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var pendingRefresh = false
    private var preloadTask: Task<Void, Never>?
    private var pendingPreload = false
    let networkSession = URLSession(configuration: .ephemeral)
    let linearClientID: String?
    var linearToken: LinearToken?
    var linearAuthTask: Task<Void, Never>?
    var linearRefreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundledClientID = Bundle.main.object(forInfoDictionaryKey: GitHubOAuthConfiguration.bundleInfoKey) as? String
        customClientID = defaults.string(forKey: "customOAuthClientID") ?? defaults.string(forKey: "oauthClientID") ?? ""
        repositories = defaults.stringArray(forKey: "repositories") ?? []
        let interval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = [60, 120, 300, 600].contains(interval) ? interval : 120
        tabGrouping = defaults.string(forKey: "tabGrouping").flatMap(TabGrouping.init(rawValue:)) ?? .related
        tabLayout = defaults.string(forKey: "tabLayout").flatMap(TabLayout.init(rawValue:)) ?? .topBar
        tabAutoClose = defaults.string(forKey: "tabAutoClose").flatMap(TabAutoClose.init(rawValue:)) ?? .off
        showStatusPanel = defaults.bool(forKey: "showStatusPanel")
        showMenuBarItem = defaults.object(forKey: "showMenuBarItem") as? Bool ?? true
        panelFilter = defaults.string(forKey: "panelFilter").flatMap(PanelFilter.init(rawValue:)) ?? .involved
        panelFadesWhenIdle = defaults.bool(forKey: "panelFadesWhenIdle")
        panelHidesWithApp = defaults.bool(forKey: "panelHidesWithApp")
        panelHotKey = defaults.bool(forKey: "panelHotKey")
        linearClientID = (Bundle.main.object(forInfoDictionaryKey: LinearOAuth.bundleInfoKey) as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        defer { trackNavigation() }
        if let stored = defaults.data(forKey: "groupingPreferences") {
            do { try installGrouping(JSONDecoder().decode(GroupingPreferences.self, from: stored), persist: false) }
            catch { report(MergeportError.message("Saved grouping configuration could not be loaded: \(error.localizedDescription)")) }
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            isDemo = true
            snapshot = DemoInbox.snapshot
            linearIssues = DemoLinear.issues
            unseenChanges = DemoInbox.changes
            lastRefreshed = .now.addingTimeInterval(-90)
            return
        }
        loadLinear()
        do {
            token = try TokenVault.read()
            isConnected = token != nil
            if isConnected, let saved = defaults.data(forKey: "workspace") {
                let workspace = try JSONDecoder().decode(SavedWorkspace.self, from: saved)
                snapshot = workspace.snapshot
                tabs = TabGroups.clustered(
                    workspace.tabs.filter { GitHubNavigation.belongsTo($0.location, pr: $0.pr) },
                    related: { self.tabsRelated($0.pr, $1.pr) })
                selectedTab = tabs.contains { $0.id == workspace.selectedTab } ? workspace.selectedTab : nil
                reviewDrafts = workspace.drafts ?? [:]
                unseenChanges = workspace.changes ?? [:]
            }
        } catch {
            report(error)
        }
    }

    var login: String { snapshot?.viewer.login ?? "" }
    /// Token saved, inbox not loaded yet. Settings must not call that "Not connected" while offering Sign out.
    var accountStatus: String {
        if !login.isEmpty { return "@\(login)" }
        if isConnected { return "Signed in" }
        return "Not connected"
    }
    var pullRequests: [PullRequest] { snapshot?.pullRequests ?? [] }
    var knownRepositories: [String] { Set(repositories + pullRequests.map(\.repository)).sorted() }
    var activeTab: ReviewTab? { tabs.first { $0.id == selectedTab } }
    var accountSessionID: UUID { generation }
    var hasRunningMutations: Bool { reviewModels.values.contains { $0.isPerforming } }
    var oauthConfiguration: GitHubOAuthConfiguration {
        GitHubOAuthConfiguration(bundledClientID: bundledClientID, customClientID: customClientID)
    }

    var filteredPRs: [PullRequest] {
        pullRequests.filter {
            scope.includes($0, login: login)
                && (stageFilter == nil || $0.stage == stageFilter)
                && (repositoryFilter == nil || $0.repository == repositoryFilter)
                && (search.isEmpty || "\($0.title) \($0.repository) #\($0.number) \($0.head) \($0.base) \($0.author)"
                    .localizedCaseInsensitiveContains(search))
        }.sorted(by: PullRequest.overviewOrder)
    }

    func start() async {
        guard !started else { return }
        started = true
        refreshActiveReview()
        preloadReviews()
        startAutoRefresh()
        if isConnected {
            if login.isEmpty { await rememberViewer() }
            await refresh()
        }
    }

    /// Refreshes on the configured interval while the main window is in front or the status panel shows.
    /// Owned by the model, not the window, so the panel keeps updating after the main window closes.
    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            var lastAttempt = Date.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                // Running checks resolve in minutes; poll faster so their outcome shows up promptly.
                let running = pullRequests.contains { $0.state == "OPEN" && $0.checks == .pending }
                let interval = Double(running ? min(refreshInterval, 30) : refreshInterval)
                let last = max(lastAttempt, lastRefreshed ?? .distantPast)
                guard Date.now.timeIntervalSince(last) >= interval, mainWindowActive || showStatusPanel else { continue }
                lastAttempt = .now
                await refresh()
            }
        }
    }

    private func trackChanges(from before: InboxSnapshot?, to result: InboxSnapshot) {
        lastRefreshed = .now
        let open = Set(result.pullRequests.map(\.id))
        var changes = unseenChanges.filter { open.contains($0.key) }
        if let before, before.viewer.login == result.viewer.login {
            changes.merge(StatusPanel.changes(from: before.pullRequests, to: result.pullRequests,
                                              login: result.viewer.login)) { $1 }
        }
        // You're looking at it right now; nothing to flag.
        if mainWindowActive, let selected = activeTab?.pr.id { changes[selected] = nil }
        if changes != unseenChanges { unseenChanges = changes }
    }

    func markSeen(_ id: String) {
        guard unseenChanges[id] != nil else { return }
        unseenChanges[id] = nil
        persistWorkspace()
    }

    func resetDemoChanges() {
        guard isDemo else { return }
        unseenChanges = DemoInbox.changes
    }

    func markAllSeen() {
        guard !unseenChanges.isEmpty else { return }
        unseenChanges.removeAll()
        persistWorkspace()
    }

    /// Brings the main window forward, reopening it if it was closed.
    func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Mergeport" && !($0 is NSPanel) && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// The OAuth token can be saved before any inbox snapshot exists. Keep the login so Settings stays consistent if the inbox fetch fails.
    private func rememberViewer() async {
        guard let token else { return }
        do {
            let viewer = try await GitHubClient(token: token, session: networkSession).viewer()
            guard snapshot?.viewer.login != viewer.login else { return }
            snapshot = InboxSnapshot(viewer: viewer, pullRequests: [])
            persistWorkspace()
        } catch {
            report(error)
        }
    }

    func refresh() async {
        guard !isDemo, !isSigningOut, let token else { return }
        if isRefreshing { pendingRefresh = true; return }
        let currentGeneration = generation
        let followed = repositories
        isRefreshing = true
        defer {
            if generation == currentGeneration {
                isRefreshing = false
                if pendingRefresh {
                    pendingRefresh = false
                    Task { await refresh() }
                }
            }
        }
        do {
            let client = GitHubClient(token: token, session: networkSession)
            let before = snapshot
            let previousLogin = snapshot?.viewer.login
            let result = try await client.snapshot(repositories: followed) { partial, loaded in
                await self.showListedInbox(partial, loaded: loaded, generation: currentGeneration, followed: followed)
            }
            var tabUpdates: [String: PullRequest] = [:]
            for tab in tabs {
                let fresh: PullRequest
                if let open = result.pullRequests.first(where: {
                    $0.repository == tab.pr.repository && $0.number == tab.pr.number
                }) { fresh = open }
                else { fresh = try await client.pullRequest(repository: tab.pr.repository, number: tab.pr.number, viewer: result.viewer.login) }
                tabUpdates[tab.id] = fresh
            }
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            if followed != repositories { pendingRefresh = true; return }
            if let previousLogin, previousLogin != result.viewer.login {
                tabs = []
                selectedTab = nil
                reviewModels.removeAll()
                reviewDrafts.removeAll()
                unseenChanges.removeAll()
            }
            snapshot = result
            trackChanges(from: before, to: result)
            for index in tabs.indices {
                if var fresh = tabUpdates[tabs[index].id] {
                    fresh.id = tabs[index].id
                    if fresh.state == "OPEN" {
                        tabs[index].finishedAt = nil
                    } else if tabs[index].pr.state == "OPEN" {
                        tabs[index].finishedAt = .now
                    }
                    tabs[index].pr = fresh
                }
            }
            error = nil
            closeFinishedTabs()
            persistWorkspace()
            refreshActiveReview()
            preloadReviews()
            refreshLinear()
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            report(error)
        }
    }

    /// The list is available before mergeability is loaded. Show it immediately so a slow check does not look like an empty inbox.
    /// PRs still loading keep their previous details, so a background refresh doesn't flash every status to unknown.
    private func showListedInbox(
        _ result: InboxSnapshot, loaded: Set<String>, generation current: UUID, followed: [String]
    ) {
        guard generation == current, followed == repositories else { return }
        var listed = result
        if let previous = snapshot, previous.viewer.login == result.viewer.login {
            let known = Dictionary(previous.pullRequests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            listed.pullRequests = result.pullRequests.map { pr in
                guard !loaded.contains(pr.id), var kept = known[pr.id] else { return pr }
                kept.reviewRequested = pr.reviewRequested
                return kept
            }
        }
        snapshot = listed
        error = nil
    }

    func signIn() {
        guard !isSigningIn, !isSigningOut else { return }
        let id: String
        do { id = try oauthConfiguration.requireClientID() } catch { report(error); return }
        isSigningIn = true
        error = nil
        let currentGeneration = generation
        authTask = Task {
            defer {
                if generation == currentGeneration {
                    isSigningIn = false
                    deviceCode = nil
                    authTask = nil
                }
            }
            do {
                let oauth = GitHubOAuth(session: networkSession)
                let code = try await oauth.requestCode(clientID: id)
                try Task.checkCancellation()
                deviceCode = code
                openExternal(code.verificationURI)
                let credential = try await oauth.waitForToken(clientID: id, code: code)
                let viewer = try await GitHubClient(token: credential, session: networkSession).viewer()
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                try TokenVault.save(credential)
                if snapshot?.viewer.login != viewer.login {
                    tabs = []
                    selectedTab = nil
                    reviewModels.removeAll()
                    reviewDrafts.removeAll()
                    snapshot = InboxSnapshot(viewer: viewer, pullRequests: [])
                }
                token = credential
                isDemo = false
                isSigningIn = false
                deviceCode = nil
                isConnected = true
                showConnection = false
                NSApp.activate()
                persistWorkspace()
                await refresh()
            } catch is CancellationError {
                return
            } catch {
                if generation == currentGeneration { report(error) }
            }
        }
    }

    func cancelSignIn() {
        preloadTask?.cancel()
        preloadTask = nil
        pendingPreload = false
        authTask?.cancel()
        authTask = nil
        generation = UUID()
        isSigningIn = false
        deviceCode = nil
        isRefreshing = false
        pendingRefresh = false
    }

    func signOut() async {
        guard !isSigningOut else { return }
        guard !hasRunningMutations else { report(MergeportError.message("Wait for the GitHub action to finish before signing out.")); return }
        do { try TokenVault.delete() } catch { report(error); return }
        cancelSignIn()
        isSigningOut = true
        token = nil
        isConnected = false
        isDemo = false
        snapshot = nil
        tabs = []
        selectedTab = nil
        reviewModels.removeAll()
        reviewDrafts.removeAll()
        clearHistory()
        defaults.removeObject(forKey: "workspace")
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        isSigningOut = false
        error = nil
    }

    func preview() {
        guard !isConnected else { return }
        isDemo = true
        snapshot = DemoInbox.snapshot
        linearIssues = DemoLinear.issues
        selectedTab = nil
        showConnection = false
    }

    func leavePreview() {
        isDemo = false
        snapshot = nil
        loadLinear()
        tabs = []
        selectedTab = nil
        reviewModels.removeAll()
        reviewDrafts.removeAll()
        clearHistory()
    }

    func addRepository(_ input: String) throws {
        let name = try RepositoryName.validate(input)
        guard !repositories.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        repositories.append(name)
        repositories.sort()
        defaults.set(repositories, forKey: "repositories")
    }

    func removeRepository(_ name: String) {
        repositories.removeAll { $0 == name }
        defaults.set(repositories, forKey: "repositories")
        if repositoryFilter == name { repositoryFilter = nil }
    }

    func savePreferences() {
        defaults.set(customClientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "customOAuthClientID")
        defaults.removeObject(forKey: "oauthClientID")
        defaults.set(refreshInterval, forKey: "refreshInterval")
    }

    func open(_ pr: PullRequest, location: URL? = nil) {
        guard GitHubNavigation.belongsTo(pr.url, pr: pr) else {
            report(MergeportError.message("This PR has an invalid GitHub URL."))
            return
        }
        let existing = tabs.first { $0.pr.repository.lowercased() == pr.repository.lowercased() && $0.pr.number == pr.number }
        if let existing {
            selectedTab = existing.id
            if let location, GitHubNavigation.belongsTo(location, pr: pr),
               let index = tabs.firstIndex(where: { $0.id == existing.id }) {
                tabs[index].location = location
            }
        } else {
            let safeLocation = location.flatMap { GitHubNavigation.belongsTo($0, pr: pr) ? $0 : nil } ?? pr.url
            let tab = ReviewTab(pr: pr, location: safeLocation)
            tabs.insert(tab, at: TabGroups.insertionIndex(for: tab, in: tabs) { tabsRelated($0.pr, $1.pr) })
            selectedTab = pr.id
        }
        unseenChanges[pr.id] = nil
        persistWorkspace()
        refreshActiveReview()
    }

    /// Opens tabs for PRs that aren't open yet, keeping the current view; returns how many were added.
    @discardableResult
    func openAll(_ prs: [PullRequest]) -> Int {
        var added = 0
        for pr in prs where GitHubNavigation.belongsTo(pr.url, pr: pr)
            && !tabs.contains(where: { $0.pr.repository.lowercased() == pr.repository.lowercased() && $0.pr.number == pr.number }) {
            let tab = ReviewTab(pr: pr, location: pr.url)
            tabs.insert(tab, at: TabGroups.insertionIndex(for: tab, in: tabs) { tabsRelated($0.pr, $1.pr) })
            added += 1
        }
        guard added > 0 else { return 0 }
        persistWorkspace()
        preloadReviews()
        return added
    }

    func unopened(_ prs: [PullRequest]) -> [PullRequest] {
        prs.filter { pr in
            !tabs.contains { $0.pr.repository.lowercased() == pr.repository.lowercased() && $0.pr.number == pr.number }
        }
    }

    func openLinkedPR(_ url: URL) {
        guard let identity = GitHubNavigation.pullRequestIdentity(url) else { return }
        if let known = pullRequests.first(where: { GitHubNavigation.belongsTo(url, pr: $0) }) {
            open(known, location: url)
        } else {
            let canonical = URL(string: "https://github.com/\(identity.repository)/pull/\(identity.number)")!
            let reference = PullRequest(
                id: "web:\(identity.repository.lowercased())#\(identity.number)", number: identity.number,
                title: "\(identity.repository) #\(identity.number)", repository: identity.repository,
                url: canonical, author: "unknown", head: "unknown", base: "unknown"
            )
            open(reference, location: url)
            Task { await refresh() }
        }
    }

    func selectTab(_ id: String?) {
        selectedTab = id
        if let id { unseenChanges[id] = nil }
        closeFinishedTabs()
        persistWorkspace()
        refreshActiveReview()
    }

    /// Tabs that can close without asking: no unsent draft and no GitHub action in flight.
    private func canCloseQuietly(_ id: String) -> Bool {
        reviewModels[id]?.isPerforming != true
            && reviewModels[id]?.draft.hasContent != true && reviewDrafts[id]?.hasContent != true
    }

    /// Closes several tabs at once; tabs with unsent drafts or running actions stay open.
    func closeTabs(_ ids: [String]) {
        let closing = Set(ids.filter(canCloseQuietly))
        let kept = ids.filter { !closing.contains($0) }.compactMap { id in tabs.first { $0.id == id } }
        if !closing.isEmpty {
            let selectedIndex = tabs.firstIndex { $0.id == selectedTab }
            for id in closing {
                reviewModels[id]?.draft = ReviewDraft()
                reviewDrafts.removeValue(forKey: id)
            }
            tabs.removeAll { closing.contains($0.id) }
            if let selected = selectedTab, closing.contains(selected), let selectedIndex {
                let remaining = tabs.count
                selectedTab = remaining == 0 ? nil : tabs[min(selectedIndex, remaining - 1)].id
                refreshActiveReview()
            }
            persistWorkspace()
        }
        if !kept.isEmpty {
            report(MergeportError.message(
                "Kept \(PRStack.list(kept.map(\.pr.number))) open: unsent drafts or a GitHub action in progress."))
        }
    }

    func closeOtherTabs(_ id: String) { closeTabs(tabs.map(\.id).filter { $0 != id }) }

    /// The tab's group as shown in the tab bar or sidebar.
    func tabGroup(of id: String) -> [ReviewTab] {
        let runs = TabGroups.runs(tabs) { tabsRelated($0.pr, $1.pr) }
        guard let run = runs.first(where: { $0.contains { tabs[$0].id == id } }) else { return [] }
        return run.map { tabs[$0] }
    }

    func closeGroup(of id: String) { closeTabs(tabGroup(of: id).map(\.id)) }

    var finishedTabs: [ReviewTab] { tabs.filter { $0.pr.state != "OPEN" } }

    func closeFinishedTabs(all: Bool = false) {
        if all { closeTabs(finishedTabs.map(\.id)); return }
        let due = tabs.filter {
            $0.id != selectedTab && canCloseQuietly($0.id)
                && tabAutoClose.shouldClose(finishedAt: $0.finishedAt)
        }
        guard !due.isEmpty else { return }
        closeTabs(due.map(\.id))
    }

    /// Cycles through Overview and the review tabs, wrapping around like Safari.
    func selectAdjacentTab(_ offset: Int) {
        let ids: [String?] = [nil] + tabs.map(\.id)
        let current = ids.firstIndex(of: selectedTab) ?? 0
        selectTab(ids[(current + offset + ids.count) % ids.count])
    }

    func closeTab(_ id: String, discardingDraft: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard reviewModels[id]?.isPerforming != true else {
            report(MergeportError.message("Wait for the GitHub action to finish before closing this review."))
            return
        }
        if !discardingDraft && (reviewModels[id]?.draft.hasContent == true || reviewDrafts[id]?.hasContent == true) {
            tabToClose = tabs[index]
            return
        }
        tabs.remove(at: index)
        reviewModels[id]?.draft = ReviewDraft()
        reviewDrafts.removeValue(forKey: id)
        let closedActiveTab = selectedTab == id
        if closedActiveTab { selectedTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        persistWorkspace()
        if closedActiveTab { refreshActiveReview() }
    }

    func recordLocation(_ url: URL, tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              GitHubNavigation.belongsTo(url, pr: tabs[index].pr) else { return }
        tabs[index].location = url
        persistWorkspace()
    }

    func showOverview(scope: InboxScope? = nil, stage: WorkflowStage? = nil, repository: String? = nil) {
        if let scope { self.scope = scope }
        stageFilter = stage
        repositoryFilter = repository
        selectTab(nil)
    }

    var canGoBack: Bool { backStack.contains(where: isReachable) }
    var canGoForward: Bool { forwardStack.contains(where: isReachable) }

    func goBack() { step(back: true) }
    func goForward() { step(back: false) }

    private var place: NavigationPlace {
        NavigationPlace(tab: selectedTab, section: Self.section(of: selectedTab, in: tabs),
                        scope: scope, stage: stageFilter, repository: repositoryFilter)
    }

    private static func section(of id: String?, in tabs: [ReviewTab]) -> ReviewSection? {
        guard let id, let tab = tabs.first(where: { $0.id == id }) else { return nil }
        return ReviewSection(rawValue: tab.location.lastPathComponent) ?? .conversation
    }

    private func trackNavigation() {
        currentPlace = place
        // One user action can change several properties; the debounce records it as one step.
        navigationObserver = Publishers.CombineLatest3(
            Publishers.CombineLatest($selectedTab, $tabs), $scope, Publishers.CombineLatest($stageFilter, $repositoryFilter)
        )
            .map { tab, scope, filters in
                NavigationPlace(tab: tab.0, section: Self.section(of: tab.0, in: tab.1),
                                scope: scope, stage: filters.0, repository: filters.1)
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.record($0) }
    }

    private func record(_ next: NavigationPlace) {
        defer { currentPlace = next }
        guard let current = currentPlace, current != next else { return }
        backStack.append(current)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    private func isReachable(_ target: NavigationPlace) -> Bool {
        target.tab.map { id in tabs.contains { $0.id == id } } ?? true
    }

    private func step(back: Bool) {
        var source = back ? backStack : forwardStack
        while let target = source.popLast() {
            guard isReachable(target), target != place else { continue }
            if back {
                backStack = source
                forwardStack.append(place)
            } else {
                forwardStack = source
                backStack.append(place)
            }
            currentPlace = target
            scope = target.scope
            stageFilter = target.stage
            repositoryFilter = target.repository
            if let id = target.tab, let section = target.section { restoreSection(section, tabID: id) }
            if target.tab != selectedTab { selectTab(target.tab) }
            return
        }
        if back { backStack = [] } else { forwardStack = [] }
    }

    private func restoreSection(_ section: ReviewSection, tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              Self.section(of: tabID, in: tabs) != section else { return }
        let base = tabs[index].pr.url.absoluteString
        guard let url = URL(string: section == .conversation ? base : "\(base)/\(section.rawValue)") else { return }
        tabs[index].location = url
        reviewModels[tabID]?.section = section
        persistWorkspace()
    }

    private func clearHistory() {
        backStack = []
        forwardStack = []
        currentPlace = place
    }

    func siblings(_ pr: PullRequest) -> [PullRequest] {
        let identity = BranchIdentity(pr)
        let branch = canonicalBranch(pr)
        return pullRequests.filter {
            let other = BranchIdentity($0)
            return $0.number != pr.number && other.repository == identity.repository && other.sourceRepository == identity.sourceRepository
                && canonicalBranch($0) == branch
        }.sorted { $0.base < $1.base }
    }

    /// PRs worth jumping to from a review: the same branch into other bases (staging/main),
    /// then anything sharing its ticket, in any followed repository. Stack members are listed
    /// separately in the stack map, so they're left out here.
    func relatedPRs(_ pr: PullRequest) -> [PullRequest] {
        let branch = siblings(pr).filter { !sameStack(pr, $0) }
        let ticket = ticket(for: pr)
        let sameTicket = ticket.map { ticket in
            pullRequests.filter { other in
                !(other.repository == pr.repository && other.number == pr.number)
                    && !branch.contains { $0.id == other.id }
                    && !sameStack(pr, other)
                    && self.ticket(for: other) == ticket
            }.sorted(by: PullRequest.overviewOrder)
        } ?? []
        return branch + sameTicket
    }

    func sameStack(_ a: PullRequest, _ b: PullRequest) -> Bool {
        guard let left = a.stack, let right = b.stack else { return false }
        return left.number == right.number && a.repository.lowercased() == b.repository.lowercased()
    }

    /// The inbox copy of a stack member when we have it; otherwise a PR built from the stack entry
    /// (e.g. someone else's PR in the middle of your stack) so it can still open in a tab.
    func pullRequest(for entry: PRStack.Entry, stackOf pr: PullRequest) -> PullRequest {
        let tabbed = tabs.map(\.pr)
        if let known = (pullRequests + tabbed).first(where: {
            $0.repository.lowercased() == pr.repository.lowercased() && $0.number == entry.number
        }) { return known }
        var stack = pr.stack
        stack?.position = entry.position
        return PullRequest(
            id: entry.id, number: entry.number, title: entry.title, repository: pr.repository, url: entry.url,
            author: entry.author, head: entry.head, headRepository: pr.repository, base: entry.base,
            isDraft: entry.isDraft, state: entry.state, reviewDecision: entry.reviewDecision,
            mergeState: entry.mergeState, stack: stack)
    }

    /// Same source branch (staging/main pair), same GitHub stack or same Linear ticket.
    func isRelated(_ a: PullRequest, _ b: PullRequest) -> Bool {
        guard a.id != b.id else { return false }
        if sameBranch(a, b) || sameStack(a, b) { return true }
        guard let ticket = ticket(for: a) else { return false }
        return ticket == self.ticket(for: b)
    }

    func tabsRelated(_ a: PullRequest, _ b: PullRequest) -> Bool {
        guard a.id != b.id else { return false }
        switch tabGrouping {
        case .related: return isRelated(a, b)
        case .ticket: return ticket(for: a).map { $0 == ticket(for: b) } ?? false
        case .branch: return sameBranch(a, b)
        case .stack: return sameStack(a, b)
        case .repository: return a.repository.lowercased() == b.repository.lowercased()
        case .none: return false
        }
    }

    /// The label a tab group shows once, so its tabs don't repeat it.
    func tabGroupLabel(_ prs: [PullRequest]) -> String? {
        guard let first = prs.first, prs.count > 1 else { return nil }
        let tickets = Set(prs.map { ticket(for: $0) })
        let branches = Set(prs.map { canonicalBranch($0) })
        switch tabGrouping {
        case .ticket: return ticket(for: first)
        case .branch: return canonicalBranch(first)
        case .stack: return first.stack.map { "Stack #\($0.number)" }
        case .repository: return first.repository.split(separator: "/").last.map(String.init)
        case .none: return nil
        case .related:
            if tickets.count == 1, let ticket = tickets.first ?? nil { return ticket }
            if let stack = first.stack, prs.allSatisfy({ sameStack(first, $0) || $0.id == first.id }) {
                return "Stack #\(stack.number)"
            }
            if branches.count == 1 { return branches.first }
            return ticket(for: first) ?? canonicalBranch(first)
        }
    }

    private func sameBranch(_ a: PullRequest, _ b: PullRequest) -> Bool {
        let left = BranchIdentity(a), right = BranchIdentity(b)
        return left.repository == right.repository && left.sourceRepository == right.sourceRepository
            && canonicalBranch(a) == canonicalBranch(b)
    }

    func canonicalBranch(_ pr: PullRequest) -> String {
        let branch = canonicalBranches[BranchIdentity(pr)] ?? pr.head
        return groupingPreferences.mode == .branchGroups ? groupingPreferences.normalizedBranch(branch) : branch
    }

    func ticket(for pr: PullRequest) -> String? {
        try? groupingPreferences.ticketIdentifier(for: pr)
    }

    var groupingResult: Result<[PullRequestGroup], MergeportError> {
        do { return .success(try groupingPreferences.groups(for: filteredPRs)) }
        catch { return .failure(.message("Could not group pull requests: \(error.localizedDescription)")) }
    }

    func setGroupingMode(_ mode: PRGrouping) {
        var preferences = groupingPreferences
        preferences.mode = mode
        do { try applyGrouping(preferences) } catch { report(error) }
    }

    func applyGrouping(_ preferences: GroupingPreferences) throws {
        try installGrouping(preferences, persist: true)
    }

    private func installGrouping(_ preferences: GroupingPreferences, persist: Bool) throws {
        try preferences.validate()
        var canonical: [BranchIdentity: String] = [:]
        for alias in preferences.aliases { canonical[alias.source] = try preferences.canonicalBranch(alias.source) }
        let data = try JSONEncoder().encode(preferences)
        groupingPreferences = preferences
        canonicalBranches = canonical
        if persist && !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            defaults.set(data, forKey: "groupingPreferences")
        }
        if persist { refreshLinear() }
    }

    func attachBranch(_ pr: PullRequest, to target: String) throws {
        var preferences = groupingPreferences
        try preferences.addAlias(source: BranchIdentity(pr), target: target)
        try applyGrouping(preferences)
    }

    func removeBranchAlias(_ source: BranchIdentity) throws {
        var preferences = groupingPreferences
        preferences.aliases.removeAll { $0.source == source }
        try applyGrouping(preferences)
    }

    func reloadSelected() {
        if let selectedTab, let review = reviewModels[selectedTab] { Task { await review.load(force: true) } }
        else { Task { await refresh() } }
    }

    func githubClient() throws -> GitHubClient {
        guard isConnected, let token else { throw MergeportError.message("Connect GitHub to load and submit real PR reviews.") }
        return GitHubClient(token: token, session: networkSession)
    }

    func reviewModel(for tab: ReviewTab) -> ReviewModel {
        if let review = reviewModels[tab.id] { return review }
        let review = ReviewModel(tab: tab, app: self, draft: reviewDrafts[tab.id] ?? ReviewDraft())
        reviewModels[tab.id] = review
        return review
    }

    private func refreshActiveReview() {
        guard let tab = activeTab else { return }
        let review = reviewModel(for: tab)
        review.section = ReviewSection(rawValue: tab.location.lastPathComponent) ?? .conversation
        Task { await review.load(force: true) }
    }

    func preloadReviews() {
        guard isConnected || isDemo else { return }
        if preloadTask != nil {
            pendingPreload = true
            return
        }
        let sessionID = generation
        let requests = pullRequests
        let retainedIDs = Set(requests.map(\.id) + tabs.map(\.id))
        reviewModels = reviewModels.filter { retainedIDs.contains($0.key) || $0.value.isLoading }
        preloadTask = Task {
            async let first: Void = preloadWorker(requests, offset: 0, sessionID: sessionID)
            async let second: Void = preloadWorker(requests, offset: 1, sessionID: sessionID)
            _ = await (first, second)
            guard generation == sessionID else { return }
            preloadTask = nil
            if pendingPreload {
                pendingPreload = false
                preloadReviews()
            }
        }

    }

    private func preloadWorker(_ requests: [PullRequest], offset: Int, sessionID: UUID) async {
        for index in stride(from: offset, to: requests.count, by: 2) {
            guard !Task.isCancelled, generation == sessionID else { return }
            let pr = requests[index]
            let tab = tabs.first(where: {
                $0.pr.repository.lowercased() == pr.repository.lowercased() && $0.pr.number == pr.number
            }) ?? ReviewTab(pr: pr, location: pr.url)
            await reviewModel(for: tab).load(force: true)
        }
    }

    func saveReviewDraft(_ draft: ReviewDraft, tabID: String) {
        if draft.hasContent { reviewDrafts[tabID] = draft }
        else { reviewDrafts.removeValue(forKey: tabID) }
        persistWorkspace()
    }

    /// Mirrors a confirmed action into the tab and Overview before the next refresh.
    func applyLocalChange(_ pr: PullRequest, tabID: String) {
        updateReviewTab(pr, tabID: tabID)
        guard var current = snapshot,
              let index = current.pullRequests.firstIndex(where: { $0.repository == pr.repository && $0.number == pr.number })
        else { return }
        var updated = pr
        updated.id = current.pullRequests[index].id
        current.pullRequests[index] = updated
        snapshot = current
    }

    func updateReviewTab(_ pr: PullRequest, tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var updated = pr
        updated.id = tabID
        tabs[index].pr = updated
        persistWorkspace()
    }

    func openExternal(_ url: URL) {
        guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            report(MergeportError.message("This link uses an unsupported URL scheme."))
            return
        }
        if !NSWorkspace.shared.open(url) { report(MergeportError.message("macOS could not open the link.")) }
    }

    func report(_ error: Error) {
        self.error = error.localizedDescription
        NSLog("Mergeport: %@", error.localizedDescription)
    }

    private func persistWorkspace() {
        guard !isDemo else { return }
        do {
            defaults.set(try JSONEncoder().encode(SavedWorkspace(snapshot: snapshot, tabs: tabs, selectedTab: selectedTab, drafts: reviewDrafts, changes: unseenChanges)),
                         forKey: "workspace")
        } catch { report(error) }
    }
}
