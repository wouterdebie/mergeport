import Foundation
import Testing

@testable import MergeportCore

struct StatusPanelTests {
  private func pr(
    author: String = "you", requested: Bool = false, decision: String? = "REVIEW_REQUIRED",
    mergeable: String = "MERGEABLE", mergeState: String = "BLOCKED", checks: CheckState = .success,
    threads: Int = 0, copilot: CopilotState = .notRequested, draft: Bool = false
  ) -> PullRequest {
    PullRequest(
      id: "PR_1", number: 1, title: "Search", repository: "acme/app",
      url: URL(string: "https://github.com/acme/app/pull/1")!, author: author, head: "feature",
      base: "main", isDraft: draft, reviewRequested: requested, reviewDecision: decision,
      mergeable: mergeable, mergeState: mergeState, checks: checks, unresolvedThreads: threads,
      copilot: copilot)
  }

  @Test func meaningfulTransitionsOnYourPRsAreReported() {
    let base = pr()
    #expect(StatusPanel.change(from: base, to: base, login: "you") == nil)
    #expect(
      StatusPanel.change(from: base, to: pr(decision: "APPROVED"), login: "you") == "Approved")
    #expect(
      StatusPanel.change(from: base, to: pr(decision: "CHANGES_REQUESTED"), login: "you")
        == "Changes requested")
    #expect(StatusPanel.change(from: base, to: pr(checks: .failure), login: "you") == "Checks failed")
    #expect(
      StatusPanel.change(from: base, to: pr(mergeable: "CONFLICTING"), login: "you")
        == "Merge conflicts")
    #expect(
      StatusPanel.change(
        from: pr(decision: "APPROVED"), to: pr(decision: "APPROVED", mergeState: "CLEAN"),
        login: "you") == "Ready to merge")
    #expect(
      StatusPanel.change(
        from: pr(copilot: .requested, draft: true), to: pr(copilot: .reviewed, draft: true),
        login: "you") == "Copilot finished reviewing")
    #expect(StatusPanel.change(from: base, to: pr(threads: 2), login: "you") == "2 new review threads")
    #expect(StatusPanel.change(from: pr(threads: 2), to: pr(threads: 1), login: "you") == nil)
  }

  @Test func reviewRequestsCountButOthersPRsAreIgnored() {
    let theirs = pr(author: "sam")
    #expect(StatusPanel.change(from: nil, to: pr(author: "sam", requested: true), login: "you")
      == "Review requested")
    #expect(StatusPanel.change(from: nil, to: theirs, login: "you") == nil)
    #expect(
      StatusPanel.change(from: theirs, to: pr(author: "sam", requested: true), login: "you")
        == "Review requested")
    #expect(StatusPanel.change(from: theirs, to: pr(author: "sam", checks: .failure), login: "you") == nil)
  }

  @Test func needsYouCoversRequestsAndYourActionablePRs() {
    #expect(StatusPanel.needsYou(pr(author: "sam", requested: true), login: "you"))
    #expect(!StatusPanel.needsYou(pr(author: "sam", requested: true, decision: "APPROVED"), login: "you"))
    #expect(StatusPanel.needsYou(pr(checks: .failure), login: "you"))
    #expect(StatusPanel.needsYou(pr(decision: "APPROVED", mergeState: "CLEAN"), login: "you"))
    #expect(!StatusPanel.needsYou(pr(), login: "you"))
    #expect(!StatusPanel.needsYou(pr(author: "sam", checks: .failure), login: "you"))
  }

  @Test func filtersAndAges() {
    let theirs = pr(author: "sam")
    #expect(!PanelFilter.involved.includes(theirs, login: "you"))
    #expect(PanelFilter.involved.includes(pr(author: "sam", requested: true), login: "you"))
    #expect(PanelFilter.all.includes(theirs, login: "you"))
    let now = Date()
    #expect(StatusPanel.age(now.addingTimeInterval(-30), now: now) == "now")
    #expect(StatusPanel.age(now.addingTimeInterval(-600), now: now) == "10m")
    #expect(StatusPanel.age(now.addingTimeInterval(-7200), now: now) == "2h")
    #expect(StatusPanel.age(now.addingTimeInterval(-86400 * 3), now: now) == "3d")
  }
}
