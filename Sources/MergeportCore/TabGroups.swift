import Foundation

/// Keeps related review tabs next to each other, like browser tab groups.
public enum TabGroups {
  /// Where a new item goes: at the end of the group it is related to, else at the end.
  public static func insertionIndex<T>(for item: T, in items: [T], related: (T, T) -> Bool) -> Int {
    guard let last = items.lastIndex(where: { related($0, item) }) else { return items.count }
    return runs(items, related: related).first { $0.contains(last) }?.upperBound ?? items.count
  }

  /// Stable clustering: each item stays where its group first appears; the rest of the group follows it.
  public static func clustered<T>(_ items: [T], related: (T, T) -> Bool) -> [T] {
    var placed = Array(repeating: false, count: items.count)
    var result: [T] = []
    for start in items.indices where !placed[start] {
      var group = [start]
      placed[start] = true
      var cursor = 0
      while cursor < group.count {
        let member = items[group[cursor]]
        for candidate in items.indices where !placed[candidate] && related(member, items[candidate]) {
          placed[candidate] = true
          group.append(candidate)
        }
        cursor += 1
      }
      result += group.sorted().map { items[$0] }
    }
    return result
  }

  /// Consecutive runs of related items, as index ranges. Single unrelated items are runs of one.
  public static func runs<T>(_ items: [T], related: (T, T) -> Bool) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    var start = 0
    for index in items.indices.dropFirst()
    where !items[start..<index].contains(where: { related($0, items[index]) }) {
      runs.append(start..<index)
      start = index
    }
    if !items.isEmpty { runs.append(start..<items.count) }
    return runs
  }

  /// Removes a ticket mention such as `[CON-205]`, `(CON-205)` or `CON-205:` from a title.
  public static func title(_ title: String, without ticket: String?) -> String {
    guard let ticket, !ticket.isEmpty else { return title }
    let escaped = NSRegularExpression.escapedPattern(for: ticket)
    let patterns = [
      "\\s*[\\[(]\\s*\(escaped)\\s*[\\])]\\s*",
      "^\\s*\(escaped)\\s*[:\\-–—|/]?\\s*",
      "\\s*[:\\-–—|/]?\\s*\(escaped)\\s*$",
    ]
    var result = title
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    result = result.trimmingCharacters(in: .whitespaces)
    return result.isEmpty ? title : result
  }
}

/// What review tabs are grouped by. Each group shows its shared label once.
public enum TabGrouping: String, CaseIterable, Codable, Sendable {
  case related, ticket, branch, stack, repository, none

  public var title: String {
    switch self {
    case .related: "Ticket, source branch or stack"
    case .ticket: "Ticket"
    case .branch: "Source branch"
    case .stack: "Stack"
    case .repository: "Repository"
    case .none: "Don't group"
    }
  }
}

/// Chrome-style tab sizing: tabs share the strip until they reach their minimum width, then it scrolls.
public enum TabSizing {
  public static let maximum: Double = 280
  public static let minimum: Double = 104

  public static func width(tabs: Int, available: Double) -> Double {
    guard tabs > 0 else { return maximum }
    return min(maximum, max(minimum, (available / Double(tabs)).rounded(.down)))
  }
}

/// Where review tabs are shown.
public enum TabLayout: String, CaseIterable, Codable, Sendable {
  case topBar, sidebar

  public var title: String {
    switch self {
    case .topBar: "Top bar"
    case .sidebar: "Sidebar"
    }
  }
}

/// When tabs of merged or closed PRs close by themselves.
public enum TabAutoClose: String, CaseIterable, Codable, Sendable {
  case off, immediately, afterDay

  public var title: String {
    switch self {
    case .off: "Never"
    case .immediately: "Right away"
    case .afterDay: "After a day"
    }
  }

  /// `finishedAt` is when Mergeport saw the PR merge or close while its tab was open.
  public func shouldClose(finishedAt: Date?, now: Date = .now) -> Bool {
    guard let finishedAt else { return false }
    switch self {
    case .off: return false
    case .immediately: return true
    case .afterDay: return now.timeIntervalSince(finishedAt) >= 24 * 60 * 60
    }
  }
}
