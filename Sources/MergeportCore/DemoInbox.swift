import Foundation

public enum DemoInbox {
    public static var snapshot: InboxSnapshot {
        let repo = "acme/platform"
        func pr(_ number: Int, _ title: String, _ head: String, _ base: String, author: String = "you",
                draft: Bool = false, requested: Bool = false, decision: String? = nil,
                state: String = "BLOCKED", checks: CheckState = .success,
                threads: Int = 0, copilotThreads: Int = 0, copilot: CopilotState = .reviewed) -> PullRequest {
            PullRequest(
                id: "demo-\(number)", number: number, title: title, repository: repo,
                url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                author: author, head: head, base: base,
                updatedAt: .now.addingTimeInterval(Double(-number * 20)),
                isDraft: draft, reviewRequested: requested, reviewDecision: decision,
                mergeable: "MERGEABLE", mergeState: state, checks: checks,
                unresolvedThreads: threads + copilotThreads, unresolvedCopilotThreads: copilotThreads, copilot: copilot, additions: 128, deletions: 34
            )
        }
        var prs = [
            pr(451, "Move email delivery into the Rust service (CON-108)", "feature/email-delivery", "staging",
               draft: true, checks: .pending, copilot: .requested),
            pr(452, "Move email delivery into the Rust service (CON-108)", "feature/email-delivery", "main",
               draft: true, checks: .pending, copilot: .requested),
            pr(446, "Add streaming Pub/Sub consumers (CON-171)", "feature/pubsub", "main", decision: "REVIEW_REQUIRED",
               checks: .pending),
            pr(445, "Add streaming Pub/Sub consumers (CON-171)", "feature/pubsub-staging", "staging", state: "CLEAN"),
            pr(443, "Keep deployment history across rollbacks (CON-200)", "fix/deploy-history", "main",
               decision: "CHANGES_REQUESTED", threads: 3),
            pr(440, "Simplify the tenant routing layer (CON-205)", "feature/routing", "main",
               author: "alex", requested: true, decision: "REVIEW_REQUIRED"),
            pr(438, "Use workload identity for scheduled jobs (CON-215)", "infra/workload-identity", "main",
               decision: "APPROVED", state: "CLEAN", copilotThreads: 2)
        ]
        // A GitHub stack: #455 (bottom) ← #456 (sam's, not in your inbox) ← #457 (top).
        let stackRepo = URL(string: "https://github.com/\(repo)/pull/")!
        let stackEntries = [
            PRStack.Entry(id: "demo-455", position: 1, number: 455, title: "Add the tenants table and migrations (CON-230)",
                          url: stackRepo.appendingPathComponent("455"), head: "stack/tenants-schema", base: "main",
                          author: "you", reviewDecision: "APPROVED", mergeState: "CLEAN"),
            PRStack.Entry(id: "demo-456", position: 2, number: 456, title: "Tenant CRUD API (CON-230)",
                          url: stackRepo.appendingPathComponent("456"), head: "stack/tenants-api", base: "stack/tenants-schema",
                          author: "sam", reviewDecision: "REVIEW_REQUIRED", mergeState: "BLOCKED"),
            PRStack.Entry(id: "demo-457", position: 3, number: 457, title: "Tenant admin screens (CON-230)",
                          url: stackRepo.appendingPathComponent("457"), head: "stack/tenants-ui", base: "stack/tenants-api",
                          author: "you", reviewDecision: "APPROVED", mergeState: "CLEAN"),
        ]
        for (number, position) in [(455, 1), (457, 3)] {
            let entry = stackEntries[position - 1]
            var member = pr(number, entry.title, entry.head, entry.base, decision: "APPROVED", state: "CLEAN")
            member.stack = PRStack(number: 7, base: "main", size: 3, position: position, entries: stackEntries)
            prs.append(member)
        }
        var second = pr(87, "Expose structured audit events (CON-205)", "feature/audit", "main",
                        author: "sam", requested: true, decision: "REVIEW_REQUIRED")
        second.repository = "acme/terraform"
        second.headRepository = second.repository
        second.url = URL(string: "https://github.com/acme/terraform/pull/87")!
        prs.append(second)
        return InboxSnapshot(viewer: Viewer(login: "you"), pullRequests: prs)
    }
}
