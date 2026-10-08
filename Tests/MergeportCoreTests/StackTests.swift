import Foundation
import Testing

@testable import MergeportCore

struct StackTests {
  private func entry(
    _ position: Int, state: String = "OPEN", draft: Bool = false, decision: String? = "APPROVED",
    merge: String = "CLEAN", checks: CheckState = .success, requests: Int = 1
  ) -> PRStack.Entry {
    PRStack.Entry(
      id: "e\(position)", position: position, number: 10 + position, title: "Layer \(position)",
      url: URL(string: "https://github.com/acme/app/pull/\(10 + position)")!, state: state,
      isDraft: draft, head: "layer-\(position)", base: position == 1 ? "main" : "layer-\(position - 1)",
      author: "you", reviewDecision: decision, mergeState: merge, checks: checks,
      reviewRequests: requests)
  }

  private func pr(_ stack: PRStack?) -> PullRequest {
    PullRequest(
      id: "1", number: 13, title: "Top", repository: "acme/app",
      url: URL(string: "https://github.com/acme/app/pull/13")!, author: "you", head: "layer-3",
      base: "layer-2", reviewDecision: "APPROVED", mergeable: "MERGEABLE", mergeState: "CLEAN",
      checks: .success, stack: stack)
  }

  @Test func entriesAreSortedBottomFirstAndMergeIncludesOpenPRsBelow() {
    let stack = PRStack(
      number: 4, base: "main", size: 3, position: 3,
      entries: [entry(3), entry(1, state: "MERGED"), entry(2)])
    #expect(stack.entries.map(\.position) == [1, 2, 3])
    #expect(stack.openBelow.map(\.number) == [12])
    #expect(stack.mergedTogether(with: 13) == [12, 13])
    #expect(stack.positionLabel == "3/3")
    #expect(stack.blocker == nil)
  }

  @Test func lowestUnreadyPRBelowBlocksTheStack() {
    let stack = PRStack(
      number: 4, base: "main", size: 3, position: 3,
      entries: [entry(1, draft: true), entry(2, decision: "REVIEW_REQUIRED"), entry(3)])
    #expect(stack.blocker?.number == 11)
    #expect(pr(stack).stage == .waiting)
    #expect(pr(stack).waitingReason.contains("#11"))
    #expect(pr(nil).stage != .waiting)
    #expect(stack.readinessLabel == "1 of 3 ready")
  }

  @Test func unrequestedLayerAnywhereInTheStackNeedsAttention() {
    let stack = PRStack(
      number: 4, base: "main", size: 3, position: 1,
      entries: [entry(1), entry(2), entry(3, decision: "REVIEW_REQUIRED", requests: 0)])
    #expect(stack.needingReviewer.map(\.number) == [13])
    #expect(stack.blocker == nil)
    var bottom = pr(stack)
    bottom.number = 11
    // The bottom can still land on its own.
    #expect(bottom.stage == .ready)
    let top = pr(PRStack(
      number: 4, base: "main", size: 3, position: 3,
      entries: [entry(1), entry(2, decision: "REVIEW_REQUIRED", requests: 0), entry(3)]))
    #expect(top.stage == .attention)
    #expect(top.waitingReason == "#12 in the stack has no reviewer")
  }

  @Test func failingChecksAndRebaseBelowHoldUpTheStack() {
    let failing = PRStack(
      number: 4, base: "main", size: 2, position: 2,
      entries: [entry(1, merge: "BLOCKED", checks: .failure), entry(2)])
    #expect(failing.blocker?.problem == "Checks failing")
    let behind = PRStack(
      number: 4, base: "main", size: 2, position: 2, entries: [entry(1, merge: "BEHIND"), entry(2)])
    #expect(behind.needsRebase)
    #expect(behind.blocker?.statusLabel == "Needs rebase")
    let ready = PRStack(number: 4, base: "main", size: 2, position: 2, entries: [entry(1), entry(2)])
    #expect(ready.readinessLabel == "All 2 ready")
  }

  @Test func optionalChecksBelowDoNotBlockStackButRemainVisible() {
    let failing = entry(1, merge: "UNSTABLE", checks: .failure)
    #expect(!failing.holdsUpStack)
    #expect(failing.statusLabel == "Optional checks failing")
    let pending = entry(2, merge: "CLEAN", checks: .pending)
    #expect(!pending.holdsUpStack)
    #expect(pending.statusLabel == "Optional checks running")
    let stack = PRStack(
      number: 4, base: "main", size: 3, position: 3, entries: [failing, pending, entry(3)])
    #expect(stack.blocker == nil)
    #expect(pr(stack).isMergeReady)
    #expect(stack.readinessLabel == "All 3 ready")
    let required = entry(1, decision: "REVIEW_REQUIRED", merge: "UNSTABLE", checks: .failure)
    #expect(required.holdsUpStack)
  }

  @Test func decodesEntriesSavedBeforeReadinessFields() throws {
    let json = #"{"id":"e","position":1,"number":5,"title":"T","url":"https://github.com/a/b/pull/5","state":"OPEN","isDraft":false,"head":"h","base":"main","author":"you","reviewDecision":"REVIEW_REQUIRED","mergeState":"BLOCKED"}"#
    let entry = try JSONDecoder().decode(PRStack.Entry.self, from: Data(json.utf8))
    #expect(entry.checks == .unknown)
    #expect(entry.needsReviewer)
    let roundTrip = try JSONDecoder().decode(PRStack.Entry.self, from: JSONEncoder().encode(entry))
    #expect(roundTrip == entry)
  }

  @Test func listsNumbersInPlainEnglish() {
    #expect(PRStack.list([12]) == "#12")
    #expect(PRStack.list([12, 13]) == "#12 and #13")
    #expect(PRStack.list([1000, 1001, 1002]) == "#1000, #1001 and #1002")
  }

  @Test func asyncMergeResultMapsStatuses() throws {
    let decode = { (json: String) in
      try JSONDecoder().decode(AsyncMergeResult.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"status":"merged"}"#).outcome() == .merged)
    #expect(try decode(#"{"status":"enqueued"}"#).outcome() == .enqueued)
    #expect(throws: MergeportError.self) {
      try decode(#"{"status":"failed","details":{"message":"Required checks"}}"#).outcome()
    }
  }

  @Test func stackGroupingOrdersLayersAndKeepsUnstackedPRs() throws {
    let stack = { (position: Int) in
      PRStack(number: 4, base: "main", size: 3, position: position, entries: [entry(1), entry(2), entry(3)])
    }
    var top = pr(stack(3))
    top.id = "top"
    var bottom = pr(stack(1))
    bottom.id = "bottom"
    bottom.number = 11
    var loose = pr(nil)
    loose.id = "loose"
    loose.number = 99
    var preferences = GroupingPreferences()
    preferences.mode = .stack
    let groups = try preferences.groups(for: [top, loose, bottom])
    let stackGroup = try #require(groups.first { $0.title == "Stack #4" })
    #expect(stackGroup.pullRequests.map(\.number) == [11, 13])
    #expect(groups.flatMap(\.pullRequests).count == 3)
  }
}
