import CryptoKit
import Foundation

public struct GitHubRateLimitError: LocalizedError, Sendable {
  public let retryAt: Date
  public var errorDescription: String? {
    "GitHub API rate limit reached. Requests are paused until \(retryAt.formatted(date: .omitted, time: .standard)). Cached PRs remain available."
  }
}

actor GitHubRateLimit {
  static let shared = GitHubRateLimit()
  private var deadlines: [String: Date] = [:]

  private func key(_ token: String, _ resource: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() + ":" + resource
  }

  func check(token: String, resource: String, now: Date = .now) throws {
    for resource in [resource, "all"] {
      let key = key(token, resource)
      if let date = deadlines[key], date > now { throw GitHubRateLimitError(retryAt: date) }
      deadlines[key] = nil
    }
  }

  func observe(
    token: String, resource: String, response: HTTPURLResponse, data: Data, now: Date = .now
  ) -> GitHubRateLimitError? {
    let problem = try? JSONDecoder().decode(Problem.self, from: data)
    let rateError = problem?.errors?.contains {
      $0.type == "RATE_LIMIT" || $0.message.lowercased().contains("rate limit")
    } == true || problem?.message?.lowercased().contains("rate limit") == true
    let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    let limited = rateError || response.statusCode == 429
      || response.statusCode == 403 && (exhausted || retry != nil)
    guard exhausted || limited else { return nil }
    let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
      .map { Date(timeIntervalSince1970: $0).addingTimeInterval(1) }
    let until = max(now.addingTimeInterval(retry ?? (reset == nil ? 60 : 1)), reset ?? now)
    let primary = problem?.errors?.contains { $0.type == "RATE_LIMIT" } == true
      || problem?.message?.lowercased().contains("api rate limit exceeded") == true
    let bucket = exhausted || primary && retry == nil && response.statusCode != 429
      ? response.value(forHTTPHeaderField: "X-RateLimit-Resource") ?? resource : "all"
    let key = key(token, bucket)
    deadlines[key] = max(deadlines[key] ?? .distantPast, until)
    return limited ? GitHubRateLimitError(retryAt: until) : nil
  }

  private struct Problem: Decodable {
    struct APIError: Decodable { let type: String?; let message: String }
    let message: String?
    let errors: [APIError]?
  }
}
