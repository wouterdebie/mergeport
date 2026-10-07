import Foundation
@testable import MergeportCore
import Testing

struct ReviewTests {
    private func fragments(_ text: String, _ ranges: [Range<Int>]) -> [String] {
        let characters = Array(text)
        return ranges.map { String(characters[$0]) }
    }

    @Test func intralineHighlightsOnlyChangedCharactersInSeparatedRegions() {
        let old = "call(111, \"aaa\")", new = "call(222, \"bbb\")"
        let changes = IntralineChange.between(old: old, new: new)
        #expect(fragments(old, changes.removed) == ["111", "aaa"])
        #expect(fragments(new, changes.added) == ["222", "bbb"])
        #expect(!changes.isCoarse)
    }

    @Test func intralineOffsetsUseGraphemesAndDoNotAlterCommentAnchors() throws {
        let old = "emoji: 👨‍👩‍👧‍👦", new = "emoji: 👩‍🚀"
        let changes = IntralineChange.between(old: old, new: new)
        #expect(fragments(old, changes.removed) == ["👨‍👩‍👧‍👦"])
        #expect(fragments(new, changes.added) == ["👩‍🚀"])
        let diff = try UnifiedDiff.parse("@@ -10 +20 @@\n-\(old)\n+\(new)")
        let added = try #require(diff.lines.first { $0.kind == .addition })
        #expect(!added.highlights.isEmpty)
        #expect(added.anchor(path: "a") == DiffAnchor(path: "a", line: 20, side: .right))
    }

    @Test func onlyReplacementsHaveIntralineSpansAndLongLinesAreBounded() throws {
        let diff = try UnifiedDiff.parse("@@ -0,0 +1 @@\n+an entirely new line")
        #expect(diff.lines.allSatisfy { $0.highlights.isEmpty })
        let old = String(repeating: "a", count: 5000), new = String(repeating: "b", count: 5000)
        let changes = IntralineChange.between(old: old, new: new)
        #expect(changes.isCoarse)
        #expect(changes.removed == [0..<5000])
        #expect(changes.added == [0..<5000])
    }

    @Test func diffAnchorsUseTheCorrectOldAndNewLineNumbers() throws {
        let diff = try UnifiedDiff.parse("@@ -10,3 +20,3 @@\n context\n-old\n+new\n tail\n\\ No newline at end of file")
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
        let removed = try #require(diff.lines.first { $0.kind == .deletion })
        let added = try #require(diff.lines.first { $0.kind == .addition })
        #expect(removed.anchor(path: "a.swift") == DiffAnchor(path: "a.swift", line: 11, side: .left))
        #expect(added.anchor(path: "a.swift") == DiffAnchor(path: "a.swift", line: 21, side: .right))
        #expect(diff.lines.first?.anchor(path: "a.swift") == nil)
        #expect(diff.lines.last?.anchor(path: "a.swift") == nil)
    }

    @Test func newFilesAndMultipleHunksResetLineCounters() throws {
        let diff = try UnifiedDiff.parse("@@ -0,0 +1,2 @@\n+one\n+two\n@@ -100 +200 @@\n-old\n+new")
        #expect(diff.lines.filter { $0.kind == .addition }.map(\.newLine) == [1, 2, 200])
        #expect(diff.lines.first { $0.kind == .deletion }?.oldLine == 100)
    }

    @Test(arguments: ["@@ broken @@\n+text", "+text", "@@ -1 +1 @@\nnot a diff line"])
    func malformedDiffsFailExplicitly(_ patch: String) {
        #expect(throws: (any Error).self) { try UnifiedDiff.parse(patch) }
    }

    @Test func reviewDraftsKeepDiscussionsAndRepliesSeparateFromReviewSubmission() throws {
        var draft = ReviewDraft()
        draft.headSHA = "head"
        draft.discussion = "An unsent discussion"
        draft.replies["thread"] = "An unsent reply"
        #expect(draft.hasContent)
        #expect(!draft.hasReviewContent)
        #expect(throws: MergeportError.self) { try draft.validate(currentHead: "head") }
        draft.event = .approve
        try draft.validate(currentHead: "head")
        #expect(throws: MergeportError.self) { try draft.validate(currentHead: "changed") }
        let restored = try JSONDecoder().decode(ReviewDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored.replies["thread"] == "An unsent reply")
        #expect(restored.discussion == draft.discussion)
        #expect(restored.headSHA == "head")
    }

    @Test func emptyAndInvalidInlineCommentsCannotBeSubmitted() {
        var draft = ReviewDraft()
        draft.headSHA = "head"
        draft.comments = [DraftComment(anchor: DiffAnchor(path: "a", line: 0, side: .right), body: "comment")]
        #expect(throws: MergeportError.self) { try draft.validate(currentHead: "head") }
        draft.comments = [DraftComment(anchor: DiffAnchor(path: "a", line: 1, side: .right), body: " \n")]
        #expect(throws: MergeportError.self) { try draft.validate(currentHead: "head") }
    }

    @Test func requestChangesNeedsAnExplanationAndDemoDiffsAreComplete() throws {
        var draft = ReviewDraft()
        draft.headSHA = "head"; draft.event = .requestChanges
        #expect(throws: MergeportError.self) { try draft.validate(currentHead: "head") }
        draft.body = "Please add coverage"
        try draft.validate(currentHead: "head")
        let details = DemoReview.details(for: DemoInbox.snapshot.pullRequests[0])
        for file in details.files {
            let diff = try UnifiedDiff.parse(try #require(file.patch))
            #expect(diff.additions == file.additions)
            #expect(diff.deletions == file.deletions)
        }
    }

    @Test func copilotFindingsAreReadFromTheReviewSummary() {
        let body = """
            <details open><summary><strong>2 open findings</strong></summary>

            - <picture><img src="low.png" alt="Low severity" width="62"></picture> [Use US spelling: labeled](#discussion_r4208968122) · New
            - [Unrated finding](#discussion_r7) · New
            </details>
            See [the docs](https://docs.github.com).
            """
        let findings = ReviewFinding.parse(body)
        #expect(findings.count == 2)
        #expect(findings[4208968122] == ReviewFinding(title: "Use US spelling: labeled", severity: "Low"))
        #expect(findings[7] == ReviewFinding(title: "Unrated finding", severity: nil))
    }

    @Test func threadSnippetShowsTheCommentedRangeOrTheLastFourLines() {
        let hunk = "@@ -1,2 +1,6 @@\n a\n-b\n+c\n+d\n+e\n+f"
        var thread = ReviewThread(
            id: "t", path: "f", line: 5, isResolved: false, isOutdated: false, canReply: true,
            canResolve: true, canUnresolve: false, comments: [], diffHunk: hunk)
        #expect(thread.snippet.map(\.text) == ["c", "d", "e", "f"])
        thread.startLine = 5
        #expect(thread.snippet.map(\.text) == ["c", "d", "e", "f"])
        thread.startLine = 4
        #expect(thread.snippet.map(\.text) == ["e", "f"])
        thread.diffHunk = nil
        #expect(thread.snippet.isEmpty)
    }

    @Test func reviewThreadsNestUnderTheirReviewInTheConversation() throws {
        let details = DemoReview.details(for: DemoInbox.snapshot.pullRequests[0])
        let review = try #require(details.reviews.first)
        #expect(details.threads(in: review).map(\.id) == ["sample-thread"])
        #expect(!details.conversation.contains { if case .thread = $0 { true } else { false } })
        #expect(details.findings[101]?.severity == "Low")
    }
}
