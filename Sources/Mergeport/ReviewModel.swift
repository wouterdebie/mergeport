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
    private var lastLoaded: Date?
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
            for file in fresh.files {
                guard let patch = file.patch, !patch.isEmpty else {
                    parsed[file.filename] = .unavailable("GitHub provided no text patch for this file (binary, unchanged content, or a diff-size limit). Open GitHub for the full file.")
                    continue
                }
                do {
                    let diff = try UnifiedDiff.parse(patch)
                    parsed[file.filename] = .available(diff, complete: diff.additions == file.additions && diff.deletions == file.deletions)
                } catch { parsed[file.filename] = .unavailable(error.localizedDescription) }
            }
            diffs = parsed
            details = fresh
            lastLoaded = .now
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

    /// Re-reads the head commit's checks so running tests update without reloading the whole PR.
    func refreshChecks() async {
        guard let app, !app.isDemo, let details, loadTask == nil else { return }
        let generation = app.accountSessionID
        guard let checks = try? await app.githubClient().checks(
            repository: reference.repository, sha: details.headSHA),
              app.accountSessionID == generation, self.details?.headSHA == details.headSHA else { return }
        self.details?.checks = checks
        if let index = self.details?.commits.firstIndex(where: { $0.id == details.headSHA }) {
            self.details?.commits[index].checks = checks
        }
        if CheckSummary(checks).pending == 0 { await load(force: true) }
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
