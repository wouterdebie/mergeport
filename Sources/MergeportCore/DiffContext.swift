import Foundation

public enum ContextDirection: Sendable { case up, down, all }

public struct DiffContextGap: Identifiable, Sendable {
  public let id: Int
  public let count: Int?
  public let canExpandUp: Bool
  public let canExpandDown: Bool
}

public enum DiffContextRow: Identifiable, Sendable {
  case line(DiffLine)
  case gap(DiffContextGap)

  public var id: String {
    switch self {
    case .line(let line): "line-\(line.id)"
    case .gap(let gap): "gap-\(gap.id)"
    }
  }
}

/// Expands only unchanged regions of a complete patch, using the pinned head's text.
public struct DiffContext: Sendable {
  private struct Hunk: Sendable {
    let oldStart: Int
    let newStart: Int
    let oldCount: Int
    let newCount: Int
    let lines: [DiffLine]
  }

  private let hunks: [Hunk]
  private var source: [String]?
  private var revealed: [Int: (before: Int, after: Int)] = [:]
  public var hasSource: Bool { source != nil }

  public init(diff: UnifiedDiff) throws {
    let regex = try NSRegularExpression(
      pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
    var groups: [[DiffLine]] = []
    for line in diff.lines {
      if line.kind == .hunk { groups.append([]) }
      guard !groups.isEmpty else {
        throw MergeportError.message("Cannot expand a diff without hunks.")
      }
      groups[groups.count - 1].append(line)
    }
    hunks = try groups.map { lines in
      let header = lines[0].text
      guard let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
        throw MergeportError.message("Cannot expand an invalid diff hunk.")
      }
      func number(_ group: Int, default fallback: Int) -> Int {
        guard let range = Range(match.range(at: group), in: header) else { return fallback }
        return Int(header[range]) ?? fallback
      }
      let oldCount = number(2, default: 1), newCount = number(4, default: 1)
      let old = number(1, default: 0), new = number(3, default: 0)
      guard lines.filter({ $0.oldLine != nil }).count == oldCount,
        lines.filter({ $0.newLine != nil }).count == newCount
      else { throw MergeportError.message("Cannot expand an incomplete diff hunk. Open GitHub for the full file.") }
      // Empty ranges name the line before the insertion/deletion, not the first line.
      return Hunk(
        oldStart: oldCount == 0 ? old + 1 : old,
        newStart: newCount == 0 ? new + 1 : new,
        oldCount: oldCount, newCount: newCount, lines: lines)
    }
    guard !hunks.isEmpty else { throw MergeportError.message("Cannot expand a diff without hunks.") }
    for index in 0..<hunks.count {
      let hunk = hunks[index]
      let oldEnd = index == 0 ? 1 : hunks[index - 1].oldStart + hunks[index - 1].oldCount
      let newEnd = index == 0 ? 1 : hunks[index - 1].newStart + hunks[index - 1].newCount
      guard hunk.oldStart >= oldEnd, hunk.newStart >= newEnd,
        hunk.oldStart - oldEnd == hunk.newStart - newEnd
      else { throw MergeportError.message("The diff has inconsistent context ranges. Open GitHub for the full file.") }
    }
  }

  public mutating func loadSource(_ text: String) throws {
    guard !text.contains("\0") else { throw MergeportError.message("Cannot expand binary file content.") }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    for hunk in hunks {
      guard hunk.newStart + hunk.newCount - 1 <= lines.count else {
        throw MergeportError.message("File content does not match this diff. Refresh the PR before expanding context.")
      }
      for row in hunk.lines {
        if let number = row.newLine {
          let expected = row.text.hasSuffix("\r") ? String(row.text.dropLast()) : row.text
          guard number > 0, number <= lines.count, lines[number - 1] == expected else {
            throw MergeportError.message("File content does not match this diff. Refresh the PR before expanding context.")
          }
        }
      }
    }
    source = lines
  }

  public mutating func expand(gap id: Int, direction: ContextDirection, batch: Int = 20) throws {
    guard source != nil, (0...hunks.count).contains(id), batch > 0 else {
      throw MergeportError.message("Load file content before expanding this context.")
    }
    let range = gapRange(id)
    let total = range.count ?? 0
    var value = revealed[id] ?? (0, 0)
    let remaining = max(0, total - value.before - value.after)
    switch direction {
    case .down: value.before += min(batch, remaining)
    case .up: value.after += min(batch, remaining)
    case .all: value.before += remaining
    }
    revealed[id] = value
  }

  private func gapRange(_ index: Int) -> (old: Int, new: Int, count: Int?) {
    let previous = index > 0 ? hunks[index - 1] : nil
    let old = previous.map { $0.oldStart + $0.oldCount } ?? 1
    let new = previous.map { $0.newStart + $0.newCount } ?? 1
    let count = index < hunks.count
      ? hunks[index].newStart - new
      : source.map { max(0, $0.count + 1 - new) }
    return (old, new, count)
  }

  public var rows: [DiffContextRow] {
    var result: [DiffContextRow] = []
    for index in 0...hunks.count {
      let range = gapRange(index)
      let shown = revealed[index] ?? (0, 0)
      func appendContext(_ offsets: Range<Int>) {
        guard let source else { return }
        for offset in offsets {
          let number = range.new + offset
          result.append(.line(DiffLine(
            id: -number, kind: .context, text: source[number - 1],
            oldLine: range.old + offset, newLine: number, isCommentable: false)))
        }
      }
      appendContext(0..<shown.before)
      let remaining = range.count.map { $0 - shown.before - shown.after }
      if remaining.map({ $0 > 0 }) ?? true {
        result.append(.gap(DiffContextGap(
          id: index, count: remaining, canExpandUp: index < hunks.count,
          canExpandDown: index > 0)))
      }
      if let count = range.count { appendContext((count - shown.after)..<count) }
      if index < hunks.count { result += hunks[index].lines.map(DiffContextRow.line) }
    }
    return result
  }
}
