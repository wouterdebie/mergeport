import Foundation

/// Which PRs the floating status panel lists.
public enum PanelFilter: String, CaseIterable, Codable, Sendable {
  case involved, mine, reviews, all

  public var title: String {
    switch self {
    case .involved: "Mine & reviews"
    case .mine: "Mine"
    case .reviews: "Reviews"
    case .all: "All"
    }
  }

  public func includes(_ pr: PullRequest, login: String) -> Bool {
    switch self {
    case .involved: pr.isMine(login) || pr.reviewRequested
    case .mine: pr.isMine(login)
    case .reviews: pr.reviewRequested
    case .all: true
    }
  }
}

public enum StatusPanel {
  /// What you act on first comes first.
  public static let lanes: [WorkflowStage] = [.review, .attention, .ready, .waiting, .draft]

  /// PRs where the next step is yours: a requested review, or your PR needing attention or ready to merge.
  public static func needsYou(_ pr: PullRequest, login: String) -> Bool {
    guard pr.state == "OPEN" else { return false }
    if pr.needsMyReview { return true }
    return pr.isMine(login) && (pr.stage == .attention || pr.stage == .ready)
  }

  /// A short reason when a refresh changed a PR in a way worth your attention, nil otherwise.
  /// Only your PRs and PRs you're asked to review are tracked; other PRs in followed repositories are noise.
  public static func change(from old: PullRequest?, to new: PullRequest, login: String) -> String? {
    guard new.state == "OPEN" else { return nil }
    guard let old else { return new.needsMyReview ? "Review requested" : nil }
    guard new.isMine(login) || new.reviewRequested || old.reviewRequested else { return nil }
    if new.needsMyReview && !old.needsMyReview { return "Review requested" }
    if new.reviewDecision != old.reviewDecision {
      switch new.reviewDecision {
      case "APPROVED": return "Approved"
      case "CHANGES_REQUESTED": return "Changes requested"
      default: break
      }
    }
    if new.mergeable == "CONFLICTING" && old.mergeable != "CONFLICTING" { return "Merge conflicts" }
    if new.checks == .failure && old.checks != .failure { return "Checks failed" }
    if new.stage == .ready && old.stage != .ready { return "Ready to merge" }
    if new.copilot == .reviewed && old.copilot != .reviewed { return "Copilot finished reviewing" }
    if new.unresolvedThreads > old.unresolvedThreads {
      let added = new.unresolvedThreads - old.unresolvedThreads
      return added == 1 ? "New review thread" : "\(added) new review threads"
    }
    if new.stage == .attention && old.stage != .attention { return new.waitingReason }
    return nil
  }

  /// Changes between two inbox snapshots, keyed by PR id.
  public static func changes(from old: [PullRequest], to new: [PullRequest], login: String)
    -> [String: String]
  {
    let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [String: String] = [:]
    for pr in new {
      if let reason = change(from: previous[pr.id], to: pr, login: login) { result[pr.id] = reason }
    }
    return result
  }

  /// "now", "5m", "3h", "2d": compact enough for a narrow panel row.
  public static func age(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    if seconds < 86400 * 30 { return "\(seconds / 86400)d" }
    return "\(seconds / (86400 * 30))mo"
  }
}
