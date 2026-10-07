import AppKit
import MergeportCore
import SwiftUI

enum YardPalette {
    static let cyan = Color(red: 0.49, green: 1, blue: 0.94)
    static let blue = Color(red: 0.34, green: 0.72, blue: 1)
    static let purple = Color(red: 0.64, green: 0.36, blue: 1)
    /// GitHub's merged status, nudged toward pink so it reads apart from the purple accents.
    static let merged = Color(red: 0.76, green: 0.39, blue: 0.94)
    static let closed = Color(red: 0.9, green: 0.3, blue: 0.28)

    /// Icon and color for a PR: merged/closed first, otherwise its workflow stage.
    static func status(_ pr: PullRequest) -> (symbol: String, color: Color) {
        switch pr.state {
        case "MERGED": ("arrow.triangle.merge", merged)
        case "CLOSED": ("xmark.circle", closed)
        default: (pr.stage.symbol, color(pr.stage))
        }
    }
    static let gradient = LinearGradient(colors: [cyan, blue, purple], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(_ stage: WorkflowStage) -> Color {
        switch stage {
        case .draft: .secondary
        case .attention: .orange
        case .review: .purple
        case .waiting: .blue
        case .ready: .green
        }
    }

    /// A concrete color per stage for card backgrounds; `.secondary` is too faint to tint with.
    static func tint(_ stage: WorkflowStage) -> Color {
        stage == .draft ? .gray : color(stage)
    }
}

struct YardMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: "arrow.triangle.pull")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(YardPalette.gradient)
            .frame(width: size, height: size)
            .background(Color(red: 0.04, green: 0.06, blue: 0.13), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct StageBadge: View {
    let stage: WorkflowStage
    var body: some View {
        Label(stage.title, systemImage: stage.symbol)
            .font(.caption.weight(.medium)).foregroundStyle(YardPalette.color(stage))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(YardPalette.color(stage).opacity(0.12), in: Capsule())
    }
}

/// Latest-commit checks: a spinner while running, then the last verdict. Pass `summary`
/// when per-check results are loaded (review tabs) to show counts.
struct ChecksStatusBadge: View {
    let state: CheckState
    var summary: CheckSummary?

    private var effective: CheckState {
        guard let summary, summary.total > 0 else { return state }
        return summary.failed > 0 ? .failure : summary.pending > 0 ? .pending : .success
    }

    private var title: String {
        switch effective {
        case .pending:
            if let summary, summary.total > 0 {
                return "Checks running \(summary.total - summary.pending)/\(summary.total)"
            }
            return "Checks running"
        case .success: return "Checks passed"
        case .failure:
            if let summary, summary.failed > 0 { return "\(summary.failed) check\(summary.failed == 1 ? "" : "s") failed" }
            return "Checks failed"
        case .none: return "No checks"
        case .unknown: return "Checks unknown"
        }
    }

    private var color: Color {
        switch effective {
        case .success: .green
        case .failure: .red
        case .pending: .yellow
        case .none, .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if effective == .pending {
                RunningIndicator()
            } else {
                Image(systemName: effective == .success ? "checkmark.circle.fill"
                    : effective == .failure ? "xmark.circle.fill" : "minus.circle")
            }
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.4)))
        .fixedSize()
        .help(summary.map { "\($0.title)\n\($0.detail)" } ?? state.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// A turning arc that, unlike a mini ProgressView, takes the surrounding color. The angle is
/// derived from the clock rather than a repeating animation, which would also animate layout
/// changes (e.g. the header growing while a PR loads) and make the arc drift around.
private struct RunningIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.15, to: 1)
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 11, height: 11)
    }
}

struct CopilotStatusBadge: View {
    let state: CopilotState

    private var title: String {
        switch state {
        case .reviewed: "Copilot reviewed"
        case .requested: "Copilot pending"
        case .outdated: "Copilot outdated"
        case .notRequested: "No Copilot review"
        case .unknown: "Copilot unknown"
        }
    }

    private var color: Color {
        switch state {
        case .reviewed: .green
        case .requested: .blue
        case .outdated, .notRequested: .orange
        case .unknown: .secondary
        }
    }

    var body: some View {
        Label(title, systemImage: state == .reviewed ? "checkmark.seal.fill" : state == .requested ? "clock.fill" : "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.4)))
            .fixedSize()
            .help(state == .requested ? "Copilot was requested. GitHub does not expose whether it has started running." : state.title)
            .accessibilityLabel(title)
    }
}

/// Number, ticket, repo and target branch: the facts to spot at a glance.
struct PRKeyFacts: View {
    let pr: PullRequest
    let ticket: String?
    var issue: LinearIssue?
    var large = false
    var openIssue: ((URL) -> Void)?

    var body: some View {
        let owner = pr.repository.split(separator: "/").first.map { "\($0)/" } ?? ""
        let name = pr.repository.split(separator: "/").last.map(String.init) ?? pr.repository
        HStack(spacing: 8) {
            Text("#" + String(pr.number)).fontWeight(.semibold).monospaced().foregroundStyle(.tint)
            if let ticket {
                if let issue, let openIssue {
                    Button { openIssue(issue.url) } label: { ticketChip(ticket, linked: true) }
                        .buttonStyle(.plain)
                        .help("\(issue.identifier): \(issue.title)\n\(issue.state) · Open in Linear")
                } else {
                    ticketChip(ticket, linked: false)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                (Text(owner).foregroundStyle(.secondary) + Text(name).fontWeight(.bold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.system(size: large ? 10 : 9, weight: .bold))
                Text(pr.base).fontWeight(.bold).monospaced()
            }
            .foregroundStyle(Color.branchBlue)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.branchBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.branchBlue.opacity(0.4)))
            .help("Target branch")
            if let stack = pr.stack {
                let allReady = stack.readyCount == stack.openEntries.count
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(allReady ? Color.green : Color.orange)
                    Text(stack.positionLabel).fontWeight(.semibold).monospacedDigit()
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .help("Stack #\(stack.number): layer \(stack.position) of \(stack.size), into \(stack.base) · \(stack.readinessLabel)")
            }
        }
        .font(.system(size: large ? 13 : 12)).lineLimit(1).textSelection(.enabled)
    }

    private func ticketChip(_ ticket: String, linked: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: linked ? "arrow.up.forward.square" : "ticket")
            Text(ticket).fontWeight(.semibold).monospaced()
            if let issue { LinearStateDot(issue: issue) }
        }
        .foregroundStyle(Color.ticketInk)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(linked ? 0.16 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Linear's workflow state as a small colored ring, like Linear's own status icons.
struct LinearStateDot: View {
    let issue: LinearIssue
    var body: some View {
        let color = Color(hex: issue.stateColor) ?? .secondary
        ZStack {
            Circle().stroke(color, lineWidth: 1.5)
            if issue.stateType == "completed" { Circle().fill(color) }
            else if issue.stateType == "started" { Circle().trim(from: 0, to: 0.5).fill(color).rotationEffect(.degrees(-90)).padding(2.5) }
            else if issue.stateType == "canceled" { Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).foregroundStyle(color) }
        }
        .frame(width: 10, height: 10)
        .help(issue.state)
    }
}

/// The linked Linear issue under a PR title: what it is about and where it stands in Linear.
struct LinearIssueLine: View {
    let issue: LinearIssue
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Text("Linear").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                Text(issue.title).foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                let color = Color(hex: issue.stateColor) ?? .secondary
                HStack(spacing: 5) {
                    LinearStateDot(issue: issue)
                    Text(issue.state).font(.caption.weight(.medium))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())
                .fixedSize()
                Image(systemName: "arrow.up.forward").font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(issue.identifier) is “\(issue.state)” in Linear. Click to open the issue.")
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

private struct TabStripMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
}

private struct TabStripGeometry: ViewModifier {
    @Binding var geometry: TabStripMetrics

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: TabStripMetrics.self) {
                TabStripMetrics(offset: $0.contentOffset.x, content: $0.contentSize.width, visible: $0.containerSize.width)
            } action: { _, value in geometry = value }
        } else {
            content
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var tabStrip = TabStripMetrics()
    @State private var tabBarWidth: CGFloat = 0
    @State private var overviewTabWidth: CGFloat = 130
    @State private var hoveredTab: String?
    @State private var collapsedGroups: Set<String> = []
    @AppStorage("collapsedSidebarSections") private var collapsedSections = ""
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if model.tabLayout == .topBar {
                    tabBar
                    Divider()
                }
                if let tab = model.activeTab {
                    NativeReviewView(tab: tab, review: model.reviewModel(for: tab)).id(tab.id)
                } else if model.isConnected || model.isDemo {
                    Overview()
                } else {
                    WelcomeView()
                }
            }
        }
        .navigationTitle("Mergeport")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Back (Command-Left Arrow)")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help("Forward (Command-Right Arrow)")
            }
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                    .disabled(!model.isConnected || model.isRefreshing).help("Refresh overview (Shift-Command-R)")
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(.regularMaterial)
            }
        }
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { model.showPalette = false }
                    CommandPalette().environmentObject(model).padding(.top, 70)
                }
            }
        }
        .sheet(isPresented: $model.showConnection, onDismiss: { if model.isSigningIn { model.cancelSignIn() } }) {
            ConnectionView().environmentObject(model)
        }
        .sheet(isPresented: $model.showRepositories) {
            RepositorySettings().environmentObject(model).padding(24).frame(width: 560, height: 480)
        }
        .sheet(item: $model.branchGroupingTarget) { pr in BranchGroupEditor(pr: pr).environmentObject(model) }
        .sheet(isPresented: $model.showGroupingSettings) {
            VStack {
                GroupingSettingsView()
                HStack { Spacer(); Button("Done") { model.showGroupingSettings = false }.keyboardShortcut(.defaultAction) }.padding(16)
            }.environmentObject(model).frame(width: 620, height: 560)
        }
        .task {
            await model.start()
            if model.isDemo, ProcessInfo.processInfo.arguments.contains("--demo-review"),
               let pr = model.pullRequests.first(where: { $0.needsMyReview }) { model.open(pr) }
            await SmokeTest.runIfRequested(model: model)
        }
        .alert(item: $model.tabToClose) { tab in
            Alert(title: Text("Discard the draft for \(tab.pr.displayNumber)?"),
                message: Text("Closing this tab discards its unsent review, discussion comment and thread replies. Submitted GitHub comments are unchanged."),
                primaryButton: .destructive(Text("Discard and close")) { model.closeTab(tab.id, discardingDraft: true) },
                secondaryButton: .cancel())
        }
        .task(id: model.refreshInterval) {
            do {
                while !Task.isCancelled {
                    // Running checks resolve in minutes; poll faster so their outcome shows up promptly.
                    let running = model.pullRequests.contains { $0.state == "OPEN" && $0.checks == .pending }
                    try await Task.sleep(for: .seconds(running ? min(model.refreshInterval, 30) : model.refreshInterval))
                    if scenePhase == .active { await model.refresh() }
                }
            } catch is CancellationError {
                return
            } catch { model.report(error) }
        }
        .onChange(of: model.selectedTab) { _, newValue in
            if newValue == nil { Task { await model.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.tabLayout == .sidebar { openTabsSection }
                    sidebarSection("INBOX") {
                        ForEach(InboxScope.allCases, id: \.self) { scope in
                            sidebarRow(scope.title, symbol: scope == .all ? "tray.full" : scope == .mine ? "person" : "text.bubble",
                                       count: model.pullRequests.filter { scope.includes($0, login: model.login) }.count,
                                       selected: onOverview && model.scope == scope && model.repositoryFilter == nil && model.stageFilter == nil,
                                       shortcut: SidebarDestination.forScope(scope).keyLabel) {
                                model.showOverview(scope: scope)
                            }
                        }
                    }
                    sidebarSection("WORKFLOW") {
                        ForEach(WorkflowStage.allCases, id: \.self) { stage in
                            sidebarRow(stage.title, symbol: stage.symbol,
                                       count: model.pullRequests.filter { $0.stage == stage }.count,
                                       selected: onOverview && model.stageFilter == stage,
                                       color: YardPalette.color(stage),
                                       shortcut: SidebarDestination.forStage(stage).keyLabel) {
                                model.showOverview(scope: .all, stage: stage)
                            }
                        }
                    }
                    sidebarSection("REPOSITORIES") {
                        ForEach(model.knownRepositories, id: \.self) { repo in
                            sidebarRow(repo, symbol: "shippingbox", count: model.pullRequests.filter { $0.repository == repo }.count,
                                       selected: onOverview && model.repositoryFilter == repo) {
                                model.showOverview(scope: .all, repository: repo)
                            }
                        }
                        Button { model.showRepositories = true } label: {
                            Label("Manage repositories", systemImage: "plus").font(.callout)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 10)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 18)
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(model.isDemo ? Color.orange : model.isConnected ? .green : .secondary).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isDemo ? "Sample workspace" : model.login.isEmpty ? "Not connected" : "@\(model.login)")
                        .font(.caption.weight(.medium))
                    if model.isDemo {
                        Button("Connect GitHub") { model.showConnection = true }.font(.caption).buttonStyle(.link)
                    } else if model.isConnected {
                        if model.isRefreshing {
                            Text("Refreshing GitHub…").font(.caption2).foregroundStyle(.secondary)
                        } else if let fetched = model.snapshot?.fetchedAt {
                            Text("Last sync: \(fetched.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("When GitHub data last loaded successfully—not a countdown to the next refresh.")
                        }
                        Text(scenePhase == .active
                             ? "Auto-refresh: every \(String(model.refreshInterval / 60)) min"
                             : "Auto-refresh paused while inactive")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("Refresh resumes when Mergeport becomes active. You can also refresh manually.")
                    }
                }
                Spacer()
            }.padding(16)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: model.tabLayout == .sidebar ? 300 : 250, max: 440)
    }

    /// With tabs in the sidebar, the overview rows only highlight while the overview is showing.
    private var onOverview: Bool { model.tabLayout == .topBar || model.selectedTab == nil }

    private func isCollapsed(_ title: String) -> Bool {
        collapsedSections.split(separator: ",").contains(Substring(title))
    }

    private func toggleSection(_ title: String) {
        var sections = Set(collapsedSections.split(separator: ",").map(String.init))
        if !sections.insert(title).inserted { sections.remove(title) }
        collapsedSections = sections.sorted().joined(separator: ",")
    }

    private func sidebarSection<Content: View>(
        _ title: String, count: Int? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        let collapsed = isCollapsed(title)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { toggleSection(title) } } label: {
                    HStack(spacing: 4) {
                        Text(title)
                        if let count { Text(String(count)).monospacedDigit() }
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
                if let accessory { accessory }
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 10).padding(.trailing, 6).padding(.bottom, 3)
            if !collapsed { content() }
        }
    }

    // MARK: Tabs in the sidebar

    private var openTabsSection: some View {
        let tabs = model.tabs
        let runs = TabGroups.runs(tabs) { model.tabsRelated($0.pr, $1.pr) }
        let menu = Menu {
            tabListMenu
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Close tabs")
        return sidebarSection("OPEN", count: tabs.count, accessory: tabs.isEmpty ? nil : AnyView(menu)) {
            if tabs.isEmpty {
                Text("PRs you open show up here, grouped like the overview.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            ForEach(Array(runs.enumerated()), id: \.element) { _, run in
                if let label = model.tabGroupLabel(run.map { tabs[$0].pr }) {
                    let collapsed = collapsedGroups.contains(label)
                    VStack(alignment: .leading, spacing: 1) {
                        sidebarGroupHeader(label, tabs: run.map { tabs[$0] }, collapsed: collapsed)
                        if !collapsed {
                            ForEach(run, id: \.self) { sidebarTab(tabs[$0], index: $0, groupLabel: label) }
                        }
                    }
                    .padding(3)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
                } else {
                    ForEach(run, id: \.self) { sidebarTab(tabs[$0], index: $0, groupLabel: nil) }
                }
            }
        }
    }

    @ViewBuilder private var tabListMenu: some View {
        let finished = model.finishedTabs.count
        Button("Close Merged and Closed Tabs (\(finished))") { model.closeFinishedTabs(all: true) }
            .disabled(finished == 0)
        Button("Close All Tabs") { model.closeTabs(model.tabs.map(\.id)) }
        Divider()
        Picker("Show Tabs In", selection: $model.tabLayout) {
            ForEach(TabLayout.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    private func sidebarGroupHeader(_ label: String, tabs: [ReviewTab], collapsed: Bool) -> some View {
        let selectedInside = tabs.contains { $0.id == model.selectedTab }
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed { collapsedGroups.remove(label) } else { collapsedGroups.insert(label) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold)).frame(width: 18)
                Text(label).font(Self.groupLabelFont).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if collapsed {
                    HStack(spacing: 2) {
                        ForEach(tabs) { tab in
                            let status = YardPalette.status(tab.pr)
                            Image(systemName: status.symbol).font(.system(size: 9)).foregroundStyle(status.color)
                        }
                    }
                }
                Text(String(tabs.count)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(collapsed && selectedInside ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Grouped by \(model.tabGrouping.title.lowercased()): \(label)")
        .contextMenu {
            Button(collapsed ? "Expand Group" : "Collapse Group") {
                if collapsed { collapsedGroups.remove(label) } else { collapsedGroups.insert(label) }
            }
            Button("Close Group") { model.closeTabs(tabs.map(\.id)) }
        }
    }

    private func sidebarTab(_ tab: ReviewTab, index: Int, groupLabel: String?) -> some View {
        let pr = tab.pr
        let ticket = model.ticket(for: pr)
        let selected = model.selectedTab == tab.id
        let status = YardPalette.status(pr)
        let detail = pr.state != "OPEN" ? pr.state.capitalized : pr.stage == .ready ? "Ready to merge" : pr.waitingReason
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol).foregroundStyle(status.color).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(TabGroups.title(pr.title, without: ticket)).lineLimit(1).truncationMode(.tail)
                    .fontWeight(selected ? .semibold : .regular)
                HStack(spacing: 5) {
                    Text("#" + String(pr.number)).monospacedDigit()
                    if let ticket, ticket != groupLabel { Text(ticket).monospaced() }
                    Text("→ " + pr.base).monospaced().foregroundStyle(Color.branchBlue).lineLimit(1).layoutPriority(-1)
                    Text("·")
                    Text(detail).lineLimit(1).truncationMode(.tail).layoutPriority(-2)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Group {
                if hoveredTab == tab.id || selected {
                    Button { model.closeTab(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab")
                } else if model.showShortcutHints, let hint = AppModel.tabShortcut(index: index, count: model.tabs.count) {
                    ShortcutHint(label: hint)
                }
            }.padding(.top, 1)
        }
        .font(.callout)
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(tabBackground(tab), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { inside in
            if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
        }
        .contextMenu { tabMenu(tab) }
        .help(pr.displayTitle)
    }

    @ViewBuilder private func tabMenu(_ tab: ReviewTab) -> some View {
        Button("Close Tab") { model.closeTab(tab.id) }
        Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }.disabled(model.tabs.count < 2)
        let group = model.tabGroup(of: tab.id)
        if group.count > 1 {
            Button("Close Group (\(group.count))") { model.closeGroup(of: tab.id) }
        }
        let finished = model.finishedTabs.count
        Button("Close Merged and Closed Tabs (\(finished))") { model.closeFinishedTabs(all: true) }
            .disabled(finished == 0)
        Divider()
        Button("Open on GitHub") { NSWorkspace.shared.open(tab.pr.url) }
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int, selected: Bool,
                            color: Color = .secondary, shortcut: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.accentColor : color).frame(width: 18)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if model.showShortcutHints, let shortcut {
                    ShortcutHint(label: shortcut)
                } else {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(shortcut.map { "\(title) (\($0))" } ?? title)
    }

    @ViewBuilder private func tabHint(_ label: String) -> some View {
        if model.showShortcutHints {
            ShortcutHint(label: label)
        }
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button { model.selectTab(nil) } label: {
                    HStack(spacing: 6) {
                        Label("Overview", systemImage: "square.grid.2x2")
                        tabHint("⌘1")
                    }
                        .font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 11)
                        .background(model.selectedTab == nil ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { overviewTabWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in overviewTabWidth = width }
                })
                let tabs = model.tabs
                let runs = TabGroups.runs(tabs) { model.tabsRelated($0.pr, $1.pr) }
                let labels = runs.map { model.tabGroupLabel($0.map { tabs[$0].pr }) }
                let width = tabWidth(runs: runs, labels: labels)
                ForEach(Array(runs.enumerated()), id: \.element) { position, run in
                    if let label = labels[position] {
                        HStack(spacing: 2) {
                            Text(label)
                                .font(Self.groupLabelFont)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: Self.groupLabelMaxWidth)
                                .padding(.horizontal, 8)
                                .help("Grouped by \(model.tabGrouping.title.lowercased()): \(label)")
                                .contextMenu {
                                    Button("Close Group (\(run.count))") { model.closeTabs(run.map { tabs[$0].id }) }
                                }
                            ForEach(run, id: \.self) { index in
                                tabItem(tabs[index], index: index, width: width, groupLabel: label)
                            }
                        }
                        .padding(.horizontal, 2)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
                    } else {
                        ForEach(run, id: \.self) { index in
                            tabItem(tabs[index], index: index, width: width, groupLabel: nil)
                        }
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        .modifier(TabStripGeometry(geometry: $tabStrip))
        .background(GeometryReader { proxy in
            Color.clear.onAppear { tabBarWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in tabBarWidth = width }
        })
        .overlay(alignment: .bottom) { thinScroller }
        .background(.bar)
        .onChange(of: model.selectedTab) { _, id in
            guard let id else { return }
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
        }
        }
    }

    private static let groupLabelFont = Font.system(size: 12, weight: .semibold, design: .monospaced)
    private static let groupLabelMaxWidth: CGFloat = 150

    /// Width left for tabs after Overview, spacing and group labels, shared Chrome-style.
    private func tabWidth(runs: [Range<Int>], labels: [String?]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let chrome = labels.reduce(CGFloat(0)) { total, label in
            guard let label else { return total }
            let text = (label as NSString).size(withAttributes: [.font: font]).width
            return total + min(Self.groupLabelMaxWidth, ceil(text)) + 16 + 4 + 2
        }
        let gaps = CGFloat(runs.reduce(0) { $0 + $1.count }) * 4
        let available = tabBarWidth - 20 - overviewTabWidth - gaps - chrome
        return CGFloat(TabSizing.width(tabs: model.tabs.count, available: Double(available)))
    }

    private func tabItem(_ tab: ReviewTab, index: Int, width: CGFloat, groupLabel: String?) -> some View {
        let ticket = model.ticket(for: tab.pr)
        let selected = model.selectedTab == tab.id
        let compact = width < 190
        return HStack(spacing: 7) {
            if let hint = AppModel.tabShortcut(index: index, count: model.tabs.count) { tabHint(hint) }
            let status = YardPalette.status(tab.pr)
            Image(systemName: status.symbol).foregroundStyle(status.color)
            Text("#\(String(tab.pr.number))").monospacedDigit().foregroundStyle(.secondary)
                .fixedSize().layoutPriority(2)
            if let ticket, ticket != groupLabel, width >= 240 {
                Text(ticket).font(.callout.monospaced().weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            if !compact {
                Text(TabGroups.title(tab.pr.title, without: ticket))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if width >= 135 {
                Text(tab.pr.base).font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(Color.branchBlue)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.branchBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            }
            if selected || width >= 120 {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab")
            }
        }
        .font(.callout)
        .padding(.horizontal, width < 150 ? 9 : 12).padding(.vertical, 12)
        .frame(width: width)
        .background(tabBackground(tab), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.selectTab(tab.id) }
        .contextMenu { tabMenu(tab) }
        .help(tab.pr.displayTitle)
        .id(tab.id)
    }

    /// Merged and closed tabs keep a status tint so they stand out; the selected tab is stronger.
    private func tabBackground(_ tab: ReviewTab) -> Color {
        let selected = model.selectedTab == tab.id
        guard tab.pr.state != "OPEN" else { return selected ? Color.accentColor.opacity(0.12) : .clear }
        return YardPalette.status(tab.pr).color.opacity(selected ? 0.22 : 0.12)
    }

    /// A 3pt indicator instead of the system scroller, shown only when tabs overflow.
    @ViewBuilder private var thinScroller: some View {
        let width = tabStrip.visible
        let content = tabStrip.content
        if content > width + 1, width > 0 {
            let thumb = max(40, width * width / content)
            let progress = min(1, max(0, tabStrip.offset / (content - width)))
            Capsule().fill(Color.primary.opacity(0.28))
                .frame(width: thumb, height: 3)
                .offset(x: (width - thumb) * progress)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Overview: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var pendingOpenAll: [PullRequest] = []

    /// Opens right away for a handful; asks first when it would open many tabs.
    private func openAll(_ prs: [PullRequest]) {
        let fresh = model.unopened(prs)
        if fresh.count > 10 { pendingOpenAll = fresh } else { model.openAll(fresh) }
    }

    private func openAllButton(_ prs: [PullRequest], compact: Bool) -> some View {
        let fresh = model.unopened(prs).count
        return Button { openAll(prs) } label: {
            Label(compact ? "Open all" : "Open all (\(fresh))", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(fresh == 0)
        .help(fresh == 0 ? "All of these are already open" : "Open \(fresh) PR\(fresh == 1 ? "" : "s") in tabs")
    }

    private var title: String { model.repositoryFilter ?? model.scope.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 28, weight: .bold))
                        Text("Your branches, reviews and next steps. One place.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isDemo {
                        Button("Connect GitHub") { model.showConnection = true }.buttonStyle(.borderedProminent)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(WorkflowStage.allCases, id: \.self) { stage in
                        let count = model.pullRequests.filter {
                            model.scope.includes($0, login: model.login)
                                && (model.repositoryFilter == nil || $0.repository == model.repositoryFilter) && $0.stage == stage
                        }.count
                        Button { model.stageFilter = model.stageFilter == stage ? nil : stage } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Image(systemName: stage.symbol).foregroundStyle(YardPalette.color(stage))
                                    Spacer()
                                    Text("\(count)").font(.system(size: 24, weight: .semibold, design: .rounded))
                                }
                                Text(stage.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.stageFilter == stage ? YardPalette.color(stage).opacity(0.1) : Color.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(model.stageFilter == stage ? YardPalette.color(stage).opacity(0.5) : Color.primary.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search PRs, repositories or branches", text: $model.search)
                            .textFieldStyle(.plain).focused($searchFocused)
                        if !model.search.isEmpty {
                            Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Picker("Group by", selection: Binding(get: { model.groupingPreferences.mode }, set: { model.setGroupingMode($0) })) {
                        ForEach(PRGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 220)
                    Button { model.showGroupingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("Configure ticket prefixes and branch aliases")
                    openAllButton(model.filteredPRs, compact: false)
                    if let stage = model.stageFilter {
                        Button {
                            model.stageFilter = nil
                        } label: { Label(stage.title, systemImage: "xmark.circle") }.font(.caption)
                    }
                }
            }.padding(24)
            Divider()
            if model.filteredPRs.isEmpty {
                ContentUnavailableView {
                    Label(model.isRefreshing ? "Loading pull requests" : "Nothing in this queue", systemImage: "tray")
                } description: {
                    Text(model.search.isEmpty ? "Your own open PRs and review requests appear automatically. Add repositories to follow everyone else's PRs."
                         : "Try another title, branch, PR number or repository.")
                } actions: {
                    if model.stageFilter != nil || !model.search.isEmpty {
                        Button("Clear filters") { model.stageFilter = nil; model.search = "" }
                    } else {
                        Button("Add repositories") { model.showRepositories = true }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        switch model.groupingResult {
                        case .success(let groups):
                            ForEach(groups) { group in
                                if model.groupingPreferences.mode != .none {
                                HStack(spacing: 8) {
                                    Image(systemName: group.symbol).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 8) {
                                            Text(group.title).font(.headline).textSelection(.enabled)
                                            if let issue = groupIssue(group) {
                                                LinearStateDot(issue: issue)
                                                Text(issue.title).font(.headline.weight(.regular)).lineLimit(1)
                                                Text(issue.state).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        if let subtitle = group.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Text("\(group.pullRequests.count)")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Spacer()
                                    if group.pullRequests.count > 1 {
                                        openAllButton(group.pullRequests, compact: true)
                                            .buttonStyle(.borderless).font(.caption)
                                    }
                                    if let issue = groupIssue(group) {
                                        Button { model.openExternal(issue.url) } label: {
                                            Label("Open in Linear", systemImage: "arrow.up.forward.square")
                                        }.buttonStyle(.borderless).font(.caption).disabled(model.isDemo)
                                    }
                                }.padding(.top, 8).padding(.bottom, 2)
                                }
                                ForEach(group.pullRequests) { PRRow(pr: $0) }
                            }
                        case .failure(let error):
                            Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            ForEach(model.filteredPRs) { PRRow(pr: $0) }
                        }
                    }.padding(24)
                }
            }
            Divider()
            HStack {
                Text("\(model.filteredPRs.count) open pull requests")
                Spacer()
                Text(model.isDemo ? "Sample data • no GitHub connection" : "Personal queues + followed repositories • GitHub enforces merge rules")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Open \(pendingOpenAll.count) tabs?",
            isPresented: Binding(get: { !pendingOpenAll.isEmpty }, set: { if !$0 { pendingOpenAll = [] } })
        ) {
            Button("Open \(pendingOpenAll.count) Tabs") { model.openAll(pendingOpenAll); pendingOpenAll = [] }
            Button("Cancel", role: .cancel) { pendingOpenAll = [] }
        } message: {
            Text("Every PR in this view opens in a tab and its review loads in the background.")
        }
        .onAppear { focusSearchIfRequested() }
        .onChange(of: model.searchFocusRequested) { focusSearchIfRequested() }
    }

    private func groupIssue(_ group: PullRequestGroup) -> LinearIssue? {
        guard model.groupingPreferences.mode == .ticket, !group.isUnmatched else { return nil }
        return model.linearIssues[group.title]
    }

    private func focusSearchIfRequested() {
        if model.searchFocusRequested {
            searchFocused = true
            model.searchFocusRequested = false
        }
    }
}

private struct PRRow: View {
    @EnvironmentObject var model: AppModel
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: pr.stage.symbol)
                        .font(.system(size: 20)).foregroundStyle(YardPalette.color(pr.stage)).frame(width: 26).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .center, spacing: 8) {
                            PRKeyFacts(pr: pr, ticket: model.ticket(for: pr), issue: model.linearIssue(for: pr),
                                       openIssue: { model.openExternal($0) })
                            Spacer(minLength: 10)
                            StageBadge(stage: pr.stage)
                        }
                        Text(pr.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 7) {
                            if let url = pr.authorAvatarURL {
                                CachedImage(url: ImageCache.sized(url, points: 16)) {
                                    Color.primary.opacity(0.08)
                                }.frame(width: 16, height: 16).clipShape(Circle())
                            }
                            Text("by \(pr.isMine(model.login) ? "you" : "@\(pr.author)")").font(.caption)
                            Text("·")
                            Text("from").font(.caption)
                            Text(pr.head).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(pr.updatedAt, style: .relative).font(.caption)
                        }.foregroundStyle(.secondary)
                    }
                }
            HStack(spacing: 14) {
                ChecksStatusBadge(state: pr.checks)
                CopilotStatusBadge(state: pr.copilot)
                if pr.blockingUnresolved > 0 {
                    Label("\(pr.blockingUnresolved) unresolved", systemImage: "text.bubble").foregroundStyle(.orange)
                }
                if pr.copilotUnresolved > 0 {
                    Label("\(pr.copilotUnresolved) Copilot finding\(pr.copilotUnresolved == 1 ? "" : "s")", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .help("Unresolved Copilot threads don't block merging")
                }
                Spacer(minLength: 4)
                Text(pr.waitingReason).foregroundStyle(.secondary).lineLimit(1)
            }.font(.caption).padding(.leading, 38)
            let siblings = model.siblings(pr)
            if !siblings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(siblings.contains(where: { $0.head != pr.head }) ? "Branch group" : "Same branch").foregroundStyle(.secondary)
                    ForEach(siblings) { sibling in
                        Button { model.open(sibling) } label: {
                            HStack(spacing: 4) {
                                Circle().fill(YardPalette.color(sibling.stage)).frame(width: 5, height: 5)
                                Text("\(sibling.base) \(sibling.displayNumber)")
                            }
                        }.buttonStyle(.borderless).help("\(sibling.stage.title): \(sibling.title)")
                    }
                    Spacer()
                }.font(.caption).padding(.leading, 38)
            }
        }
        .padding(16).padding(.leading, 4)
        .background(tint.opacity(hovering ? 0.13 : 0.07))
        .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(isDraft ? 0.55 : 0.85)).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(tint.opacity(hovering ? 0.6 : 0.3)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.open(pr) }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .onDisappear { if hovering { NSCursor.pop() } }
        .accessibilityAction { model.open(pr) }
        .contextMenu {
            Button("Open review tab") { model.open(pr) }
            Button("Open files changed") {
                model.open(pr, location: URL(string: pr.url.absoluteString + "/files"))
            }
            Button("Open in browser") { model.openExternal(pr.url) }.disabled(model.isDemo)
            if let issue = model.linearIssue(for: pr) {
                Button("Open \(issue.identifier) in Linear") { model.openExternal(issue.url) }.disabled(model.isDemo)
            }
            Divider()
            Button("Add source branch to group…") { model.branchGroupingTarget = pr }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            }
        }
    }

    private var isDraft: Bool { pr.stage == .draft }
    private var tint: Color { YardPalette.tint(pr.stage) }
}
