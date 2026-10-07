import Foundation
@testable import MergeportCore
import Testing

struct WorkflowTests {
    @Test(arguments: [1, 1000, 5459, 1234567])
    func prIdentifiersNeverUseLocaleDigitGrouping(_ number: Int) {
        var value = pr()
        value.number = number
        #expect(value.displayNumber == "#" + String(number))
        #expect(!value.displayNumber.contains(","))
        #expect(!value.displayNumber.contains(" "))
    }

    private func pr() -> PullRequest {
        PullRequest(id: "1", number: 1, title: "Feature", repository: "acme/app",
                    url: URL(string: "https://github.com/acme/app/pull/1")!,
                    author: "you", head: "feature/a", base: "main",
                    mergeable: "MERGEABLE", mergeState: "CLEAN", checks: .success)
    }

    @Test func displayTitleIncludesNumberRepositoryAndTitleInOrder() {
        var value = pr()
        value.number = 5459
        value.title = "CON-123 Fix sync"
        #expect(value.displayTitle == "#5459 acme/app CON-123 Fix sync")
    }

    @Test func draftHasPriorityOverPassingChecksAndApproval() {
        var value = pr()
        value.isDraft = true
        value.reviewDecision = "APPROVED"
        #expect(value.stage == .draft)
    }

    @Test func reviewRequestsStayInYourReviewQueueEvenWhenChecksFail() {
        var value = pr()
        value.reviewRequested = true
        value.checks = .failure
        #expect(value.stage == .review)
        #expect(InboxScope.review.includes(value, login: "you"))
    }

    @Test func approvedPRsLeaveYourReviewQueue() {
        var value = pr()
        value.reviewRequested = true
        value.reviewDecision = "APPROVED"
        #expect(value.stage != .review)
        #expect(!InboxScope.review.includes(value, login: "you"))
    }

    @Test(arguments: ["BLOCKED", "BEHIND", "UNKNOWN", "UNSTABLE", "HAS_HOOKS", "NEW_FUTURE_STATE"])
    func approvalDoesNotBypassGitHubMergePolicy(_ state: String) {
        var value = pr()
        value.reviewDecision = "APPROVED"
        value.mergeState = state
        #expect(value.stage != .ready)
    }

    @Test func readyRequiresKnownMergeabilityAndSuccessfulPolicy() {
        var value = pr()
        #expect(value.stage == .ready)
        value.checks = .none
        #expect(value.stage == .ready)
        value.checks = .unknown
        #expect(value.stage == .waiting)
        value.checks = .pending
        #expect(value.stage == .waiting)
        value.checks = .success
        value.mergeable = "UNKNOWN"
        #expect(value.stage == .waiting)
        value.mergeable = "MERGEABLE"
        value.reviewDecision = "REVIEW_REQUIRED"
        #expect(value.stage == .waiting)
        #expect(value.waitingReason == "Waiting for approval")
    }

    @Test(arguments: ["MERGED", "CLOSED"])
    func finishedPRsAreNeverMergeReady(_ state: String) {
        var value = pr()
        value.state = state
        #expect(value.stage != .ready)
    }

    @Test func attentionReflectsFeedbackChecksAndConflicts() {
        var value = pr()
        value.unresolvedThreads = 1
        #expect(value.stage == .attention)
        value.unresolvedThreads = 0
        value.reviewDecision = "CHANGES_REQUESTED"
        #expect(value.stage == .attention)
        value.reviewDecision = nil
        value.mergeable = "CONFLICTING"
        #expect(value.stage == .attention)
        value.mergeable = "MERGEABLE"
        value.checks = .failure
        #expect(value.stage == .attention)
    }

    @Test func siblingPRsRequireSameRepositoryAndSourceFork() {
        let main = pr()
        var staging = main
        staging.id = "2"
        staging.number = 2
        staging.base = "staging"
        #expect(main.isSibling(of: staging))
        #expect(!main.isSibling(of: main))
        staging.headRepository = "someone-else/app"
        #expect(!main.isSibling(of: staging))
        staging.headRepository = main.headRepository
        staging.repository = "acme/other"
        #expect(!main.isSibling(of: staging))
    }

    @Test func mineMatchesCaseInsensitively() {
        #expect(pr().isMine("YOU"))
        #expect(!InboxScope.mine.includes(pr(), login: "alex"))
    }

    @Test(arguments: ["", "acme", "/app", "acme/", "acme/app/extra", "acme/app?x=y", "acme/..", "acme/app name"])
    func invalidRepositoryNamesAreRejected(_ input: String) {
        #expect(throws: (any Error).self) { try RepositoryName.validate(input) }
    }

    @Test func repositoryNamesTrimWhitespace() throws {
        #expect(try RepositoryName.validate("  acme/my-app.v2\n") == "acme/my-app.v2")
    }

    @Test func browserLocationsMustBeRealGitHubPRPages() {
        let value = pr()
        #expect(GitHubNavigation.belongsTo(URL(string: "https://github.com/acme/app/pull/1/files#diff")!, pr: value))
        for url in ["http://github.com/acme/app/pull/1", "https://github.com.evil.test/acme/app/pull/1",
                    "https://github.com:444/acme/app/pull/1", "https://github.com/acme/app/pull/11",
                    "https://github.com/login", "https://user@github.com/acme/app/pull/1"] {
            #expect(!GitHubNavigation.belongsTo(URL(string: url)!, pr: value))
        }
    }

    @Test func snapshotRoundTripsAndDemoCoversWorkflow() throws {
        let snapshot = DemoInbox.snapshot
        let copy = try JSONDecoder().decode(InboxSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(copy.pullRequests == snapshot.pullRequests)
        #expect(Set(copy.pullRequests.map(\.stage)) == Set(WorkflowStage.allCases))
        #expect(copy.pullRequests.contains { value in copy.pullRequests.contains { value.isSibling(of: $0) } })
    }

    @Test func copilotActorsAreSpecificNotSubstringMatches() {
        #expect(CopilotState.isCopilot("copilot-pull-request-reviewer[bot]"))
        #expect(!CopilotState.isCopilot("my-copilot-helper"))
    }
}
