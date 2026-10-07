import Foundation
@testable import MergeportCore
import Testing

struct FileTreeTests {
  private func file(_ name: String) -> PullRequestFile {
    PullRequestFile(filename: name, previousFilename: nil, status: "modified", additions: 1, deletions: 0, patch: nil)
  }

  private let files = [
    "app/services/negotiation/lib/intake/run.ts",
    "app/services/negotiation/lib/intake/pipeline.ts",
    "app/decisions/rules/email-intake.yaml",
    "README.md",
    "app/decisions/generated/decision-map.json",
  ]

  @Test func foldersComeFirstAndSingleChildChainsCompress() {
    let rows = FileTree.rows(for: files.map(file))
    #expect(rows.map { "\(String(repeating: " ", count: $0.depth))\($0.name)" } == [
      "app",
      " decisions",
      "  generated",
      "   decision-map.json",
      "  rules",
      "   email-intake.yaml",
      " services/negotiation/lib/intake",
      "  pipeline.ts",
      "  run.ts",
      "README.md",
    ])
    #expect(FileTree.orderedFilenames(files.map(file)).first == "app/decisions/generated/decision-map.json")
  }

  @Test func collapsedFoldersHideDescendantsAndAncestorsCoverCompressedPaths() {
    let rows = FileTree.rows(for: files.map(file), collapsed: ["app/decisions"])
    #expect(rows.map(\.name) == ["app", "decisions", "services/negotiation/lib/intake", "pipeline.ts", "run.ts", "README.md"])
    #expect(rows[1].kind == .folder(isExpanded: false))
    #expect(FileTree.ancestors(of: "app/services/negotiation/lib/intake/run.ts").contains("app/services/negotiation/lib/intake"))
    #expect(FileTree.ancestors(of: "README.md").isEmpty)
  }
}
