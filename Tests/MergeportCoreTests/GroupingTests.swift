import Foundation
@testable import MergeportCore
import Testing

struct GroupingTests {
    private func pr(_ number: Int, head: String, title: String = "Change", repo: String = "acme/app", fork: String? = nil) -> PullRequest {
        PullRequest(id: "\(repo)#\(number)", number: number, title: title, repository: repo,
                    url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, author: "you", head: head,
                    headRepository: fork ?? repo, base: number == 1 ? "main" : "staging")
    }

    @Test func reusableBranchRulesGroupFutureBranchesWithoutCreatingAliases() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .branchGroups
        let first = [pr(1, head: "feature/CON-12"), pr(2, head: "feature/CON-12-staging"), pr(3, head: "feature/CON-12-test")]
        #expect(try preferences.groups(for: first).count == 1)
        #expect(try preferences.groups(for: first).first?.title == "feature/CON-12")
        let later = [pr(4, head: "entirely-new"), pr(5, head: "entirely-new-staging"), pr(6, head: "entirely-new-test")]
        #expect(try preferences.groups(for: later).count == 1)
        #expect(preferences.aliases.isEmpty)
        preferences.mode = .branch
        #expect(try preferences.groups(for: first).count == 3)
    }

    @Test func suffixRulesAreScopedAndRespectCaseAndLongestMatch() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .branchGroups
        preferences.branchSuffixes = try GroupingPreferences.suffixes(from: "test, -staging, -integration-test")
        #expect(preferences.normalizedBranch("feature/a-integration-test") == "feature/a")
        #expect(preferences.normalizedBranch("feature/a-staging-test") == "feature/a")
        #expect(preferences.normalizedBranch("feature/a-TEST") == "feature/a-TEST")
        let groups = try preferences.groups(for: [
            pr(1, head: "a"), pr(2, head: "a-test"),
            pr(3, head: "a-test", repo: "acme/other"), pr(4, head: "a-test", fork: "alex/app")
        ])
        #expect(groups.count == 3)
        preferences.branchSuffixes = []
        #expect(preferences.normalizedBranch("a-test") == "a-test")
    }

    @Test func oldSettingsMigrateAndReusableRulesPersist() throws {
        let old = Data(#"{"mode":"branch","ticketPrefixes":["CON-"],"aliases":[]}"#.utf8)
        var preferences = try JSONDecoder().decode(GroupingPreferences.self, from: old)
        #expect(preferences.mode == .branch)
        #expect(preferences.branchSuffixes == ["-staging", "-test"])
        preferences.mode = .branchGroups
        let restored = try JSONDecoder().decode(GroupingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored == preferences)
        try restored.validate()
    }

    @Test func exactSourceBranchesGroupMainAndStagingButNotUnrelatedReposOrForks() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .branch
        let prs = [pr(1, head: "feature/a"), pr(2, head: "feature/a"),
                   pr(3, head: "feature/a", repo: "acme/other"), pr(4, head: "feature/a", fork: "alex/app")]
        let groups = try preferences.groups(for: prs)
        #expect(groups.count == 3)
        #expect(groups.first { $0.pullRequests.count == 2 }?.pullRequests.map(\.base).sorted() == ["main", "staging"])
    }

    @Test func conflictBranchesNeedAnExplicitAliasAndAliasesAlsoFindSiblings() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .branch
        let main = pr(1, head: "feature/a")
        let staging = pr(2, head: "feature/a-staging")
        #expect(try preferences.groups(for: [main, staging]).count == 2)
        try preferences.addAlias(source: BranchIdentity(staging), target: main.head)
        #expect(try preferences.groups(for: [main, staging]).count == 1)
        #expect(try preferences.sameBranchFamily(main, staging))
        #expect(!(try preferences.sameBranchFamily(main, pr(3, head: staging.head, fork: "alex/app"))))
        let restored = try JSONDecoder().decode(GroupingPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(try restored.canonicalBranch(BranchIdentity(staging)) == main.head)
    }

    @Test func aliasChainsNormalizeAndCyclesAreRejectedWithoutChangingSettings() throws {
        var preferences = GroupingPreferences()
        let source = BranchIdentity(pr(1, head: "c"))
        try preferences.addAlias(source: source, target: "b")
        try preferences.addAlias(source: source.withBranch("b"), target: "a")
        #expect(try preferences.canonicalBranch(source) == "a")
        let original = preferences
        #expect(throws: MergeportError.self) { try preferences.addAlias(source: source.withBranch("a"), target: "c") }
        #expect(preferences == original)
        #expect(throws: MergeportError.self) { try preferences.addAlias(source: source, target: "c") }
    }

    @Test func ticketIDsPreferBranchThenTitleAndGroupAcrossRepos() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .ticket
        preferences.ticketPrefixes = try GroupingPreferences.prefixes(from: "con, ENG-, con-")
        #expect(preferences.ticketPrefixes == ["CON-", "ENG-"])
        let first = pr(1, head: "feature/con-123-change", title: "Fix ENG-456 too")
        let second = pr(2, head: "fix/other", title: "Complete CON-123", repo: "acme/other")
        #expect(try preferences.ticketIdentifier(for: first) == "CON-123")
        #expect(try preferences.groups(for: [first, second]).count == 1)
        #expect(try preferences.ticketIdentifier(for: pr(3, head: "feature/no-id", title: "ENG-456: fix")) == "ENG-456")
    }

    @Test(arguments: ["feature/FOOCON-12", "feature/CON-12abc", "feature/CON-", "feature/CON-text"])
    func ticketBoundariesDoNotMatchPartialIdentifiers(_ head: String) throws {
        #expect(try GroupingPreferences().ticketIdentifier(for: pr(1, head: head)) == nil)
    }

    @Test func aliasedBranchCanInheritCanonicalTicketAndUnmatchedPRsRemainVisible() throws {
        var preferences = GroupingPreferences()
        preferences.mode = .ticket
        let staging = pr(1, head: "conflict-workaround")
        try preferences.addAlias(source: BranchIdentity(staging), target: "feature/CON-88-change")
        #expect(try preferences.ticketIdentifier(for: staging) == "CON-88")
        let groups = try preferences.groups(for: [staging, pr(2, head: "no-ticket")])
        #expect(groups.count == 2)
        #expect(groups.last?.isUnmatched == true)
        #expect(groups.flatMap(\.pullRequests).count == 2)
    }

    @Test(arguments: ["", " , ", "CON PROJECT-", "123-"])
    func invalidPrefixConfigurationIsRejected(_ input: String) {
        #expect(throws: MergeportError.self) { try GroupingPreferences.prefixes(from: input) }
    }
}
