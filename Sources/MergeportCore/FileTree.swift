import Foundation

/// A visible row of the changed-files tree. Folders with a single child folder are
/// compressed into one row (`lib/intake`), like GitHub's file tree.
public struct FileTreeRow: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case folder(isExpanded: Bool)
    case file(PullRequestFile)
  }

  /// Full path of the folder or file; folders and files never collide.
  public let path: String
  public let name: String
  public let depth: Int
  public let kind: Kind
  public var id: String { (isFolder ? "dir:" : "file:") + path }
  public var isFolder: Bool { if case .folder = kind { true } else { false } }
}

public enum FileTree {
  private final class Node {
    var folders: [String: Node] = [:]
    var files: [PullRequestFile] = []
  }

  /// Folders first, then files, both in Finder order. `collapsed` holds folder paths.
  public static func rows(for files: [PullRequestFile], collapsed: Set<String> = []) -> [FileTreeRow] {
    let root = Node()
    for file in files {
      var node = root
      let parts = file.filename.split(separator: "/").map(String.init)
      for part in parts.dropLast() {
        if let next = node.folders[part] {
          node = next
        } else {
          let next = Node()
          node.folders[part] = next
          node = next
        }
      }
      node.files.append(file)
    }
    var rows: [FileTreeRow] = []
    append(root, prefix: "", depth: 0, collapsed: collapsed, into: &rows)
    return rows
  }

  /// File paths in visual order, ignoring collapsed folders. Used for next/previous navigation.
  public static func orderedFilenames(_ files: [PullRequestFile]) -> [String] {
    rows(for: files).compactMap { if case .file(let file) = $0.kind { file.filename } else { nil } }
  }

  /// Every folder path containing `filename`, including compressed chains.
  public static func ancestors(of filename: String) -> [String] {
    let parts = filename.split(separator: "/").map(String.init).dropLast()
    return parts.indices.map { parts[...$0].joined(separator: "/") }
  }

  private static func append(
    _ node: Node, prefix: String, depth: Int, collapsed: Set<String>, into rows: inout [FileTreeRow]
  ) {
    for name in node.folders.keys.sorted(by: finderOrder) {
      var folder = node.folders[name]!
      var label = name
      var path = prefix + name
      while folder.files.isEmpty, folder.folders.count == 1, let (child, next) = folder.folders.first {
        label += "/" + child
        path += "/" + child
        folder = next
      }
      let expanded = !collapsed.contains(path)
      rows.append(FileTreeRow(path: path, name: label, depth: depth, kind: .folder(isExpanded: expanded)))
      if expanded { append(folder, prefix: path + "/", depth: depth + 1, collapsed: collapsed, into: &rows) }
    }
    for file in node.files.sorted(by: { finderOrder($0.filename, $1.filename) }) {
      let name = file.filename.split(separator: "/").last.map(String.init) ?? file.filename
      rows.append(FileTreeRow(path: file.filename, name: name, depth: depth, kind: .file(file)))
    }
  }

  private static func finderOrder(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
  }
}
