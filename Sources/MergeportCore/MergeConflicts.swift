import Foundation
import CryptoKit

/// Uses a bare cache: merge-tree writes objects, never a checkout, index or branch.
public actor MergeConflictAnalyzer {
  public static let shared = MergeConflictAnalyzer()

  public func files(repository: String, base: String, head: String, token: String) throws -> [String] {
    let name = try RepositoryName.validate(repository)
    guard Self.isCommit(base), Self.isCommit(head) else {
      throw MergeportError.message("Refresh the PR to load exact commits before inspecting conflicts.")
    }
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dev.wouter.mergeport/merge-conflicts", isDirectory: true)
    let key = SHA256.hash(data: Data(name.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    let cache = root.appendingPathComponent(key, isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let inherited = ProcessInfo.processInfo.environment
    var environment = inherited.filter {
      ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
       "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy"].contains($0.key)
    }
    // Keep credentials out of arguments, remotes and on-disk configuration.
    let credential = Data("x-access-token:\(token)".utf8).base64EncodedString()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_ALLOW_PROTOCOL"] = "https"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    let settings = [
      ("http.https://github.com/.extraheader", "Authorization: Basic \(credential)"),
      ("credential.helper", ""), ("core.hooksPath", "/dev/null"),
      ("http.followRedirects", "false"), ("http.lowSpeedLimit", "1000"),
      ("http.lowSpeedTime", "30"),
    ]
    environment["GIT_CONFIG_COUNT"] = String(settings.count)
    for (index, value) in settings.enumerated() {
      environment["GIT_CONFIG_KEY_\(index)"] = value.0
      environment["GIT_CONFIG_VALUE_\(index)"] = value.1
    }
    func git(_ args: [String], allowed: Set<Int32> = [0]) throws -> Data {
      try Self.run(args, directory: cache, environment: environment, allowed: allowed)
    }
    if !FileManager.default.fileExists(atPath: cache.appendingPathComponent("HEAD").path) {
      _ = try git(["init", "--bare", "--quiet"])
    }
    _ = try git(["config", "remote.origin.url", "https://github.com/\(name).git"])
    _ = try git(["config", "remote.origin.promisor", "true"])
    _ = try git(["config", "remote.origin.partialclonefilter", "blob:none"])
    _ = try git(["fetch", "--quiet", "--no-tags", "--filter=blob:none", "origin", base, head])
    return try Self.localFiles(directory: cache, base: base, head: head, environment: environment)
  }

  static func localFiles(
    directory: URL, base: String, head: String, environment: [String: String]
  ) throws -> [String] {
    let output = try run(
      ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", base, head],
      directory: directory, environment: environment, allowed: [0, 1])
    return try parse(output)
  }

  public static func parse(_ output: Data) throws -> [String] {
    guard let text = String(data: output, encoding: .utf8) else {
      throw MergeportError.message("Git returned conflict paths that are not valid UTF-8.")
    }
    let parts = text.components(separatedBy: "\0")
    guard let tree = parts.first, isCommit(tree), parts.count > 1, parts.last == "",
      parts.dropFirst().dropLast().allSatisfy({ !$0.isEmpty }) else {
      throw MergeportError.message("Git returned an invalid merge analysis result.")
    }
    return Array(Set(parts.dropFirst().dropLast())).sorted()
  }

  private static func isCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func run(
    _ arguments: [String], directory: URL, environment: [String: String], allowed: Set<Int32>
  ) throws -> Data {
    let output = directory.appendingPathComponent("analysis-\(UUID().uuidString).log")
    let errors = directory.appendingPathComponent("analysis-\(UUID().uuidString).err")
    guard FileManager.default.createFile(atPath: output.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw MergeportError.message("Cannot create the merge analysis output file.")
    }
    defer { try? FileManager.default.removeItem(at: output) }
    guard FileManager.default.createFile(atPath: errors.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw MergeportError.message("Cannot create the merge analysis error file.")
    }
    defer { try? FileManager.default.removeItem(at: errors) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let errorHandle = try FileHandle(forWritingTo: errors)
    defer { try? errorHandle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardOutput = handle
    process.standardError = errorHandle
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
    defer { timeout.cancel() }
    process.waitUntilExit()
    guard allowed.contains(process.terminationStatus) else {
      var diagnostic = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
      for value in environment.values where value.hasPrefix("Authorization: Basic ") {
        let encoded = String(value.dropFirst("Authorization: Basic ".count))
        diagnostic = diagnostic.replacingOccurrences(of: value, with: "[redacted]")
          .replacingOccurrences(of: encoded, with: "[redacted]")
        if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
          diagnostic = diagnostic.replacingOccurrences(of: decoded, with: "[redacted]")
          let token = String(decoded.dropFirst("x-access-token:".count))
          if !token.isEmpty { diagnostic = diagnostic.replacingOccurrences(of: token, with: "[redacted]") }
        }
      }
      throw MergeportError.message(
        "Read-only conflict analysis failed during git \(arguments[0]) (exit \(process.terminationStatus)). Check Git 2.38+, network and repository access, then retry.\n\(diagnostic.prefix(2000))")
    }
    return try Data(contentsOf: output)
  }
}
