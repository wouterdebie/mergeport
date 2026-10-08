import Testing
@testable import MergeportCore

struct DiffContextTests {
  private func lines(_ context: DiffContext) -> [DiffLine] {
    context.rows.compactMap { if case .line(let line) = $0 { line } else { nil } }
  }

  private func gaps(_ context: DiffContext) -> [DiffContextGap] {
    context.rows.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }
  }

  @Test func expandsAboveBelowAndBetweenWithoutDuplicatesOrChangingAnchors() throws {
    let source = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let diff = try UnifiedDiff.parse(
      "@@ -31,1 +31,1 @@\n-old\n+line 31\n@@ -72,1 +72,1 @@\n-old\n+line 72")
    var context = try DiffContext(diff: diff)
    #expect(gaps(context).map(\.count) == [30, 40, nil])
    #expect(gaps(context).first?.canExpandDown == false)
    #expect(gaps(context).last?.canExpandUp == false)
    try context.loadSource(source)
    try context.expand(gap: 0, direction: .up)
    #expect(lines(context).filter { !$0.isCommentable }.map(\.newLine) == Array(11...30))
    try context.expand(gap: 1, direction: .down)
    try context.expand(gap: 1, direction: .up)
    #expect(!gaps(context).contains { $0.id == 1 })
    try context.expand(gap: 0, direction: .up)
    try context.expand(gap: 2, direction: .down)
    #expect(gaps(context).map(\.count) == [8])
    try context.expand(gap: 2, direction: .down)
    #expect(gaps(context).isEmpty)
    let right = lines(context).compactMap(\.newLine)
    #expect(right == Array(1...100))
    #expect(Set(context.rows.map(\.id)).count == context.rows.count)
    #expect(lines(context).filter { $0.kind == .addition }.map { $0.anchor(path: "f") } ==
      diff.lines.filter { $0.kind == .addition }.map { $0.anchor(path: "f") })
    #expect(lines(context).filter { !$0.isCommentable }.allSatisfy { $0.anchor(path: "f") == nil })
  }

  @Test func insertionAndDeletionOnlyHunksKeepBothNumberColumnsCorrect() throws {
    let diff = try UnifiedDiff.parse(
      "@@ -2,0 +3,1 @@\n+inserted\n@@ -5,1 +5,0 @@\n-deleted")
    var context = try DiffContext(diff: diff)
    try context.loadSource("one\ntwo\ninserted\nthree\nfour\nsix\n")
    for id in [0, 1, 2] { try context.expand(gap: id, direction: .all) }
    let unchanged = lines(context).filter { !$0.isCommentable }
    #expect(unchanged.map(\.text) == ["one", "two", "three", "four", "six"])
    #expect(unchanged.map(\.oldLine) == [1, 2, 3, 4, 6])
    #expect(unchanged.map(\.newLine) == [1, 2, 4, 5, 6])
  }

  @Test func emptyAndEndOfFileRangesDoNotInventBlankLines() throws {
    var empty = try DiffContext(diff: UnifiedDiff.parse("@@ -1,1 +0,0 @@\n-last"))
    try empty.loadSource("")
    #expect(gaps(empty).isEmpty)
    var context = try DiffContext(diff: UnifiedDiff.parse("@@ -1 +1 @@\n-old\n+new"))
    try context.loadSource("new\n")
    #expect(gaps(context).isEmpty)
    try context.expand(gap: 1, direction: .down)
    #expect(lines(context).count == 3)
  }

  @Test func validatesContentAndHunkCompleteness() throws {
    #expect(throws: MergeportError.self) {
      try DiffContext(diff: UnifiedDiff.parse("@@ -1,2 +1,2 @@\n-old\n+new"))
    }
    #expect(throws: MergeportError.self) {
      try DiffContext(diff: UnifiedDiff.parse("@@ -5 +6 @@\n-old\n+new"))
    }
    var context = try DiffContext(diff: UnifiedDiff.parse("@@ -1 +1 @@\n-old\n+new"))
    #expect(throws: MergeportError.self) { try context.loadSource("different") }
    #expect(throws: MergeportError.self) { try context.loadSource("new\0") }
    #expect(throws: MergeportError.self) { try context.expand(gap: 1, direction: .down) }
    try context.loadSource("new\r\n\r\nlast")
    try context.expand(gap: 1, direction: .all)
    #expect(lines(context).suffix(2).map(\.text) == ["", "last"])
  }

  @Test func expandAllMergesPartiallyExpandedGapAndPreservesNoNewlineNote() throws {
    let source = (1...70).map { "line \($0)" }.joined(separator: "\n")
    var context = try DiffContext(diff: UnifiedDiff.parse(
      "@@ -1 +1 @@\n-old\n+line 1\n@@ -70 +70 @@\n-old\n+line 70\n\\ No newline at end of file"))
    try context.loadSource(source)
    try context.expand(gap: 1, direction: .down)
    #expect(gaps(context).first?.count == 48)
    try context.expand(gap: 1, direction: .all)
    #expect(gaps(context).isEmpty)
    #expect(lines(context).compactMap(\.newLine) == Array(1...70))
    #expect(lines(context).last?.kind == .note)
  }
}
