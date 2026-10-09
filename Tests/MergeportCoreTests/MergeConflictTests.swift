import Foundation
import Testing
@testable import MergeportCore

struct MergeConflictTests {
  @Test func bareMergeAnalysisFindsActualConflictsWithoutChangingCheckout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = args
      process.currentDirectoryURL = root
      var env = ProcessInfo.processInfo.environment
      env["GIT_CONFIG_GLOBAL"] = "/dev/null"
      env["GIT_CONFIG_NOSYSTEM"] = "1"
      env["GIT_AUTHOR_NAME"] = "Fixture"
      env["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
      env["GIT_COMMITTER_NAME"] = "Fixture"
      env["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
      process.environment = env
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw MergeportError.message("Fixture git \(args[0]) failed.")
      }
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let paths = ["a file.swift", "nested/é.swift", "delete.swift"]
    func write(_ name: String, _ text: String) throws {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    _ = try git(["init", "--quiet", "--initial-branch=base"])
    for path in paths { try write(path, "original\n") }
    _ = try git(["add", "."])
    _ = try git(["commit", "--quiet", "-m", "original"])
    let ancestor = try git(["rev-parse", "HEAD"])
    for path in paths { try write(path, "base edit\n") }
    try write("added.swift", "base addition\n")
    _ = try git(["add", "."])
    _ = try git(["commit", "--quiet", "-m", "base"])
    let base = try git(["rev-parse", "HEAD"])
    _ = try git(["checkout", "--quiet", "-b", "head", ancestor])
    for path in paths { try write(path, "head edit\n") }
    try FileManager.default.removeItem(at: root.appendingPathComponent("delete.swift"))
    try write("added.swift", "head addition\n")
    _ = try git(["add", "-A"])
    _ = try git(["commit", "--quiet", "-m", "head"])
    let head = try git(["rev-parse", "HEAD"])
    _ = try git(["clone", "--quiet", "--bare", ".", "cache.git"])
    let environment = ProcessInfo.processInfo.environment
    let cache = root.appendingPathComponent("cache.git")
    let checkoutStatus = try git(["status", "--porcelain"])
    #expect(try MergeConflictAnalyzer.localFiles(directory: cache, base: base, head: head, environment: environment)
      == (paths + ["added.swift"]).sorted())
    #expect(try MergeConflictAnalyzer.localFiles(directory: cache, base: ancestor, head: head, environment: environment).isEmpty)
    #expect(try git(["status", "--porcelain"]) == checkoutStatus)
    #expect(try git(["rev-parse", "HEAD"]) == head)
    #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("index").path))
    #expect(throws: MergeportError.self) {
      try MergeConflictAnalyzer.localFiles(directory: cache, base: String(repeating: "0", count: 40),
        head: head, environment: environment)
    }
  }

  @Test func conflictPathsKeepSpacesNewlinesAndDeduplicate() throws {
    let tree = String(repeating: "a", count: 40)
    let data = Data("\(tree)\0a file.swift\0folder/a\nb.swift\0a file.swift\0".utf8)
    #expect(try MergeConflictAnalyzer.parse(data) == ["a file.swift", "folder/a\nb.swift"])
  }

  @Test func cleanMergeHasNoConflictingFiles() throws {
    #expect(try MergeConflictAnalyzer.parse(Data("\(String(repeating: "b", count: 40))\0".utf8)).isEmpty)
  }

  @Test func invalidMergeOutputFailsExplicitly() {
    #expect(throws: MergeportError.self) { try MergeConflictAnalyzer.parse(Data("not a tree\0".utf8)) }
    #expect(throws: MergeportError.self) { try MergeConflictAnalyzer.parse(Data([0xff])) }
  }
}
