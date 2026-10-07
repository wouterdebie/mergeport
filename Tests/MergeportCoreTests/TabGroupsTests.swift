import Foundation
@testable import MergeportCore
import Testing

struct TabGroupsTests {
  /// Items related when they share the first character ("a1" ~ "a2").
  private let related: (String, String) -> Bool = { $0 != $1 && $0.first == $1.first }

  @Test func newTabsJoinTheEndOfTheirGroup() {
    let tabs = ["a1", "b1", "a2", "c1"]
    #expect(TabGroups.insertionIndex(for: "b2", in: tabs, related: related) == 2)
    #expect(TabGroups.insertionIndex(for: "c2", in: tabs, related: related) == 4)
    #expect(TabGroups.insertionIndex(for: "d1", in: tabs, related: related) == 4)
    #expect(TabGroups.insertionIndex(for: "a3", in: ["a1", "a2", "b1"], related: related) == 2)
  }

  @Test func clusteringIsStableAndTransitive() {
    #expect(TabGroups.clustered(["a1", "b1", "a2", "c1", "b2"], related: related)
      == ["a1", "a2", "b1", "b2", "c1"])
    // a ~ b, b ~ c, but a !~ c: still one group.
    let chain: (String, String) -> Bool = { a, b in
      Set([a, b]) == ["a", "b"] || Set([a, b]) == ["b", "c"]
    }
    #expect(TabGroups.clustered(["a", "x", "c", "b"], related: chain) == ["a", "c", "b", "x"])
  }

  @Test func runsSplitOnlyBetweenUnrelatedTabs() {
    #expect(TabGroups.runs(["a1", "a2", "b1", "c1", "c2"], related: related) == [0..<2, 2..<3, 3..<5])
    #expect(TabGroups.runs([String](), related: related).isEmpty)
  }

  @Test func ticketMentionsAreRemovedFromTabTitles() {
    #expect(TabGroups.title("Simplify the tenant routing layer (CON-205)", without: "CON-205")
      == "Simplify the tenant routing layer")
    #expect(TabGroups.title("[con-205] Fix routing", without: "CON-205") == "Fix routing")
    #expect(TabGroups.title("CON-205: Fix routing", without: "CON-205") == "Fix routing")
    #expect(TabGroups.title("Fix [CON-205] routing", without: "CON-205") == "Fix routing")
    #expect(TabGroups.title("CON-205", without: "CON-205") == "CON-205")
    #expect(TabGroups.title("Fix routing", without: nil) == "Fix routing")
  }
}
