import Foundation

public enum WorkflowStage: String, Codable, CaseIterable, Sendable {
    case draft, attention, review, waiting, ready

    public var title: String {
        switch self {
        case .draft: "Draft"
        case .attention: "Needs attention"
        case .review: "Your review"
        case .waiting: "Waiting"
        case .ready: "Ready to merge"
        }
    }

    public var symbol: String {
        switch self {
        case .draft: "pencil.circle"
        case .attention: "exclamationmark.circle"
        case .review: "text.bubble"
        case .waiting: "clock"
        case .ready: "checkmark.circle"
        }
    }
}

public enum CheckState: String, Codable, Sendable {
    case success, failure, pending, none, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        case nil: self = .none
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .success: "Checks passing"
        case .failure: "Checks failing"
        case .pending: "Checks running"
        case .none: "No checks"
        case .unknown: "Checks unknown"
        }
    }
}

public enum CopilotState: String, Codable, Sendable {
    case notRequested, requested, reviewed, outdated, unknown

    public var title: String {
        switch self {
        case .notRequested: "Copilot not requested"
        case .requested: "Copilot requested"
        case .reviewed: "Copilot reviewed"
        case .outdated: "Copilot review on earlier commit"
        case .unknown: "Copilot status unknown"
        }
    }

    public static func isCopilot(_ login: String) -> Bool {
        let value = login.lowercased()
        return value == "copilot" || value == "copilot[bot]"
            || value == "copilot-pull-request-reviewer"
            || value == "copilot-pull-request-reviewer[bot]"
    }
}

public struct PullRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var repository: String
    public var url: URL
    public var author: String
    public var head: String
    public var headRepository: String
    public var base: String
    public var updatedAt: Date
    public var isDraft: Bool
    public var state: String
    public var reviewRequested: Bool
    public var reviewDecision: String?
    public var mergeable: String
    public var mergeState: String
    public var checks: CheckState
    public var unresolvedThreads: Int
    /// Unresolved threads started by Copilot; optional so older saved workspaces still decode.
    public var unresolvedCopilotThreads: Int?
    public var copilot: CopilotState
    public var additions: Int
    public var deletions: Int
    public var authorAvatarURL: URL?
    /// GitHub stacked PR membership; nil when the PR isn't stacked (or from older saved workspaces).
    public var stack: PRStack?

    public init(
        id: String, number: Int, title: String, repository: String, url: URL,
        author: String, head: String, headRepository: String? = nil, base: String,
        updatedAt: Date = .now, isDraft: Bool = false, state: String = "OPEN", reviewRequested: Bool = false,
        reviewDecision: String? = nil, mergeable: String = "UNKNOWN", mergeState: String = "UNKNOWN",
        checks: CheckState = .unknown, unresolvedThreads: Int = 0, unresolvedCopilotThreads: Int = 0,
        copilot: CopilotState = .notRequested, additions: Int = 0, deletions: Int = 0,
        authorAvatarURL: URL? = nil, stack: PRStack? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.repository = repository
        self.url = url
        self.author = author
        self.head = head
        self.headRepository = headRepository ?? repository
        self.base = base
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.state = state
        self.reviewRequested = reviewRequested
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.mergeState = mergeState
        self.checks = checks
        self.unresolvedThreads = unresolvedThreads
        self.unresolvedCopilotThreads = unresolvedCopilotThreads
        self.copilot = copilot
        self.additions = additions
        self.deletions = deletions
        self.authorAvatarURL = authorAvatarURL
        self.stack = stack
    }

    public var displayNumber: String { "#" + String(number) }
    public var displayTitle: String { "\(displayNumber) \(repository) \(title)" }

    /// Requested from you and not yet approved; approved PRs don't need another look.
    public var needsMyReview: Bool { reviewRequested && reviewDecision != "APPROVED" }

    public var copilotUnresolved: Int { min(unresolvedCopilotThreads ?? 0, unresolvedThreads) }
    /// Copilot findings are suggestions: they're shown, but don't hold a PR back from merging.
    public var blockingUnresolved: Int { unresolvedThreads - copilotUnresolved }

    /// GitHub distinguishes optional check failures (UNSTABLE) from unmet rules (BLOCKED).
    public static func policyAllowsMerge(_ state: String) -> Bool {
        state == "CLEAN" || state == "UNSTABLE"
    }

    public var isMergeReady: Bool {
        state == "OPEN" && !isDraft && mergeable == "MERGEABLE"
            && Self.policyAllowsMerge(mergeState)
            && (reviewDecision == nil || reviewDecision == "APPROVED")
            && blockingUnresolved == 0 && stack?.blocker == nil
    }

    public var stage: WorkflowStage {
        if state != "OPEN" { return .waiting }
        if isDraft { return .draft }
        if needsMyReview { return .review }
        if checks == .failure || reviewDecision == "CHANGES_REQUESTED"
            || mergeable == "CONFLICTING" || blockingUnresolved > 0 { return .attention }
        if isMergeReady { return .ready }
        // A stack only lands once every layer is approved; catch unrequested reviews early.
        if stack?.needingReviewer.isEmpty == false { return .attention }
        return .waiting
    }

    public var waitingReason: String {
        if isDraft { return copilot == .reviewed ? "Finish feedback, then mark ready" : copilot.title }
        if needsMyReview { return "Your review is requested" }
        if mergeable == "CONFLICTING" { return "Merge conflicts" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if blockingUnresolved > 0 { return "\(blockingUnresolved) unresolved review threads" }
        if let layers = stack?.needingReviewer, !layers.isEmpty, stage != .ready {
            return layers.count == 1
                ? "\(layers[0].displayNumber) in the stack has no reviewer"
                : "\(PRStack.list(layers.map(\.number))) in the stack have no reviewer"
        }
        if checks == .failure {
            return isMergeReady ? "Checks failing; GitHub allows merging" : checks.title
        }
        if reviewDecision == "REVIEW_REQUIRED" { return "Waiting for approval" }
        if checks == .pending || checks == .unknown {
            return isMergeReady ? "\(checks.title); GitHub allows merging" : checks.title
        }
        if let blocker = stack?.blocker, let problem = blocker.problem {
            return "Waiting on \(blocker.displayNumber) below: \(problem.lowercased())"
        }
        if stack?.needsRebase == true { return "Stack needs a rebase on GitHub" }
        switch mergeState {
        case "BEHIND": return "Branch needs updating"
        case "BLOCKED": return "Blocked by repository rules"
        case "UNSTABLE": return isMergeReady
            ? "Some checks are not successful; GitHub allows merging" : "Some checks are not successful"
        case "HAS_HOOKS": return "Merge hooks pending"
        case "UNKNOWN": return "GitHub is calculating mergeability"
        default: return stage == .ready ? "GitHub reports merge-ready" : "Waiting on GitHub"
        }
    }

    public func isMine(_ login: String) -> Bool {
        author.caseInsensitiveCompare(login) == .orderedSame
    }

    public func isSibling(of other: PullRequest) -> Bool {
        number != other.number && repository == other.repository
            && headRepository == other.headRepository && head == other.head
    }
}

public enum InboxScope: String, CaseIterable, Codable, Sendable {
    case all, mine, review

    public var title: String {
        switch self {
        case .all: "All open"
        case .mine: "My pull requests"
        case .review: "Review requested"
        }
    }

    public func includes(_ pr: PullRequest, login: String) -> Bool {
        switch self {
        case .all: true
        case .mine: pr.isMine(login)
        case .review: pr.needsMyReview
        }
    }
}

public enum RepositoryName {
    public static func validate(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
            && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw MergeportError.message("Enter a repository as owner/name, for example apple/swift.")
        }
        return value
    }
}

public enum GitHubNavigation {
    public static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    public static func pullRequestIdentity(_ url: URL) -> (repository: String, number: Int)? {
        guard isGitHubPage(url) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
        return ("\(parts[0])/\(parts[1])", number)
    }

    public static func belongsTo(_ url: URL, pr: PullRequest) -> Bool {
        guard let identity = pullRequestIdentity(url) else { return false }
        return identity.repository.lowercased() == pr.repository.lowercased() && identity.number == pr.number
    }
}

public struct Viewer: Codable, Sendable {
    public var login: String
    public init(login: String) { self.login = login }
}

public struct InboxSnapshot: Codable, Sendable {
    public var viewer: Viewer
    public var pullRequests: [PullRequest]
    public var fetchedAt: Date

    public init(viewer: Viewer, pullRequests: [PullRequest], fetchedAt: Date = .now) {
        self.viewer = viewer
        self.pullRequests = pullRequests
        self.fetchedAt = fetchedAt
    }
}

public enum MergeportError: LocalizedError, Sendable {
    case message(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .unauthorized: "GitHub authorization expired or was revoked. Sign out and connect again."
        }
    }
}
