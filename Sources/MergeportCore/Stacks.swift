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

    public init(
      id: String, position: Int, number: Int, title: String, url: URL, state: String = "OPEN",
      isDraft: Bool = false, head: String, base: String, author: String,
      reviewDecision: String? = nil, mergeState: String = "UNKNOWN"
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
    }

    public var isOpen: Bool { state == "OPEN" }

    /// Would stop a merge from above: GitHub merges every open PR below the one you merge.
    public var holdsUpStack: Bool {
      isOpen
        && (isDraft || reviewDecision == "CHANGES_REQUESTED" || reviewDecision == "REVIEW_REQUIRED"
          || mergeState == "BLOCKED" || mergeState == "DIRTY")
    }

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
