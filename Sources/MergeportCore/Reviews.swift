import Foundation

public enum ReviewEvent: String, Codable, CaseIterable, Sendable {
  case comment = "COMMENT"
  case approve = "APPROVE"
  case requestChanges = "REQUEST_CHANGES"
  public var title: String {
    switch self {
    case .comment: "Comment"
    case .approve: "Approve"
    case .requestChanges: "Request changes"
    }
  }
}

public enum MergeMethod: String, Codable, CaseIterable, Sendable {
  case squash, merge, rebase
  public var title: String {
    switch self {
    case .squash: "Squash and merge"
    case .merge: "Create merge commit"
    case .rebase: "Rebase and merge"
    }
  }
}

public enum DiffSide: String, Codable, Sendable {
  case left = "LEFT"
  case right = "RIGHT"
}

public struct DiffAnchor: Codable, Hashable, Sendable {
  public var path: String
  public var line: Int
  public var side: DiffSide
  public init(path: String, line: Int, side: DiffSide) {
    self.path = path
    self.line = line
    self.side = side
  }
}

public struct DraftComment: Identifiable, Codable, Sendable {
  public var id: UUID
  public var anchor: DiffAnchor
  public var body: String
  public init(anchor: DiffAnchor, body: String, id: UUID = UUID()) {
    self.id = id
    self.anchor = anchor
    self.body = body
  }
}

public struct ReviewDraft: Codable, Sendable {
  public var event: ReviewEvent = .comment
  public var body = ""
  public var comments: [DraftComment] = []
  public var headSHA: String?
  public var discussion = ""
  public var replies: [String: String] = [:]
  public init() {}
  public var hasReviewContent: Bool {
    !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comments.isEmpty
  }
  public var hasContent: Bool {
    hasReviewContent || !discussion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || replies.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  public func validate(currentHead: String) throws {
    guard headSHA == currentHead else {
      throw MergeportError.message(
        "The PR changed since this review was drafted. Refresh and review the new changes before submitting."
      )
    }
    guard event != .comment || hasReviewContent else {
      throw MergeportError.message("Add a review summary or an inline comment.")
    }
    guard event != .requestChanges || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MergeportError.message("Add a summary explaining the requested changes.")
    }
    guard
      comments.allSatisfy({
        $0.anchor.line > 0 && !$0.anchor.path.isEmpty
          && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw MergeportError.message("An inline comment has an invalid line, path or empty body.")
    }
  }
}

public struct PullRequestFile: Decodable, Hashable, Identifiable, Sendable {
  public let filename: String
  public let previousFilename: String?
  public let status: String
  public let additions: Int
  public let deletions: Int
  public let patch: String?
  public var id: String { filename }
}

public struct DiscussionComment: Identifiable, Sendable {
  public let id: String
  public let databaseID: Int?
  public let author: String
  public let body: String
  public let date: Date
  public let url: URL?
  public var bodyHTML: String? = nil
  public var authorAvatarURL: URL? = nil
}

public struct SubmittedReview: Identifiable, Sendable {
  public let id: Int
  public let author: String
  public let body: String
  public let state: String
  public let date: Date?
  public var bodyHTML: String? = nil
}

public struct ReviewThread: Identifiable, Sendable {
  public let id: String
  public let path: String
  public let line: Int?
  public let isResolved: Bool
  public let isOutdated: Bool
  public let canReply: Bool
  public let canResolve: Bool
  public let canUnresolve: Bool
  public let comments: [DiscussionComment]
  public var startLine: Int? = nil
  public var isLeftSide = false
  /// The diff hunk GitHub stored with the first comment. It ends at the commented line.
  public var diffHunk: String? = nil
  /// The REST id of the review the thread was opened in.
  public var reviewID: Int? = nil

  /// The lines GitHub shows above a review thread: the commented range, or the last four lines.
  public var snippet: [DiffLine] {
    guard let diffHunk, let diff = try? UnifiedDiff.parse(diffHunk) else { return [] }
    let lines = diff.lines.filter { $0.kind != .hunk && $0.kind != .note }
    if let startLine, startLine != line,
      let start = lines.lastIndex(where: { (isLeftSide ? $0.oldLine : $0.newLine) == startLine })
    {
      return Array(lines[start...])
    }
    return Array(lines.suffix(4))
  }
}

/// A finding Copilot lists in its review summary, linked to the comment that explains it.
public struct ReviewFinding: Sendable, Hashable {
  public let title: String
  public let severity: String?

  /// Reads Copilot's "open findings" list: `<img alt="Low severity"> [Title](#discussion_r123)`.
  public static func parse(_ body: String) -> [Int: ReviewFinding] {
    guard
      let link = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(#discussion_r(\d+)\)"#),
      let alt = try? NSRegularExpression(pattern: #"alt="([A-Za-z]+) severity""#)
    else { return [:] }
    var result: [Int: ReviewFinding] = [:]
    for line in body.components(separatedBy: "\n") where line.contains("#discussion_r") {
      let range = NSRange(line.startIndex..., in: line)
      let severity = alt.firstMatch(in: line, range: range)
        .flatMap { Range($0.range(at: 1), in: line) }.map { String(line[$0]) }
      for match in link.matches(in: line, range: range) {
        guard let title = Range(match.range(at: 1), in: line),
          let id = Range(match.range(at: 2), in: line).flatMap({ Int(line[$0]) })
        else { continue }
        result[id] = ReviewFinding(title: String(line[title]), severity: severity)
      }
    }
    return result
  }
}

public struct PullRequestCheck: Identifiable, Sendable {
  public enum Outcome: Int, Sendable, CaseIterable {
    case failing, pending, skipped, successful
    public var title: String {
      switch self {
      case .failing: "failing"
      case .pending: "in progress"
      case .skipped: "skipped"
      case .successful: "successful"
      }
    }
  }

  public let id: String
  public let name: String
  public let state: String
  public let url: URL?
  /// The Actions workflow ("Test Suite") and trigger ("pull_request") GitHub shows around the job name.
  public var workflow: String? = nil
  public var event: String? = nil
  public var startedAt: Date? = nil
  public var completedAt: Date? = nil
  public var summary: String? = nil

  public init(
    id: String, name: String, state: String, url: URL?, workflow: String? = nil,
    event: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil, summary: String? = nil
  ) {
    self.id = id
    self.name = name
    self.state = state
    self.url = url
    self.workflow = workflow
    self.event = event
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.summary = summary
  }

  public var outcome: Outcome {
    switch state.lowercased() {
    case "success": .successful
    case "neutral", "skipped", "stale": .skipped
    case "failure", "error", "cancelled", "timed_out", "action_required", "startup_failure": .failing
    default: .pending
    }
  }

  /// "Test Suite / Run Tests (pull_request)", like GitHub's checks list.
  public var title: String {
    var text = [workflow, name].compactMap { $0 }.joined(separator: " / ")
    if let event { text += " (\(event))" }
    return text
  }

  /// "Successful in 5m", "Skipped 31 minutes ago", "Started 2m ago".
  public func status(now: Date = .now) -> String {
    let label =
      switch state.lowercased() {
      case "success": "Successful"
      case "neutral", "skipped": "Skipped"
      case "cancelled": "Cancelled"
      case "timed_out": "Timed out"
      case "action_required": "Action required"
      case "failure", "error", "startup_failure": "Failing"
      case "queued", "waiting", "requested", "expected": "Queued"
      default: "In progress"
      }
    if outcome == .pending {
      guard let startedAt else { return summary ?? label }
      return "\(label) — started \(Self.duration(now.timeIntervalSince(startedAt))) ago"
    }
    if outcome == .skipped, let completedAt {
      return "\(label) \(Self.duration(now.timeIntervalSince(completedAt))) ago"
    }
    if let startedAt, let completedAt {
      return "\(label) in \(Self.duration(completedAt.timeIntervalSince(startedAt)))"
    }
    return summary ?? label
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value < 60 { return "\(value)s" }
    if value < 3600 { return "\(value / 60)m" + (value % 60 > 0 && value < 600 ? " \(value % 60)s" : "") }
    if value < 86400 { return "\(value / 3600)h" + (value % 3600 >= 60 ? " \(value % 3600 / 60)m" : "") }
    return "\(value / 86400)d"
  }
}

public struct PullRequestCommit: Identifiable, Sendable {
  public let id: String
  public let message: String
  public let author: String
  public let date: Date
  public let url: URL
  /// GitHub's signature verification; nil when unknown.
  public var verified: Bool? = nil
  public var checks: [PullRequestCheck] = []

  public init(
    id: String, message: String, author: String, date: Date, url: URL, verified: Bool? = nil,
    checks: [PullRequestCheck] = []
  ) {
    self.id = id
    self.message = message
    self.author = author
    self.date = date
    self.url = url
    self.verified = verified
    self.checks = checks
  }
}

public struct ReviewDetails: Sendable {
  public var pr: PullRequest
  public let viewer: Viewer
  public let body: String
  public let headSHA: String
  public let files: [PullRequestFile]
  public let comments: [DiscussionComment]
  public let reviews: [SubmittedReview]
  public let threads: [ReviewThread]
  public var checks: [PullRequestCheck]
  public var commits: [PullRequestCommit]
  public let mergeMethods: [MergeMethod]
  public let canUpdate: Bool
  public let canWrite: Bool
  public let notices: [String]
  public var bodyHTML: String? = nil
  public var createdAt: Date? = nil
  public var events: [ConversationEvent] = []
  /// Avatar URLs reported by GitHub, keyed by `ReviewDetails.avatarKey(_:)`.
  public var avatars: [String: URL] = [:]
  public var sidebar = PullRequestSidebar()

  /// Reviewers like GitHub's sidebar: pending requests first, then everyone who reviewed.
  public var sidebarReviewers: [SidebarReviewer] {
    var result: [SidebarReviewer] = []
    var seen = Set<String>()
    for login in sidebar.requestedReviewers where seen.insert(Self.avatarKey(login)).inserted {
      result.append(SidebarReviewer(login: login, isTeam: false, status: .requested))
    }
    for team in sidebar.requestedTeams where seen.insert("team:" + team.lowercased()).inserted {
      result.append(SidebarReviewer(login: team, isTeam: true, status: .requested))
    }
    var latest: [String: SubmittedReview] = [:]
    var order: [String] = []
    for item in reviews.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    where item.state != "PENDING"
      && item.author.caseInsensitiveCompare(pr.author) != .orderedSame
    {
      let key = Self.avatarKey(item.author)
      if latest[key] == nil { order.append(key) }
      if item.state != "COMMENTED" || latest[key] == nil || latest[key]?.state == "COMMENTED" {
        latest[key] = item
      }
    }
    for key in order where seen.insert(key).inserted {
      guard let item = latest[key] else { continue }
      let status: SidebarReviewer.Status =
        switch item.state {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "DISMISSED": .dismissed
        default: .commented
        }
      result.append(SidebarReviewer(login: item.author, isTeam: false, status: status))
    }
    return result
  }

  public var participants: [String] {
    var seen = Set<String>()
    let logins =
      sidebar.participants.isEmpty
      ? [pr.author] + comments.map(\.author) + reviews.map(\.author)
        + threads.flatMap { $0.comments.map(\.author) }
      : sidebar.participants
    return logins.filter { seen.insert(Self.avatarKey($0)).inserted }
  }

  public static func avatarKey(_ login: String) -> String {
    var value = login.lowercased()
    if value.hasSuffix("[bot]") { value.removeLast(5) }
    return value
  }

  /// GitHub's avatar for a login. Bots have no `github.com/<login>.png`, so they rely on API data.
  public func avatarURL(for login: String) -> URL? {
    if let url = avatars[Self.avatarKey(login)] { return url }
    if Self.avatarKey(login) == Self.avatarKey(pr.author), let url = pr.authorAvatarURL {
      return url
    }
    guard !login.lowercased().hasSuffix("[bot]"), !CopilotState.isCopilot(login),
      login.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    else { return nil }
    return URL(string: "https://github.com/\(login).png?size=80")
  }

  public static func displayName(_ login: String) -> String {
    if CopilotState.isCopilot(login) { return "Copilot" }
    return login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login
  }

  public static func isBot(_ login: String) -> Bool {
    CopilotState.isCopilot(login) || login.lowercased().hasSuffix("[bot]")
  }
  /// Threads opened in a review, shown beneath it like GitHub's conversation.
  public func threads(in review: SubmittedReview) -> [ReviewThread] {
    threads.filter { $0.reviewID == review.id }
  }

  /// Copilot's findings across all reviews, keyed by review comment database ID.
  public var findings: [Int: ReviewFinding] {
    reviews.reduce(into: [:]) { result, review in
      result.merge(ReviewFinding.parse(review.body)) { first, _ in first }
    }
  }

  public var conversation: [ConversationItem] {
    let shownReviews = reviews.filter { $0.state != "PENDING" }
    let nested = Set(shownReviews.map(\.id))
    let items =
      comments.map { ConversationItem.comment($0) }
      + shownReviews.map { .review($0) }
      + commits.map { .commit($0) }
      + events.map { .event($0) }
      + threads.filter { $0.reviewID.map { !nested.contains($0) } ?? true }.map { .thread($0) }
    let sorted = items.sorted {
      if $0.date == $1.date { return $0.id < $1.id }
      return $0.date < $1.date
    }
    var result: [ConversationItem] = []
    for item in sorted {
      guard case .event(let event) = item, event.reference != nil else {
        result.append(item)
        continue
      }
      if case .references(let group)? = result.last {
        result[result.count - 1] = .references(group + [event])
      } else {
        result.append(.references([event]))
      }
    }
    return result
  }

  public var checkSummary: CheckSummary { CheckSummary(checks) }

  /// Latest non-comment review state per reviewer, as GitHub uses for the merge box.
  public var latestReviewStates: [String: String] {
    var states: [String: String] = [:]
    for review in reviews.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) {
      states[review.author.lowercased()] = review.state
    }
    return states
  }
  public var canMerge: Bool { canWrite && pr.stage == .ready && !mergeMethods.isEmpty }
  public var hasPendingGitHubReview: Bool {
    reviews.contains {
      $0.state == "PENDING" && $0.author.caseInsensitiveCompare(viewer.login) == .orderedSame
    }
  }

}

public struct PullRequestLabel: Sendable, Hashable, Identifiable {
  public let name: String
  /// Hex color without "#", as GitHub returns it.
  public let color: String
  public var id: String { name }
  public init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}

public struct SidebarReviewer: Sendable, Hashable, Identifiable {
  public enum Status: Sendable, Hashable { case requested, approved, changesRequested, commented, dismissed }
  public let login: String
  public let isTeam: Bool
  public let status: Status
  public var id: String { login.lowercased() }
}

public struct PullRequestSidebar: Sendable {
  public var requestedReviewers: [String] = []
  public var requestedTeams: [String] = []
  public var assignees: [String] = []
  public var labels: [PullRequestLabel] = []
  public var milestone: String? = nil
  public var milestoneNumber: Int? = nil
  public var participants: [String] = []
  /// Triage or higher: may change assignees, labels and the milestone.
  public var canTriage = false
  /// `SUBSCRIBED`, `UNSUBSCRIBED` or `IGNORED`; nil when unknown.
  public var subscription: String? = nil
  public var locked = false

  public var isSubscribed: Bool { subscription == "SUBSCRIBED" }

  public init(
    requestedReviewers: [String] = [], requestedTeams: [String] = [], assignees: [String] = [],
    labels: [PullRequestLabel] = [], milestone: String? = nil, milestoneNumber: Int? = nil,
    participants: [String] = [], canTriage: Bool = false, subscription: String? = nil,
    locked: Bool = false
  ) {
    self.requestedReviewers = requestedReviewers
    self.requestedTeams = requestedTeams
    self.assignees = assignees
    self.labels = labels
    self.milestone = milestone
    self.milestoneNumber = milestoneNumber
    self.participants = participants
    self.canTriage = canTriage
    self.subscription = subscription
    self.locked = locked
  }
}

/// A choice offered by sidebar pickers (assignees, labels, milestones).
public struct SidebarOption: Sendable, Hashable, Identifiable {
  public let id: String
  public let title: String
  public var detail: String? = nil
  public var color: String? = nil
  public var number: Int? = nil

  public init(id: String, title: String, detail: String? = nil, color: String? = nil, number: Int? = nil) {
    self.id = id
    self.title = title
    self.detail = detail
    self.color = color
    self.number = number
  }
}

public struct CheckSummary: Sendable, Equatable {
  public var successful = 0
  public var failed = 0
  public var pending = 0
  public var skipped = 0
  public var total: Int { successful + failed + pending + skipped }

  public init(successful: Int = 0, failed: Int = 0, pending: Int = 0, skipped: Int = 0) {
    self.successful = successful
    self.failed = failed
    self.pending = pending
    self.skipped = skipped
  }

  public init(_ checks: [PullRequestCheck]) {
    for check in checks {
      switch check.outcome {
      case .successful: successful += 1
      case .skipped: skipped += 1
      case .failing: failed += 1
      case .pending: pending += 1
      }
    }
  }

  public var title: String {
    if total == 0 { return "No checks" }
    if failed > 0 { return "Some checks were not successful" }
    if pending > 0 { return "Some checks haven't completed yet" }
    return "All checks have passed"
  }

  public var detail: String {
    var parts: [String] = []
    if failed > 0 { parts.append("\(failed) failing") }
    if pending > 0 { parts.append("\(pending) in progress") }
    if skipped > 0 { parts.append("\(skipped) skipped") }
    if successful > 0 { parts.append("\(successful) successful") }
    guard !parts.isEmpty else { return "GitHub reported no checks for this commit." }
    return parts.joined(separator: ", ") + (total == 1 ? " check" : " checks")
  }
}

public struct ConversationEvent: Identifiable, Sendable {
  public let id: String
  public let actor: String
  public let action: String
  public let date: Date
  public let symbol: String
  public let url: URL?
  public let title: String?
  public let reference: Reference?

  public struct Reference: Sendable, Hashable {
    public enum State: String, Sendable { case open, draft, merged, closed }
    public let title: String
    public let number: Int
    public let repository: String?
    public let url: URL
    public let state: State
    public let isPullRequest: Bool

    public init(
      title: String, number: Int, repository: String? = nil, url: URL, state: State,
      isPullRequest: Bool = true
    ) {
      self.title = title
      self.number = number
      self.repository = repository
      self.url = url
      self.state = state
      self.isPullRequest = isPullRequest
    }
  }

  public init(
    id: String, actor: String, action: String, date: Date,
    symbol: String = "circle", url: URL? = nil, title: String? = nil,
    reference: Reference? = nil
  ) {
    self.id = id
    self.actor = actor
    self.action = action
    self.date = date
    self.symbol = symbol
    self.url = url
    self.title = title
    self.reference = reference
  }
}

public enum ConversationItem: Identifiable, Sendable {
  case comment(DiscussionComment)
  case review(SubmittedReview)
  case commit(PullRequestCommit)
  case event(ConversationEvent)
  case thread(ReviewThread)
  /// Consecutive cross-references, shown together like GitHub's "This was referenced".
  case references([ConversationEvent])

  public var id: String {
    switch self {
    case .comment(let value): "comment-\(value.id)"
    case .review(let value): "review-\(value.id)"
    case .commit(let value): "commit-\(value.id)"
    case .event(let value): "event-\(value.id)"
    case .thread(let value): "thread-\(value.id)"
    case .references(let value): "references-\(value.first?.id ?? "")"
    }
  }
  public var date: Date {
    switch self {
    case .comment(let value): value.date
    case .review(let value): value.date ?? .distantPast
    case .commit(let value): value.date
    case .event(let value): value.date
    case .thread(let value): value.comments.first?.date ?? .distantPast
    case .references(let value): value.first?.date ?? .distantPast
    }
  }
}
public enum DiffLineKind: Sendable { case context, addition, deletion, hunk, note }

public struct DiffLine: Identifiable, Sendable {
  public let id: Int
  public let kind: DiffLineKind
  public let text: String
  public let oldLine: Int?
  public let newLine: Int?
  public let highlights: [Range<Int>]
  public let coarseHighlights: Bool

  public init(
    id: Int, kind: DiffLineKind, text: String, oldLine: Int?, newLine: Int?,
    highlights: [Range<Int>] = [], coarseHighlights: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.oldLine = oldLine
    self.newLine = newLine
    self.highlights = highlights
    self.coarseHighlights = coarseHighlights
  }
  public func anchor(path: String) -> DiffAnchor? {
    if kind == .deletion, let oldLine { return DiffAnchor(path: path, line: oldLine, side: .left) }
    if let newLine { return DiffAnchor(path: path, line: newLine, side: .right) }
    return nil
  }
}

public struct UnifiedDiff: Sendable {
  public let lines: [DiffLine]
  public var additions: Int { lines.filter { $0.kind == .addition }.count }
  public var deletions: Int { lines.filter { $0.kind == .deletion }.count }

  public static func parse(_ patch: String) throws -> UnifiedDiff {
    let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
    var old: Int?
    var new: Int?
    var rows: [DiffLine] = []
    let source = patch.components(separatedBy: "\n")
    for (index, text) in source.enumerated() {
      if text.isEmpty {
        guard index == source.count - 1 else {
          throw MergeportError.message(
            "The diff has an unprefixed blank line. Open this file on GitHub.")
        }
        continue
      }
      if text.hasPrefix("@@") {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let left = Range(match.range(at: 1), in: text),
          let right = Range(match.range(at: 2), in: text),
          let oldStart = Int(text[left]), let newStart = Int(text[right])
        else {
          throw MergeportError.message(
            "GitHub returned an invalid diff hunk. Open this file on GitHub to inspect it.")
        }
        old = oldStart
        new = newStart
        rows.append(DiffLine(id: index, kind: .hunk, text: text, oldLine: nil, newLine: nil))
        continue
      }
      if text.hasPrefix("\\") {
        rows.append(DiffLine(id: index, kind: .note, text: text, oldLine: nil, newLine: nil))
        continue
      }
      guard let oldNumber = old, let newNumber = new else {
        throw MergeportError.message("The diff has content outside a hunk. Open this file on GitHub.")
      }
      let kind: DiffLineKind
      let left: Int?
      let right: Int?
      switch text.first {
      case "+":
        kind = .addition
        left = nil
        right = newNumber
        new = newNumber + 1
      case "-":
        kind = .deletion
        left = oldNumber
        right = nil
        old = oldNumber + 1
      case " ":
        kind = .context
        left = oldNumber
        right = newNumber
        old = oldNumber + 1
        new = newNumber + 1
      default:
        throw MergeportError.message(
          "The diff contains an unsupported line. Open this file on GitHub.")
      }
      rows.append(
        DiffLine(
          id: index, kind: kind, text: String(text.dropFirst()), oldLine: left, newLine: right))
    }
    return UnifiedDiff(lines: highlightReplacements(rows))
  }

  private static func highlightReplacements(_ rows: [DiffLine]) -> [DiffLine] {
    var result = rows
    var index = 0
    while index < rows.count {
      guard rows[index].kind == .addition || rows[index].kind == .deletion else {
        index += 1
        continue
      }
      var removed: [Int] = []
      var added: [Int] = []
      while index < rows.count && (rows[index].kind == .addition || rows[index].kind == .deletion) {
        if rows[index].kind == .deletion { removed.append(index) } else { added.append(index) }
        index += 1
      }
      for (old, new) in zip(removed, added) {
        let spans = IntralineChange.between(old: rows[old].text, new: rows[new].text)
        for (position, ranges) in [(old, spans.removed), (new, spans.added)] {
          let row = rows[position]
          result[position] = DiffLine(
            id: row.id, kind: row.kind, text: row.text, oldLine: row.oldLine,
            newLine: row.newLine, highlights: ranges, coarseHighlights: spans.isCoarse)
        }
      }
    }
    return result
  }
}

public struct IntralineChange: Sendable {
  public let removed: [Range<Int>]
  public let added: [Range<Int>]
  public let isCoarse: Bool

  public static func between(old: String, new: String) -> IntralineChange {
    let before = Array(old)
    let after = Array(new)
    var prefix = 0
    var suffix = 0
    while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
    while suffix < min(before.count, after.count) - prefix,
      before[before.count - suffix - 1] == after[after.count - suffix - 1]
    { suffix += 1 }
    let left = Array(before[prefix..<(before.count - suffix)])
    let right = Array(after[prefix..<(after.count - suffix)])
    // Avoid quadratic work on minified/generated replacement lines.
    if left.count + right.count > 4096 {
      return IntralineChange(
        removed: left.isEmpty ? [] : [prefix..<(before.count - suffix)],
        added: right.isEmpty ? [] : [prefix..<(after.count - suffix)], isCoarse: true)
    }
    let changes = right.difference(from: left)
    var deleted: [Int] = []
    var inserted: [Int] = []
    for change in changes {
      switch change {
      case .remove(let offset, _, _): deleted.append(prefix + offset)
      case .insert(let offset, _, _): inserted.append(prefix + offset)
      }
    }
    return IntralineChange(removed: ranges(deleted), added: ranges(inserted), isCoarse: false)
  }

  private static func ranges(_ offsets: [Int]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for offset in offsets.sorted() {
      if let last = result.last, last.upperBound == offset {
        result[result.count - 1] = last.lowerBound..<(offset + 1)
      } else {
        result.append(offset..<(offset + 1))
      }
    }
    return result
  }
}

public enum DemoReview {
  private static let demoChecks = [
    PullRequestCheck(
      id: "sample-slack", name: "Post review request", state: "skipped", url: nil,
      workflow: "Notify Slack", event: "pull_request", completedAt: .now.addingTimeInterval(-1860)),
    PullRequestCheck(
      id: "sample-check", name: "Run Tests", state: "success", url: nil, workflow: "Test Suite",
      event: "pull_request", startedAt: .now.addingTimeInterval(-2100),
      completedAt: .now.addingTimeInterval(-1800)),
  ]

  public static func details(for pr: PullRequest) -> ReviewDetails {
    let file = PullRequestFile(
      filename: "src/routing.ts", previousFilename: nil, status: "modified", additions: 3,
      deletions: 2,
      patch: """
        @@ -1,3 +1,4 @@
        -export function route(host: string) {
        -  return host.split(".")[0];
        +export function route(host: string): string {
        +  const tenant = host.trim().toLowerCase().split(".")[0];
        +  return tenant || "default";
         }
        """)
    let tests = PullRequestFile(
      filename: "tests/routing.test.ts", previousFilename: nil, status: "added", additions: 3,
      deletions: 0,
      patch: """
        @@ -0,0 +1,3 @@
        +test("routes a tenant hostname", () => {
        +  expect(route("ACME.example.com")).toBe("acme");
        +});
        """)
    let comment = DiscussionComment(
      id: "sample-thread", databaseID: 101, author: "copilot-pull-request-reviewer",
      body: "An empty hostname now routes to `default`; cover it in the tests.", date: .now,
      url: nil,
      bodyHTML: """
        <p>An empty hostname now routes to <code>default</code>; cover it in the tests.</p>
        <div class="my-2 border rounded-2 js-suggested-changes-blob diff-view"><div class="f6 p-2 lh-condensed border-bottom d-flex"><div class="flex-auto flex-items-center color-fg-muted">Suggested change</div></div>
        <div class="blob-wrapper data file"><table class="d-table tab-size mb-0 width-full"><tbody>
        <tr class="border-0"><td class="blob-num blob-num-deletion" data-line-number="3"></td><td class="blob-code-inner blob-code-deletion blob-code-marker-deletion">  return tenant || "default";</td></tr>
        <tr class="border-0"><td class="blob-num blob-num-addition" data-line-number="3"></td><td class="blob-code-inner blob-code-addition blob-code-marker-addition">  return tenant <span class="x x-first x-last">?? </span>"default";</td></tr>
        </tbody></table></div></div>
        """)
    return ReviewDetails(
      pr: pr, viewer: Viewer(login: "you"),
      body:
        "## Summary\nNormalize tenant hostnames and keep a safe default.\n\n## Testing\n- Existing routing tests pass\n- Adds coverage for mixed-case hostnames",
      headSHA: String(repeating: "a", count: 40), files: [file, tests], comments: [],
      reviews: [
        SubmittedReview(
          id: 1, author: "copilot-pull-request-reviewer",
          body: """
            ### 🔵 Needs a closer look

            - <img alt="Low severity"> [Cover the empty hostname](#discussion_r101) · New
            """,
          state: "COMMENTED", date: .now,
          bodyHTML: """
            <h3>🔵 Needs a closer look</h3>
            <details open><summary><strong>1 open finding</strong></summary>
            <ul><li><a href="#discussion_r101">Cover the empty hostname</a> · New</li></ul></details>
            """)
      ],
      threads: [
        ReviewThread(
          id: "sample-thread", path: file.filename, line: 3, isResolved: false, isOutdated: false,
          canReply: true, canResolve: true, canUnresolve: true, comments: [comment],
          diffHunk: file.patch?.components(separatedBy: "\n").dropLast().joined(separator: "\n"),
          reviewID: 1)
      ],
      checks: demoChecks,
      commits: [
        PullRequestCommit(
          id: String(repeating: "a", count: 40), message: "Normalize tenant hostnames",
          author: "alex", date: .now, url: pr.url, verified: true, checks: demoChecks)
      ],
      mergeMethods: [.squash, .merge], canUpdate: true, canWrite: true,
      notices: [
        "Sample review: no GitHub actions are submitted. You can try drafting inline comments locally."
      ],
      bodyHTML: """
        <h2>Summary</h2><p>Normalize tenant hostnames and keep a safe default.</p>
        <table><thead><tr><th>Input</th><th>Result</th></tr></thead>
        <tbody><tr><td><code>ACME.example.com</code></td><td>acme</td></tr>
        <tr><td>Empty hostname</td><td>default</td></tr></tbody></table>
        <h2>Testing</h2><ul><li>Existing routing tests pass</li><li>Adds coverage for mixed-case hostnames</li></ul>
        <details><summary>Implementation details</summary><pre><code>const tenant = host.trim().toLowerCase();</code></pre></details>
        """,
      createdAt: .now.addingTimeInterval(-3600),
      events: [
        ConversationEvent(
          id: "sample-request", actor: "you", action: "requested review from Copilot",
          date: .now.addingTimeInterval(-1800), symbol: "eye"),
        ConversationEvent(
          id: "sample-ready", actor: "you", action: "marked this PR ready for review",
          date: .now.addingTimeInterval(-900), symbol: "eye"),
        ConversationEvent(
          id: "sample-ref-1", actor: "you", action: "referenced this PR",
          date: .now.addingTimeInterval(-600), symbol: "link",
          reference: .init(
            title: "Route tenant hostnames through the Rust service", number: 452,
            url: URL(string: "https://github.com/acme/platform/pull/452")!, state: .merged)),
        ConversationEvent(
          id: "sample-ref-2", actor: "you", action: "referenced this PR",
          date: .now.addingTimeInterval(-590), symbol: "link",
          reference: .init(
            title: "Email delivery follow-ups", number: 460,
            url: URL(string: "https://github.com/acme/platform/issues/460")!, state: .open,
            isPullRequest: false)),
      ],
      sidebar: PullRequestSidebar(
        requestedReviewers: ["copilot-pull-request-reviewer"], requestedTeams: ["platform-team"],
        labels: [
          PullRequestLabel(name: "email", color: "1d76db"),
          PullRequestLabel(name: "rust", color: "dea584"),
        ], milestone: "Q4 migration", milestoneNumber: 1, canTriage: true,
        subscription: "SUBSCRIBED"))
  }
}
