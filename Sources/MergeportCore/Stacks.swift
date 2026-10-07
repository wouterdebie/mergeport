import Foundation

/// A GitHub stacked pull request chain, as seen from one of its PRs.
public struct PRStack: Codable, Hashable, Sendable {
  public struct Entry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var position: Int
    public var number: Int
    public var title: String
    public var url: URL
    public var state: String
    public var isDraft: Bool
    public var head: String
    public var base: String
    public var author: String
    public var reviewDecision: String?
    public var mergeState: String
    public var checks: CheckState
    /// Pending review requests (users and teams).
    public var reviewRequests: Int
    /// Submitted reviews, including comments.
    public var reviews: Int

    public init(
      id: String, position: Int, number: Int, title: String, url: URL, state: String = "OPEN",
      isDraft: Bool = false, head: String, base: String, author: String,
      reviewDecision: String? = nil, mergeState: String = "UNKNOWN", checks: CheckState = .unknown,
      reviewRequests: Int = 0, reviews: Int = 0
    ) {
      self.id = id
      self.position = position
      self.number = number
      self.title = title
      self.url = url
      self.state = state
      self.isDraft = isDraft
      self.head = head
      self.base = base
      self.author = author
      self.reviewDecision = reviewDecision
      self.mergeState = mergeState
      self.checks = checks
      self.reviewRequests = reviewRequests
      self.reviews = reviews
    }

    private enum CodingKeys: String, CodingKey {
      case id, position, number, title, url, state, isDraft, head, base, author, reviewDecision
      case mergeState, checks, reviewRequests, reviews
    }

    // Saved workspaces predate the readiness fields.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        id: try c.decode(String.self, forKey: .id), position: try c.decode(Int.self, forKey: .position),
        number: try c.decode(Int.self, forKey: .number), title: try c.decode(String.self, forKey: .title),
        url: try c.decode(URL.self, forKey: .url), state: try c.decode(String.self, forKey: .state),
        isDraft: try c.decode(Bool.self, forKey: .isDraft), head: try c.decode(String.self, forKey: .head),
        base: try c.decode(String.self, forKey: .base), author: try c.decode(String.self, forKey: .author),
        reviewDecision: try c.decodeIfPresent(String.self, forKey: .reviewDecision),
        mergeState: try c.decode(String.self, forKey: .mergeState),
        checks: try c.decodeIfPresent(CheckState.self, forKey: .checks) ?? .unknown,
        reviewRequests: try c.decodeIfPresent(Int.self, forKey: .reviewRequests) ?? 0,
        reviews: try c.decodeIfPresent(Int.self, forKey: .reviews) ?? 0)
    }

    public var isOpen: Bool { state == "OPEN" }

    /// Needs an approval but nobody has been asked and nobody has reviewed it yet.
    public var needsReviewer: Bool {
      isOpen && !isDraft && reviewDecision == "REVIEW_REQUIRED" && reviewRequests == 0 && reviews == 0
    }

    /// GitHub only merges stacks with a linear history; it shows "Rebase stack" then.
    public var needsRebase: Bool { isOpen && mergeState == "BEHIND" }

    /// Why this layer can't merge yet, or nil when it meets the trunk's rules.
    public var problem: String? {
      guard isOpen else { return nil }
      if isDraft { return "Draft" }
      if mergeState == "DIRTY" { return "Merge conflicts" }
      if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
      if checks == .failure { return "Checks failing" }
      if needsReviewer { return "No reviewer" }
      if reviewDecision == "REVIEW_REQUIRED" { return "Needs review" }
      if checks == .pending { return "Checks running" }
      if needsRebase { return "Needs rebase" }
      if mergeState == "BLOCKED" { return "Blocked" }
      return nil
    }

    /// Short status for the stack map.
    public var statusLabel: String {
      switch state {
      case "MERGED": return "Merged"
      case "CLOSED": return "Closed"
      default: return problem ?? (reviewDecision == "APPROVED" ? "Approved" : "Ready")
      }
    }

    /// Would stop a merge from above: GitHub merges every open PR below the one you merge.
    public var holdsUpStack: Bool { problem != nil }

    public var displayNumber: String { "#" + String(number) }
  }

  public var number: Int
  /// The trunk the bottom PR targets; every layer must meet its rules.
  public var base: String
  public var size: Int
  public var position: Int
  /// Bottom (position 1) to top.
  public var entries: [Entry]

  public init(number: Int, base: String, size: Int, position: Int, entries: [Entry]) {
    self.number = number
    self.base = base
    self.size = size
    self.position = position
    self.entries = entries.sorted { $0.position < $1.position }
  }

  /// Open PRs below this one; merging this PR merges them too.
  public var openBelow: [Entry] { entries.filter { $0.position < position && $0.isOpen } }

  /// The lowest open PR below that isn't ready yet.
  public var blocker: Entry? { openBelow.first(where: \.holdsUpStack) }

  public var openEntries: [Entry] { entries.filter(\.isOpen) }
  public var readyCount: Int { openEntries.filter { !$0.holdsUpStack }.count }
  /// "2 of 3 ready" or "All 3 ready".
  public var readinessLabel: String {
    let open = openEntries.count
    return readyCount == open ? (open == 1 ? "Ready" : "All \(open) ready") : "\(readyCount) of \(open) ready"
  }

  /// Layers that need an approval nobody has been asked for, anywhere in the stack.
  public var needingReviewer: [Entry] { entries.filter(\.needsReviewer) }
  public var needsRebase: Bool { entries.contains(where: \.needsRebase) }

  public var positionLabel: String { "\(position)/\(size)" }

  /// "#12", "#12 and #13", "#12, #13 and #14".
  public static func list(_ numbers: [Int]) -> String {
    let labels = numbers.map { "#" + String($0) }
    guard labels.count > 1 else { return labels.first ?? "" }
    return labels.dropLast().joined(separator: ", ") + " and " + labels.last!
  }

  /// PR numbers a merge of this PR lands, bottom first.
  public func mergedTogether(with number: Int) -> [Int] { openBelow.map(\.number) + [number] }
}

/// Final outcome of GitHub's asynchronous merge.
public enum AsyncMergeOutcome: Equatable, Sendable {
  case merged
  case enqueued
}
