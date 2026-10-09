import Combine
import Foundation
import MergeportCore

enum ReviewSection: String, CaseIterable {
    case conversation, files, checks, commits
    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .files: "Files changed"
        case .checks: "Checks"
        case .commits: "Commits"
        }
    }

    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .files: "plus.forwardslash.minus"
        case .checks: "checklist"
        case .commits: "smallcircle.filled.circle"
        }
    }
}

enum FileDiff {
    case available(UnifiedDiff, complete: Bool)
    case unavailable(String)
}

@MainActor
final class ReviewModel: ObservableObject {
    let reference: PullRequest
    private weak var app: AppModel?
    @Published var details: ReviewDetails?
    @Published var isComposingReview = false
    @Published var section: ReviewSection
    @Published var selectedFile: String? {
        didSet {
            // Jumping to a file (e.g. from a thread) reveals it in the tree.
            if let selectedFile { collapsedFolders.subtract(FileTree.ancestors(of: selectedFile)) }
        }
    }
    @Published var collapsedFolders: Set<String> = []
    @Published var isLoading = false
    @Published var isPerforming = false { didSet { app?.objectWillChange.send() } }
    @Published var error: String?
    @Published var notice: String?
    @Published var draft: ReviewDraft { didSet { app?.saveReviewDraft(draft, tabID: reference.id) } }
    @Published var mergeMethod: MergeMethod = .squash {
        didSet { UserDefaults.standard.set(mergeMethod.rawValue, forKey: Self.mergeMethodKey(reference.repository)) }
    }
    @Published private(set) var isMerging = false
    private(set) var diffs: [String: FileDiff] = [:]
    @Published private(set) var diffContexts: [String: DiffContext] = [:]
    @Published private(set) var contextErrors: [String: String] = [:]
    @Published private(set) var loadingContext: Set<String> = []
    @Published private(set) var conflictingFiles: [String]?
    @Published private(set) var conflictError: String?
    @Published private(set) var isLoadingConflicts = false
    private var conflictRevision: String?
    private var conflictTask: Task<Void, Never>?
    private var conflictTaskID: UUID?
    private(set) var diffRevision = UUID()
    private var lastLoaded: Date?
    private var lastPreloadAttempt: Date?
    private var loadedUpdatedAt: Date?
    private var loadTask: Task<Void, Never>?
    var diffLayoutMeasurements: [String: CGFloat] = [:]

    init(tab: ReviewTab, app: AppModel, draft: ReviewDraft) {
        reference = tab.pr
        self.app = app
        self.draft = draft
        section = ReviewSection(rawValue: tab.location.lastPathComponent) ?? .conversation
        if let saved = UserDefaults.standard.string(forKey: Self.mergeMethodKey(tab.pr.repository)),
           let method = MergeMethod(rawValue: saved) { mergeMethod = method }
    }

    private static func mergeMethodKey(_ repository: String) -> String { "mergeMethod.\(repository.lowercased())" }

    func preload(_ pr: PullRequest) async {
        guard details == nil || loadedUpdatedAt != pr.updatedAt else { return }
        if let lastPreloadAttempt, Date.now.timeIntervalSince(lastPreloadAttempt) < 120 { return }
        lastPreloadAttempt = .now
        await load(force: true)
    }

    var pr: PullRequest { details?.pr ?? reference }
    var isDemo: Bool { app?.isDemo == true }
    var draftIsStale: Bool { draft.headSHA != nil && draft.headSHA != details?.headSHA }
    var file: PullRequestFile? { details?.files.first { $0.filename == selectedFile } }

    func load(force: Bool = false) async {
        if let loadTask {
            await loadTask.value
            return
        }
        if !force, details != nil, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 60 { return }
        isLoading = true
        let task = Task { await fetch() }
        loadTask = task
        await task.value
        loadTask = nil
        isLoading = false
    }

    private func fetch() async {
        guard let app else { return }
        let generation = app.accountSessionID
        do {
            var fresh: ReviewDetails
            if app.isDemo { fresh = DemoReview.details(for: reference) }
            else { fresh = try await app.githubClient().reviewDetails(repository: reference.repository, number: reference.number) }
            try Task.checkCancellation()
            guard app.accountSessionID == generation else { return }
            if let queued = app.pullRequests.first(where: { $0.repository == fresh.pr.repository && $0.number == fresh.pr.number }) {
                fresh.pr.reviewRequested = fresh.pr.reviewRequested || queued.reviewRequested
            }
            var parsed: [String: FileDiff] = [:]
            var contexts: [String: DiffContext] = [:]
            var contextErrors: [String: String] = [:]
            for file in fresh.files {
                guard let patch = file.patch, !patch.isEmpty else {
                    parsed[file.filename] = .unavailable("GitHub provided no text patch for this file (binary, unchanged content, or a diff-size limit). Open GitHub for the full file.")
                    continue
                }
                do {
                    let diff = try UnifiedDiff.parse(patch)
                    let complete = diff.additions == file.additions && diff.deletions == file.deletions
                    parsed[file.filename] = .available(diff, complete: complete)
                    if complete, file.status != "removed", file.status != "added" {
                        do {
                            if details?.headSHA == fresh.headSHA,
                               let previous = details?.files.first(where: { $0.filename == file.filename }),
                               previous == file, let existing = diffContexts[file.filename] {
                                contexts[file.filename] = existing
                            } else {
                                contexts[file.filename] = try DiffContext(diff: diff)
                            }
                        } catch {
                            contextErrors[file.filename] = error.localizedDescription
                        }
                    }
                } catch { parsed[file.filename] = .unavailable(error.localizedDescription) }
            }
            diffs = parsed
            diffRevision = UUID()
            diffContexts = contexts
            self.contextErrors = contextErrors
            loadingContext = []
            if details?.headSHA != fresh.headSHA || details?.baseSHA != fresh.baseSHA
                || fresh.pr.mergeable != "CONFLICTING" && fresh.pr.mergeState != "DIRTY" {
                conflictingFiles = nil
                conflictError = nil
                conflictRevision = nil
            }
            details = fresh
            lastLoaded = .now
            loadedUpdatedAt = fresh.pr.updatedAt
            if !fresh.files.contains(where: { $0.filename == selectedFile }) { selectedFile = FileTree.orderedFilenames(fresh.files).first }
            if !fresh.mergeMethods.contains(mergeMethod), let method = fresh.mergeMethods.first { mergeMethod = method }
            app.updateReviewTab(fresh.pr, tabID: reference.id)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard app.accountSessionID == generation else { return }
            report(error)
        }
    }

    var hasRunningChecks: Bool {
        guard let details else { return false }
        return details.checkSummary.pending > 0
    }

    var conflictKey: String? {
        guard let details, pr.mergeable == "CONFLICTING" || pr.mergeState == "DIRTY" else { return nil }
        return "\(app?.accountSessionID.uuidString ?? ""):\(details.baseSHA ?? ""):\(details.headSHA)"
    }

    func loadConflictingFiles(retry: Bool = false) async {
        if let conflictTask { await conflictTask.value }
        guard retry || conflictRevision != conflictKey else { return }
        let id = UUID()
        conflictTaskID = id
        conflictRevision = conflictKey
        let task = Task { await fetchConflictingFiles() }
        conflictTask = task
        await task.value
        if conflictTaskID == id {
            conflictTask = nil
            conflictTaskID = nil
        }
    }

    private func fetchConflictingFiles() async {
        guard let app, let details, let key = conflictKey else {
            conflictingFiles = nil
            conflictError = nil
            conflictRevision = nil
            return
        }
        conflictRevision = key
        conflictingFiles = nil
        conflictError = nil
        isLoadingConflicts = true
        let generation = app.accountSessionID
        defer { isLoadingConflicts = false }
        do {
            let files: [String]
            if isDemo { files = ["app/services/notification-rs/project.json"] }
            else {
                guard let base = details.baseSHA else {
                    throw MergeportError.message("The base commit is unavailable. Refresh the PR before inspecting conflicts.")
                }
                files = try await app.githubClient().conflictingFiles(
                    repository: reference.repository, base: base, head: details.headSHA)
            }
            guard app.accountSessionID == generation, conflictKey == key else { return }
            conflictingFiles = files
            if files.isEmpty {
                conflictError = "Git found no conflicting files for these commits. GitHub's status may have changed; refresh the PR."
            }
        } catch {
            guard app.accountSessionID == generation, conflictKey == key else { return }
            conflictError = error.localizedDescription
        }
    }

    func expandContext(path: String, gap: Int, direction: ContextDirection) async {
        guard let app, let details, var context = diffContexts[path],
              !loadingContext.contains(path) else { return }
        let revision = diffRevision
        let generation = app.accountSessionID
        loadingContext.insert(path)
        defer { if revision == diffRevision { loadingContext.remove(path) } }
        do {
            if !context.hasSource {
                let text: String
                if isDemo { text = try DemoReview.fileText(path: path) }
                else {
                    text = try await app.githubClient().fileText(
                        repository: reference.repository, path: path, commit: details.headSHA)
                }
                try Task.checkCancellation()
                try context.loadSource(text)
            }
            guard revision == diffRevision, generation == app.accountSessionID else { return }
            try context.expand(gap: gap, direction: direction)
            diffContexts[path] = context
        } catch is CancellationError {
            return
        } catch {
            guard revision == diffRevision, generation == app.accountSessionID else { return }
            report(error)
        }
    }

    /// Re-reads the head commit's checks so running tests update without reloading the whole PR.
    func refreshChecks() async {
        guard let app, !app.isDemo, let details, loadTask == nil else { return }
        let generation = app.accountSessionID
        do {
            let checks = try await app.githubClient().checks(
                repository: reference.repository, sha: details.headSHA, number: reference.number)
            guard app.accountSessionID == generation, self.details?.headSHA == details.headSHA else { return }
            self.details?.checks = checks
            if let index = self.details?.commits.firstIndex(where: { $0.id == details.headSHA }) {
                self.details?.commits[index].checks = checks
            }
            if CheckSummary(checks).pending == 0 { await load(force: true) }
        } catch is CancellationError {
            return
        } catch {
            guard app.accountSessionID == generation, self.details?.headSHA == details.headSHA else { return }
            report(error)
        }
    }

    func selectSection(_ section: ReviewSection) {
        self.section = section
        let suffix = section == .conversation ? "" : "/\(section.rawValue)"
        if let url = URL(string: reference.url.absoluteString + suffix) { app?.recordLocation(url, tabID: reference.id) }
    }

    func prepareReview() {
        if draft.headSHA == nil { draft.headSHA = details?.headSHA }
    }

    func addComment(anchor: DiffAnchor, body: String) throws {
        guard let details else { throw MergeportError.message("Load the diff before commenting.") }
        guard !draftIsStale else { throw MergeportError.message("Clear the old review draft and review the updated diff before adding comments.") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MergeportError.message("Write an inline comment first.") }
        draft.headSHA = details.headSHA
        draft.comments.append(DraftComment(anchor: anchor, body: body))
    }

    func clearReviewDraft() {
        draft.body = ""; draft.comments = []; draft.headSHA = nil; draft.event = .comment
    }

    func submitReview() async -> Bool {
        guard let details else { report(MergeportError.message("Load the PR first.")); return false }
        if draft.event != .comment && (pr.isMine(details.viewer.login) || pr.isDraft) {
            report(MergeportError.message("You cannot approve/request changes on your own PR or a draft PR. Submit a comment instead."))
            return false
        }
        do { try draft.validate(currentHead: details.headSHA) } catch { report(error); return false }
        let submitted = draft
        let success = await perform("Review submitted", local: { $0.pr.reviewRequested = false }) { client in
            try await client.submitReview(repository: self.reference.repository, number: self.reference.number, draft: submitted)
        }
        if success { clearReviewDraft() }
        return success
    }

    func postDiscussion() async {
        let body = draft.discussion
        if await perform("Comment posted", operation: { client in
            try await client.postComment(repository: self.reference.repository, number: self.reference.number, body: body)
        }) { draft.discussion = "" }
    }

    func reply(to thread: ReviewThread) async -> Bool {
        guard let id = thread.comments.first?.databaseID else {
            report(MergeportError.message("GitHub did not provide an ID for replying to this thread.")); return false
        }
        let body = draft.replies[thread.id] ?? ""
        let success = await perform("Reply posted") { client in
            try await client.postComment(repository: self.reference.repository, number: self.reference.number, body: body, replyTo: id)
        }
        if success { draft.replies.removeValue(forKey: thread.id) }
        return success
    }

    func resolve(_ thread: ReviewThread) async {
        _ = await perform(thread.isResolved ? "Thread reopened" : "Thread resolved") { client in
            try await client.setThreadResolved(thread.id, resolved: !thread.isResolved)
        }
    }

    func setDraft() async {
        guard let details else { return }
        let draft = !details.pr.isDraft
        _ = await perform(pr.isDraft ? "PR marked ready for review" : "PR converted to draft", local: { $0.pr.isDraft = draft }) { client in
            try await client.setDraft(details.pr.id, draft: !details.pr.isDraft)
        }
    }

    func requestReview(from logins: [String]) async {
        guard let details, !logins.isEmpty else { return }
        let names = logins.map(ReviewDetails.displayName).joined(separator: ", ")
        _ = await perform("Review requested from \(names)", local: { details in
            for login in logins where !details.sidebar.requestedReviewers.contains(where: {
                $0.caseInsensitiveCompare(login) == .orderedSame
            }) { details.sidebar.requestedReviewers.append(login) }
            if logins.contains(where: CopilotState.isCopilot) { details.pr.copilot = .requested }
            // A fresh request means the PR is waiting on someone else again.
            if !details.pr.isDraft, details.pr.reviewDecision != "CHANGES_REQUESTED" {
                details.pr.reviewDecision = "REVIEW_REQUIRED"
            }
        }) { client in
            try await client.requestReviews(details.pr.id, logins: logins)
        }
    }

    /// People on this PR whose review counts toward the trunk's required approvals.
    var stackReviewers: [String] {
        (details?.sidebarReviewers ?? []).filter {
            !$0.isTeam && !ReviewDetails.isBot($0.login) && !CopilotState.isCopilot($0.login)
        }.map(\.login)
    }

    /// Teams requested on this PR, as `org/team-slug`.
    var stackReviewerTeams: [String] { details?.sidebar.requestedTeamSlugs ?? [] }

    /// "alice, @acme/platform-team" for the reviewers copied to other layers.
    var stackReviewerNames: String {
        (stackReviewers.map(ReviewDetails.displayName) + stackReviewerTeams.map { "@" + $0 })
            .joined(separator: ", ")
    }

    /// Asks this PR's reviewers to review every layer that nobody has been asked to review.
    func requestStackReviewers() async {
        guard let layers = pr.stack?.needingReviewer, !layers.isEmpty else { return }
        let logins = stackReviewers
        let teams = stackReviewerTeams
        guard !logins.isEmpty || !teams.isEmpty else { return }
        _ = await perform("Review requested on \(PRStack.list(layers.map(\.number)))") { client in
            for layer in layers {
                let reviewers = logins.filter { $0.caseInsensitiveCompare(layer.author) != .orderedSame }
                guard !reviewers.isEmpty || !teams.isEmpty else { continue }
                try await client.requestReviews(layer.id, logins: reviewers, teams: teams)
            }
        }
    }

    func reviewerCandidates() async throws -> [SidebarOption] {
        guard let app else { return [] }
        let logins = app.isDemo ? ["octocat", "hubot", "monalisa"] : try await app.githubClient().reviewerCandidates(
            repository: reference.repository, number: reference.number)
        return logins.map { SidebarOption(id: $0, title: $0) }
    }

    func sidebarOptions(_ kind: GitHubClient.SidebarOptionKind) async throws -> [SidebarOption] {
        guard let app else { return [] }
        guard !app.isDemo else {
            switch kind {
            case .assignees: return ["you", "octocat", "monalisa"].map { SidebarOption(id: $0, title: $0) }
            case .labels: return [
                SidebarOption(id: "bug", title: "bug", detail: "Something isn't working", color: "d73a4a"),
                SidebarOption(id: "email", title: "email", color: "1d76db"),
                SidebarOption(id: "rust", title: "rust", color: "dea584"),
            ]
            case .milestones: return [SidebarOption(id: "1", title: "Q4 migration", number: 1)]
            }
        }
        return try await app.githubClient().sidebarOptions(repository: reference.repository, kind: kind)
    }

    func setAssignees(_ logins: [String]) async {
        _ = await perform("Assignees updated") { client in
            try await client.updateIssue(repository: self.reference.repository, number: self.reference.number, assignees: logins)
        }
    }

    func setLabels(_ names: [String]) async {
        _ = await perform("Labels updated") { client in
            try await client.updateIssue(repository: self.reference.repository, number: self.reference.number, labels: names)
        }
    }

    func setMilestone(_ number: Int?) async {
        _ = await perform(number == nil ? "Milestone cleared" : "Milestone updated") { client in
            try await client.updateIssue(repository: self.reference.repository, number: self.reference.number, milestone: .some(number))
        }
    }

    func setSubscribed(_ subscribed: Bool) async {
        guard let details else { return }
        _ = await perform(subscribed ? "Subscribed to notifications" : "Unsubscribed from notifications") { client in
            try await client.setSubscribed(details.pr.id, subscribed: subscribed)
        }
    }

    func setLocked(_ locked: Bool) async {
        guard let details else { return }
        _ = await perform(locked ? "Conversation locked" : "Conversation unlocked") { client in
            try await client.setLocked(details.pr.id, locked: locked)
        }
    }

    @discardableResult
    func merge() async -> Bool {
        guard let details, details.canMerge, details.mergeMethods.contains(mergeMethod) else {
            report(MergeportError.message("GitHub does not currently report this PR as merge-ready.")); return false
        }
        let method = mergeMethod
        isMerging = true
        defer { isMerging = false }
        guard let stack = details.pr.stack else {
            return await perform("PR merged", local: { $0.pr.state = "MERGED" }) { client in
                try await client.merge(repository: self.reference.repository, number: self.reference.number, sha: details.headSHA, method: method)
            }
        }
        // Stacked PRs merge asynchronously, together with every open PR below them.
        let numbers = stack.mergedTogether(with: details.pr.number)
        var outcome = AsyncMergeOutcome.merged
        let merged = await perform(
            numbers.count > 1 ? "Merged \(PRStack.list(numbers))" : "PR merged",
            local: { if outcome == .merged { $0.pr.state = "MERGED" } }
        ) { client in
            outcome = try await client.mergeAsync(
                repository: self.reference.repository, number: self.reference.number, sha: details.headSHA, method: method)
        }
        if merged, outcome == .enqueued {
            notice = numbers.count > 1 ? "Added \(PRStack.list(numbers)) to the merge queue" : "Added to the merge queue"
        }
        return merged
    }

    /// Applies what GitHub just accepted to the local PR so the tab, card and page update instantly.
    private func applyLocally(_ change: (inout ReviewDetails) -> Void) {
        guard var updated = details else { return }
        change(&updated)
        details = updated
        app?.applyLocalChange(updated.pr, tabID: reference.id)
    }

    private func perform(
        _ message: String, local: ((inout ReviewDetails) -> Void)? = nil,
        operation: (GitHubClient) async throws -> Void
    ) async -> Bool {
        guard !isPerforming, let app else { return false }
        guard !app.isDemo else { report(MergeportError.message("Sample reviews are local previews. Connect GitHub to submit changes.")); return false }
        isPerforming = true
        let generation = app.accountSessionID
        error = nil; notice = nil
        do {
            try await operation(app.githubClient())
            isPerforming = false
            guard app.accountSessionID == generation else {
                throw MergeportError.message("The account changed during this action. Check GitHub before retrying.")
            }
            notice = message
            if let local { applyLocally(local) }
            // GitHub already applied the change; refreshing shouldn't keep the tab locked.
            Task {
                await app.refresh()
                await self.load(force: true)
            }
            return true
        } catch let transport as URLError {
            isPerforming = false
            report(MergeportError.message("The connection failed while submitting. Check GitHub before retrying: \(transport.localizedDescription)"))
            return false
        } catch {
            isPerforming = false
            report(error)
            return false
        }
    }

    func report(_ error: Error) {
        self.error = error.localizedDescription
        NSLog("Mergeport review: %@", error.localizedDescription)
    }
}
