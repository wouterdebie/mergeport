import Testing

@testable import MergeportCore

struct QuickSearchTests {
    @Test func exactNumberAndTicketBeatTitleMatches() throws {
        let byNumber = try #require(QuickSearch.score("440", identifiers: ["440", "#440"], title: "Routing", details: []))
        let inTitle = try #require(QuickSearch.score("440", identifiers: ["12"], title: "Fix 440 errors", details: []))
        #expect(byNumber > inTitle)
        #expect(QuickSearch.score("#440", identifiers: ["440", "#440"], title: "x", details: []) != nil)
        let ticket = try #require(QuickSearch.score("con-108", identifiers: ["CON-108"], title: "Email", details: []))
        #expect(ticket >= 1000)
    }

    @Test func everyWordMustMatchSomewhere() {
        #expect(QuickSearch.score("email platform", identifiers: [], title: "Move email delivery", details: ["acme/platform"]) != nil)
        #expect(QuickSearch.score("email terraform", identifiers: [], title: "Move email delivery", details: ["acme/platform"]) == nil)
    }

    @Test func titlePrefixAndWordStartsRankHigher() throws {
        let prefix = try #require(QuickSearch.score("move", identifiers: [], title: "Move email", details: []))
        let word = try #require(QuickSearch.score("email", identifiers: [], title: "Move email", details: []))
        let inside = try #require(QuickSearch.score("mail", identifiers: [], title: "Move email", details: []))
        let detail = try #require(QuickSearch.score("acme", identifiers: [], title: "Move email", details: ["acme/app"]))
        #expect(prefix > word && word > inside && inside > detail)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(QuickSearch.score("  ", identifiers: [], title: "x", details: []) == 0)
    }
}
