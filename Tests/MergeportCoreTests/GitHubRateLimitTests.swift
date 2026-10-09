import Foundation
import Testing
@testable import MergeportCore

struct GitHubRateLimitTests {
  private let now = Date(timeIntervalSince1970: 1000)

  private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!,
      statusCode: status, httpVersion: nil, headerFields: headers)!
  }

  @Test func primaryLimitPausesOnlyItsAccountAndResourceUntilReset() async throws {
    let limit = GitHubRateLimit()
    let error = await limit.observe(token: "a", resource: "graphql",
      response: response(200, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"]),
      data: Data(#"{"errors":[{"type":"RATE_LIMIT","message":"API rate limit exceeded"}]}"#.utf8), now: now)
    #expect(error?.retryAt == Date(timeIntervalSince1970: 2001))
    await #expect(throws: GitHubRateLimitError.self) {
      try await limit.check(token: "a", resource: "graphql", now: now)
    }
    try await limit.check(token: "a", resource: "core", now: now)
    try await limit.check(token: "b", resource: "graphql", now: now)
    try await limit.check(token: "a", resource: "graphql", now: Date(timeIntervalSince1970: 2001))
  }

  @Test func finalSuccessfulRequestIsReturnedButNextRequestIsPaused() async throws {
    let limit = GitHubRateLimit()
    let error = await limit.observe(token: "a", resource: "core",
      response: response(200, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"]),
      data: Data("{}".utf8), now: now)
    #expect(error == nil)
    await #expect(throws: GitHubRateLimitError.self) {
      try await limit.check(token: "a", resource: "core", now: now)
    }
  }

  @Test func secondaryLimitHonorsRetryAfterAcrossResources() async throws {
    let limit = GitHubRateLimit()
    let error = await limit.observe(token: "a", resource: "core",
      response: response(429, ["Retry-After": "120"]),
      data: Data("{}".utf8), now: now)
    #expect(error?.retryAt == now.addingTimeInterval(120))
    await #expect(throws: GitHubRateLimitError.self) {
      try await limit.check(token: "a", resource: "graphql", now: now)
    }
    try await limit.check(token: "a", resource: "core", now: now.addingTimeInterval(120))
  }

  @Test func permissionDenialDoesNotInventRateLimit() async throws {
    let limit = GitHubRateLimit()
    #expect(await limit.observe(token: "a", resource: "core", response: response(403),
      data: Data(#"{"message":"Resource not accessible by integration"}"#.utf8), now: now) == nil)
    try await limit.check(token: "a", resource: "core", now: now)
  }

  @Test func secondaryForbiddenResponsePausesBothAPIs() async {
    let limit = GitHubRateLimit()
    let error = await limit.observe(token: "a", resource: "core",
      response: response(403, ["Retry-After": "90"]),
      data: Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8), now: now)
    #expect(error?.retryAt == now.addingTimeInterval(90))
    await #expect(throws: GitHubRateLimitError.self) {
      try await limit.check(token: "a", resource: "graphql", now: now)
    }
  }
}
