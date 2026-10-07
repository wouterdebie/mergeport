import Foundation
import Testing

@testable import MergeportCore

private struct Reply: Sendable {
  let status: Int
  let data: Data
  init(_ value: Any, status: Int = 200) throws {
    self.status = status
    data = try JSONSerialization.data(withJSONObject: value)
  }
}

private final class StubState: @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [Reply] = []
  private var recorded: [URLRequest] = []
  private var handler: (@Sendable (URLRequest) throws -> Reply)?

  func install(_ replies: [Reply]) {
    lock.lock()
    defer { lock.unlock() }
    self.replies = replies
    recorded = []
    handler = nil
  }

  func route(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
    lock.lock()
    defer { lock.unlock() }
    recorded = []
    replies = []
    self.handler = handler
  }

  func next(_ request: URLRequest) throws -> Reply {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
    if let handler { return try handler(request) }
    guard !replies.isEmpty else { throw MergeportError.message("Unexpected test HTTP request") }
    return replies.removeFirst()
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  static let state = StubState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      var recorded = request
      if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count >= 0 else {
            throw stream.streamError ?? MergeportError.message("Cannot read test request")
          }
          if count == 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
        recorded.httpBody = data
      }
      let reply = try Self.state.next(recorded)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: reply.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@Suite(.serialized)
struct GitHubClientTests {
  private func session(_ replies: [Reply]) -> URLSession {
    StubProtocol.state.install(replies)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func fixture(_ number: Int, overrides: [String: Any] = [:]) -> [String: Any] {
    var value: [String: Any] = [
      "id": "PR_\(number)", "number": number, "title": "PR \(number)",
      "url": "https://github.com/acme/app/pull/\(number)", "isDraft": false, "state": "OPEN",
      "updatedAt": "2026-10-06T12:00:00Z", "additions": 10, "deletions": 2,
      "author": ["login": "you"], "repository": ["nameWithOwner": "acme/app"],
      "headRepository": ["nameWithOwner": "acme/app"], "headRefName": "feature",
      "baseRefName": "main", "headRefOid": "current", "reviewDecision": NSNull(),
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
      "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
      "reviewRequests": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []],
      "reviews": ["pageInfo": ["hasPreviousPage": false], "nodes": []],
      "reviewThreads": ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": []],
    ]
    value.merge(overrides) { _, new in new }
    return value
  }

  private func viewerReply() throws -> Reply { try Reply(["data": ["viewer": ["login": "you"]]]) }
  private func searchReply(_ prs: [[String: Any]], next: String? = nil, total: Int = 1) throws
    -> Reply
  {
    try Reply([
      "data": [
        "search": [
          "issueCount": total, "nodes": prs,
          "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()],
        ]
      ]
    ])
  }
  private func repositoryReply(_ prs: [[String: Any]], next: String? = nil) throws -> Reply {
    try Reply([
      "data": [
        "repository": [
          "pullRequests": [
            "nodes": prs,
            "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()],
          ]
        ]
      ]
    ])
  }

  @Test func paginatesDeduplicatesAndPreservesReviewRequestedSearch() async throws {
    let http = session([
      try viewerReply(),
      try searchReply([fixture(1)], next: "mine-page-2"),
      try searchReply([fixture(2)]),
      try searchReply([fixture(3, overrides: ["author": ["login": "alex"]])]),
      try repositoryReply([fixture(1), fixture(3)], next: "repo-page-2"),
      try repositoryReply([fixture(4)]),
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: ["acme/app"])
    #expect(result.pullRequests.count == 4)
    #expect(result.pullRequests.first { $0.number == 3 }?.reviewRequested == true)
    #expect(result.pullRequests.first { $0.number == 1 }?.stage == .ready)
    let requests = StubProtocol.state.requests
    #expect(requests.count == 6)
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
      })
    let secondPage = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
    #expect((secondPage["variables"] as? [String: Any])?["cursor"] as? String == "mine-page-2")
    let searchQuery = String(data: requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(!searchQuery.contains("reviewThreads"))
    #expect(!searchQuery.contains("mergeable"))
  }

  @Test func inboxListLoadsReviewConnectionsOnePullRequestAtATime() async throws {
    var slim = fixture(7)
    slim.removeValue(forKey: "reviewRequests")
    slim.removeValue(forKey: "reviews")
    slim.removeValue(forKey: "reviewThreads")
    let full = fixture(
      7,
      overrides: [
        "reviewRequests": [
          "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
          "nodes": [["requestedReviewer": ["login": "you"]]],
        ]
      ])
    let http = session([
      try viewerReply(),
      try searchReply([slim]),
      try searchReply([]),
      try Reply([
        "data": [
          "node": [
            "reviewRequests": full["reviewRequests"]!,
            "reviews": full["reviews"]!,
            "reviewThreads": full["reviewThreads"]!,
          ]
        ]
      ]),
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(repositories: [])
    let pr = try #require(result.pullRequests.first)
    #expect(pr.number == 7)
    #expect(pr.reviewRequested)
    let requests = StubProtocol.state.requests
    #expect(requests.count == 4)
    let bodies = requests.map { String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? "" }
    let followUp = bodies.first { $0.contains("PR_7") } ?? ""
    #expect(followUp.contains("reviewThreads"))
    #expect(followUp.contains("mergeable"))
    #expect(!bodies[1].contains("mergeable"))
  }

  @Test func inboxConnectionsLoadConcurrentlyAndMatchTheirPullRequest() async throws {
    let numbers = Array(1...9)
    let slim = numbers.map { number -> [String: Any] in
      var node = fixture(number)
      for key in ["reviewRequests", "reviews", "reviewThreads", "mergeable", "mergeStateStatus"] {
        node.removeValue(forKey: key)
      }
      return node
    }
    let mine = try searchReply(slim, total: slim.count)
    let empty = try searchReply([])
    let http = session([])
    defer { http.invalidateAndCancel() }
    let searches = SearchCounter()
    StubProtocol.state.route { request in
      let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
      if body.contains("viewer { login }") { return try Reply(["data": ["viewer": ["login": "you"]]]) }
      if body.contains("search(") { return searches.next() == 0 ? mine : empty }
      let number = numbers.first { body.contains("\"PR_\($0)\"") } ?? 0
      let full = fixture(number)
      return try Reply([
        "data": [
          "node": [
            "reviewRequests": full["reviewRequests"]!, "reviews": full["reviews"]!,
            "reviewThreads": full["reviewThreads"]!,
            "mergeable": number.isMultiple(of: 2) ? "CONFLICTING" : "MERGEABLE",
            "mergeStateStatus": number.isMultiple(of: 2) ? "DIRTY" : "CLEAN",
          ]
        ]
      ])
    }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: [])
    #expect(result.pullRequests.count == numbers.count)
    for pr in result.pullRequests {
      #expect(pr.mergeable == (pr.number.isMultiple(of: 2) ? "CONFLICTING" : "MERGEABLE"))
    }
  }

  @Test func reviewThreadsArePaginatedBeforeClassifyingReadiness() async throws {
    let first = fixture(
      1,
      overrides: [
        "reviewThreads": [
          "pageInfo": ["hasNextPage": true, "endCursor": "threads-2"],
          "nodes": [["isResolved": true]],
        ]
      ])
    let http = session([
      try viewerReply(), try searchReply([first]),
      try searchReply([]),
      try Reply([
        "data": [
          "node": [
            "reviewThreads": [
              "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
              "nodes": [["isResolved": false]],
            ]
          ]
        ]
      ]),
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: [])
    #expect(result.pullRequests.first?.unresolvedThreads == 1)
    #expect(result.pullRequests.first?.stage == .attention)
  }

  @Test func unresolvedCopilotFindingsDoNotBlockReadyToMerge() async throws {
    func thread(_ login: String) -> [String: Any] {
      ["isResolved": false, "comments": ["nodes": [["author": ["login": login]]]]]
    }
    let copilotOnly = fixture(
      1,
      overrides: [
        "reviewThreads": [
          "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
          "nodes": [thread("copilot-pull-request-reviewer"), thread("Copilot")],
        ]
      ])
    let human = fixture(
      2,
      overrides: [
        "reviewThreads": [
          "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
          "nodes": [thread("copilot-pull-request-reviewer"), thread("alex")],
        ]
      ])
    let http = session([try viewerReply(), try searchReply([copilotOnly, human]), try searchReply([])])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: [])
    let first = try #require(result.pullRequests.first { $0.number == 1 })
    #expect(first.unresolvedThreads == 2 && first.copilotUnresolved == 2)
    #expect(first.stage == .ready)
    let second = try #require(result.pullRequests.first { $0.number == 2 })
    #expect(second.blockingUnresolved == 1)
    #expect(second.stage == .attention)
    #expect(second.waitingReason == "1 unresolved review threads")
  }

  @Test func copilotReviewMustMatchCurrentHeadCommit() async throws {
    let reviews: [String: Any] = [
      "pageInfo": ["hasPreviousPage": false],
      "nodes": [
        [
          "author": ["login": "copilot-pull-request-reviewer"],
          "state": "COMMENTED", "commit": ["oid": "old"],
        ]
      ],
    ]
    let http = session([
      try viewerReply(), try searchReply([fixture(1, overrides: ["reviews": reviews])]),
      try searchReply([]),
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: [])
    #expect(result.pullRequests.first?.copilot == .outdated)
  }

  @Test func copilotRequestsAreFoundBeyondFirstReviewerPage() async throws {
    let first = fixture(
      1,
      overrides: [
        "reviewRequests": [
          "pageInfo": ["hasNextPage": true, "endCursor": "reviewers-2"], "nodes": [],
        ]
      ])
    let http = session([
      try viewerReply(), try searchReply([first]),
      try searchReply([]),
      try Reply([
        "data": [
          "node": [
            "reviewRequests": [
              "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
              "nodes": [["requestedReviewer": ["login": "copilot-pull-request-reviewer"]]],
            ]
          ]
        ]
      ]),
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).snapshot(
      repositories: [])
    #expect(result.pullRequests.first?.copilot == .requested)
  }

  @Test func mergedReviewTabsCanBeRefreshedOutsideOpenInbox() async throws {
    let http = session([
      try Reply([
        "data": ["repository": ["pullRequest": fixture(1, overrides: ["state": "MERGED"])]]
      ])
    ])
    defer { http.invalidateAndCancel() }
    let result = try await GitHubClient(token: "fixture-token", session: http).pullRequest(
      repository: "acme/app", number: 1, viewer: "you")
    #expect(result.state == "MERGED")
    #expect(result.stage != .ready)
  }

  @Test func partialGraphQLErrorsAreNotSuccessfulSnapshots() async throws {
    let http = session([
      try Reply([
        "data": ["viewer": ["login": "you"]], "errors": [["message": "SSO authorization required"]],
      ])
    ])
    defer { http.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await GitHubClient(token: "fixture-token", session: http).snapshot(repositories: [])
    }
  }

  @Test func inaccessibleFollowedRepositoryIsAnError() async throws {
    let http = session([
      try viewerReply(), try searchReply([]), try searchReply([]),
      try Reply(["data": ["repository": NSNull()]]),
    ])
    defer { http.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await GitHubClient(token: "fixture-token", session: http).snapshot(repositories: [
        "acme/missing"
      ])
    }
  }

  @Test func searchLimitIsExplicitRatherThanTruncated() async throws {
    let http = session([try viewerReply(), try searchReply([], total: 1001)])
    defer { http.invalidateAndCancel() }
    await #expect(throws: (any Error).self) {
      try await GitHubClient(token: "fixture-token", session: http).snapshot(repositories: [])
    }
  }

  @Test func revokedOAuthIsAnError() async throws {
    let http = session([try Reply(["message": "Bad credentials"], status: 401)])
    defer { http.invalidateAndCancel() }
    await #expect(throws: MergeportError.self) {
      try await GitHubClient(token: "fixture-token", session: http).viewer()
    }
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test func readRequestsRetryGatewayErrors() async throws {
    let http = session([
      try Reply(["message": "bad gateway"], status: 502),
      try viewerReply(),
    ])
    defer { http.invalidateAndCancel() }
    let viewer = try await GitHubClient(token: "fixture-token", session: http).viewer()
    #expect(viewer.login == "you")
    #expect(StubProtocol.state.requests.count == 2)
  }

  @Test func gatewayErrorsStopAfterThreeReads() async throws {
    let http = session([
      try Reply(["message": "bad gateway"], status: 502),
      try Reply(["message": "bad gateway"], status: 503),
      try Reply(["message": "bad gateway"], status: 504),
    ])
    defer { http.invalidateAndCancel() }
    await #expect(throws: MergeportError.self) {
      try await GitHubClient(token: "fixture-token", session: http).viewer()
    }
    #expect(StubProtocol.state.requests.count == 3)
  }

  @Test func mutationsDoNotRetryGatewayErrors() async throws {
    let http = session([try Reply(["message": "bad gateway"], status: 502)])
    defer { http.invalidateAndCancel() }
    await #expect(throws: MergeportError.self) {
      try await GitHubClient(token: "fixture-token", session: http).setThreadResolved("T", resolved: true)
    }
    #expect(StubProtocol.state.requests.count == 1)
  }

  @Test func deviceCodeUsesPublicClientIDAndValidatesAuthorizationURL() async throws {
    let http = session([
      try Reply([
        "device_code": "fixture-device", "user_code": "ABCD-EFGH",
        "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5,
      ])
    ])
    defer { http.invalidateAndCancel() }
    let code = try await GitHubOAuth(session: http).requestCode(clientID: "public-client")
    #expect(code.userCode == "ABCD-EFGH")
    let request = StubProtocol.state.requests[0]
    #expect(request.url?.absoluteString == "https://github.com/login/device/code")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("scope=repo%20read%3Aorg"))
  }

  @Test func disabledDeviceFlowGivesSetupInstructions() async throws {
    let http = session([try Reply(["error": "device_flow_disabled"])])
    defer { http.invalidateAndCancel() }
    do {
      _ = try await GitHubOAuth(session: http).requestCode(clientID: "public-client")
      Issue.record("Disabled device flow must fail.")
    } catch {
      #expect(error.localizedDescription.contains("app owner must enable device flow"))
    }
  }

  @Test func nativeReviewSubmissionUsesCapturedCommitAndExactLineSides() async throws {
    let http = session([try Reply(["head": ["sha": "head"]]), try Reply(["id": 123])])
    defer { http.invalidateAndCancel() }
    var draft = ReviewDraft()
    draft.headSHA = "head"
    draft.event = .approve
    draft.comments = [
      DraftComment(
        anchor: DiffAnchor(path: "src/a.swift", line: 42, side: .left), body: "Keep this guard")
    ]
    try await GitHubClient(token: "fixture-token", session: http).submitReview(
      repository: "acme/app", number: 1, draft: draft)
    let requests = StubProtocol.state.requests
    #expect(requests.count == 2)
    #expect(requests[1].httpMethod == "POST")
    #expect(requests[1].url?.path == "/repos/acme/app/pulls/1/reviews")
    let data = try #require(requests[1].httpBody)
    let json = try JSONSerialization.jsonObject(with: data)
    let body = try #require(json as? [String: Any])
    #expect(body["commit_id"] as? String == "head")
    #expect(body["event"] as? String == "APPROVE")
    let comment = try #require((body["comments"] as? [[String: Any]])?.first)
    #expect(comment["path"] as? String == "src/a.swift")
    #expect(comment["line"] as? Int == 42)
    #expect(comment["side"] as? String == "LEFT")
  }

  @Test func changedHeadPreventsPostingTheReview() async throws {
    let http = session([try Reply(["head": ["sha": "new-head"]])])
    defer { http.invalidateAndCancel() }
    var draft = ReviewDraft()
    draft.headSHA = "old-head"
    draft.event = .approve
    await #expect(throws: MergeportError.self) {
      try await GitHubClient(token: "fixture-token", session: http).submitReview(
        repository: "acme/app", number: 1, draft: draft)
    }
    #expect(StubProtocol.state.requests.count == 1)
    #expect(StubProtocol.state.requests[0].httpMethod == "GET")
  }

  @Test func emptyReviewsAndCommentsMakeNoRequests() async throws {
    let http = session([])
    defer { http.invalidateAndCancel() }
    var draft = ReviewDraft()
    draft.headSHA = "head"
    let client = GitHubClient(token: "fixture-token", session: http)
    await #expect(throws: MergeportError.self) {
      try await client.submitReview(repository: "acme/app", number: 1, draft: draft)
    }
    await #expect(throws: MergeportError.self) {
      try await client.postComment(repository: "acme/app", number: 1, body: " \n")
    }
    #expect(StubProtocol.state.requests.isEmpty)
  }

  @Test func nativeRepliesUseTheTopLevelReviewCommentEndpoint() async throws {
    let http = session([try Reply(["id": 42])])
    defer { http.invalidateAndCancel() }
    try await GitHubClient(token: "fixture-token", session: http).postComment(
      repository: "acme/app", number: 1, body: "Updated", replyTo: 99)
    let request = try #require(StubProtocol.state.requests.first)
    #expect(request.url?.path == "/repos/acme/app/pulls/1/comments/99/replies")
    #expect(request.httpMethod == "POST")
  }

  @Test func sidebarEditsPatchTheIssueAndCanClearTheMilestone() async throws {
    let http = session([try Reply(["id": 1]), try Reply(["id": 1])])
    defer { http.invalidateAndCancel() }
    let client = GitHubClient(token: "fixture-token", session: http)
    try await client.updateIssue(
      repository: "acme/app", number: 7, assignees: ["octocat"], labels: ["bug"])
    try await client.updateIssue(repository: "acme/app", number: 7, milestone: .some(nil))
    let requests = StubProtocol.state.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/repos/acme/app/issues/7")
    #expect(requests[0].httpMethod == "PATCH")
    let firstBody = try #require(requests[0].httpBody)
    let first = try #require(try JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
    #expect(first["assignees"] as? [String] == ["octocat"])
    #expect(first["labels"] as? [String] == ["bug"])
    #expect(first["milestone"] == nil)
    let secondBody = try #require(requests[1].httpBody)
    let second = try #require(try JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
    #expect(second["milestone"] is NSNull)
    #expect(second["labels"] == nil)
  }

  @Test func reviewRequestsSplitUsersAndCopilotAndKeepExistingReviewers() async throws {
    let http = session([try Reply(["data": ["result": ["clientMutationId": NSNull()]]])])
    defer { http.invalidateAndCancel() }
    let client = GitHubClient(token: "fixture-token", session: http)
    try await client.requestReviews("PR_1", logins: ["octocat", "Copilot"])
    let request = try #require(StubProtocol.state.requests.first)
    let json = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
    let body = try #require(json as? [String: Any])
    #expect((body["query"] as? String)?.contains("union: true") == true)
    let variables = try #require(body["variables"] as? [String: Any])
    #expect(variables["users"] as? [String] == ["octocat"])
    #expect(variables["bots"] as? [String] == ["copilot-pull-request-reviewer"])
    await #expect(throws: MergeportError.self) {
      try await client.requestReviews("PR_1", logins: ["bad login"])
    }
  }

  @Test func mergeUsesTheLoadedSHAAndRejectsSuccessShapedFailures() async throws {
    let http = session([try Reply(["merged": false, "message": "Approval required"])])
    defer { http.invalidateAndCancel() }
    await #expect(throws: MergeportError.self) {
      try await GitHubClient(token: "fixture-token", session: http).merge(
        repository: "acme/app", number: 1, sha: "loaded-head", method: .squash)
    }
    let request = try #require(StubProtocol.state.requests.first)
    #expect(request.httpMethod == "PUT")
    let data = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: data)
    let body = try #require(json as? [String: String])
    #expect(body["sha"] == "loaded-head")
    #expect(body["merge_method"] == "squash")
  }

  @Test func nativeDetailsPaginateFilesAndDecodeAllReviewSurfaces() async throws {
    let http = session([])
    defer { http.invalidateAndCancel() }
    let info = fixture(
      1,
      overrides: [
        "body": "Summary", "bodyHTML": "<h2>Summary</h2>", "createdAt": "2026-10-06T10:00:00Z",
        "changedFiles": 101, "viewerCanUpdate": true, "commitCount": ["totalCount": 1],
      ])
    func file(_ number: Int) -> [String: Any] {
      [
        "filename": "file-\(number).swift", "status": "modified", "additions": 1, "deletions": 0,
        "patch": "@@ -1 +1,2 @@\n old\n+new",
      ]
    }
    let metadata = try Reply([
      "data": [
        "viewer": ["login": "you"],
        "repository": [
          "viewerPermission": "WRITE", "mergeCommitAllowed": true, "squashMergeAllowed": true,
          "rebaseMergeAllowed": false,
          "pullRequest": info,
        ],
      ]
    ])
    let checksPage = try Reply([
      "data": [
        "repository": [
          "object": [
            "statusCheckRollup": [
              "contexts": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                "nodes": [
                  [
                    "databaseId": 9, "name": "Tests", "status": "COMPLETED",
                    "conclusion": "SUCCESS", "detailsUrl": NSNull(),
                  ],
                  ["id": "S1", "context": "deploy", "state": "PENDING", "targetUrl": NSNull()],
                ],
              ]
            ]
          ]
        ]
      ]
    ])
    let threadPage = try Reply([
      "data": [
        "node": [
          "reviewThreads": [
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": [],
          ]
        ]
      ]
    ])
    let routes: [String: Reply] = [
      "/repos/acme/app/issues/1/timeline?per_page=100&page=1": try Reply(
        [
          [
            "id": 10, "event": "ready_for_review", "actor": ["login": "you"],
            "created_at": "2026-10-06T11:00:00Z",
          ],
          [
            "id": 11, "event": "review_requested", "actor": ["login": "you"],
            "requested_reviewer": ["login": "alex"], "created_at": "2026-10-06T11:01:00Z",
          ],
        ]
          + (0..<98).map {
            ["id": 100 + $0, "event": "commented", "created_at": "2026-10-06T12:00:00Z"]
          }),
      "/repos/acme/app/issues/1/timeline?per_page=100&page=2": try Reply([
        [
          "id": 12, "event": "cross-referenced", "actor": ["login": "alex"],
          "created_at": "2026-10-06T13:00:00Z",
          "source": [
            "issue": [
              "title": "Related change", "number": 5459, "state": "closed",
              "html_url": "https://github.com/acme/app/pull/5459",
              "pull_request": ["merged_at": "2026-10-06T14:00:00Z"],
              "repository": ["full_name": "acme/app"],
            ]
          ],
        ]
      ]),
      "/repos/acme/app/pulls/1/files?per_page=100&page=1": try Reply((0..<100).map(file)),
      "/repos/acme/app/pulls/1/files?per_page=100&page=2": try Reply([file(100)]),
      "/repos/acme/app/issues/1/comments?per_page=100&page=1": try Reply([
        [
          "id": 1, "user": ["login": "alex"], "body": "Looks good",
          "body_html": "<p>Looks good</p>",
          "created_at": "2026-10-06T12:00:00Z",
          "html_url": "https://github.com/acme/app/pull/1#issuecomment-1",
        ]
      ]),
      "/repos/acme/app/pulls/1/reviews?per_page=100&page=1": try Reply([
        [
          "id": 2,
          "user": [
            "login": "copilot-pull-request-reviewer[bot]",
            "avatar_url": "https://avatars.githubusercontent.com/in/946600?v=4",
          ],
          "state": "COMMENTED", "body": "A suggestion",
          "body_html": "<p>A suggestion</p>",
          "submitted_at": "2026-10-06T12:00:00Z",
        ],
        [
          "id": 3, "user": ["login": "you"], "state": "PENDING", "body": "Unsubmitted",
          "submitted_at": NSNull(),
        ],
      ]),
      "/repos/acme/app/pulls/1/commits?per_page=100&page=1": try Reply([
        [
          "sha": "current", "html_url": "https://github.com/acme/app/commit/current",
          "author": ["login": "alex"],
          "commit": [
            "message": "Feature", "author": ["name": "Alex", "date": "2026-10-06T12:00:00Z"],
          ],
        ]
      ]),
      "/repos/acme/app/pulls/1": try Reply(["head": ["sha": "current"]]),
    ]
    StubProtocol.state.route { request in
      if request.url?.path == "/graphql" {
        let query = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if query.contains("commitCount:") { return metadata }
        if query.contains("contexts(") { return checksPage }
        return threadPage
      }
      let key = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")
      guard let reply = routes[key] else {
        throw MergeportError.message("Unexpected fixture route: \(key)")
      }
      return reply
    }
    let details = try await GitHubClient(token: "fixture-token", session: http).reviewDetails(
      repository: "acme/app", number: 1)
    #expect(details.files.count == 101)
    #expect(details.comments.first?.body == "Looks good")
    #expect(details.bodyHTML == "<h2>Summary</h2>")
    #expect(details.comments.first?.bodyHTML == "<p>Looks good</p>")
    #expect(details.events.count == 3)
    #expect(details.events[1].action == "requested review from alex")
    #expect(details.events.last?.title == "Related change #5459 · closed")
    #expect(details.events.last?.reference?.state == .merged)
    #expect(details.events.last?.reference?.number == 5459)
    if case .references(let group)? = details.conversation.first(where: {
      if case .references = $0 { true } else { false }
    }) {
      #expect(group.count == 1)
    } else {
      Issue.record("Cross-references should be grouped")
    }
    #expect(
      CheckSummary([
        PullRequestCheck(id: "1", name: "a", state: "success", url: nil),
        PullRequestCheck(id: "2", name: "b", state: "in_progress", url: nil),
        PullRequestCheck(id: "3", name: "c", state: "skipped", url: nil),
      ]) == CheckSummary(successful: 1, pending: 1, skipped: 1))
    #expect(details.reviews.first?.bodyHTML == "<p>A suggestion</p>")
    #expect(
      details.avatarURL(for: "copilot-pull-request-reviewer")?.absoluteString
        == "https://avatars.githubusercontent.com/in/946600?v=4")
    #expect(details.avatarURL(for: "unknown-bot[bot]") == nil)
    #expect(details.avatarURL(for: "alex")?.absoluteString == "https://github.com/alex.png?size=80")
    #expect(ReviewDetails.displayName("copilot-pull-request-reviewer[bot]") == "Copilot")
    #expect(details.conversation.count == 6)
    #expect(details.conversation.map(\.date) == details.conversation.map(\.date).sorted())
    #expect(details.reviews.first?.state == "COMMENTED")
    #expect(details.checks.first?.state == "success")
    #expect(details.checks.last?.state == "pending")
    #expect(details.checkSummary == CheckSummary(successful: 1, pending: 1))
    #expect(details.commits.first?.message == "Feature")
    #expect(details.mergeMethods == [.squash, .merge])
    #expect(details.canMerge)
    #expect(details.notices.isEmpty)
  }
}

extension GitHubClientTests {
  @Test func linearIssuesBatchByTeamAndSkipUnknownTickets() async throws {
    let client = LinearClient(
      token: "lin_token",
      session: session([
        try Reply([
          "data": [
            "issues": [
              "nodes": [
                [
                  "identifier": "CON-108", "title": "Email delivery",
                  "url": "https://linear.app/acme/issue/CON-108/email-delivery",
                  "state": ["name": "In Progress", "type": "started", "color": "#f2c94c"],
                ]
              ]
            ]
          ]
        ])
      ]))
    let issues = try await client.issues(["con-108", "CON-171", "ENG-2", "not a ticket"])
    #expect(issues.keys.sorted() == ["CON-108"])
    #expect(issues["CON-108"]?.state == "In Progress")
    let request = try #require(StubProtocol.state.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lin_token")
    let body = try #require(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let filter = try #require((body["variables"] as? [String: Any])?["filter"] as? [String: Any])
    let clauses = try #require(filter["or"] as? [[String: Any]])
    #expect(clauses.count == 2)
    let con = try #require(clauses.first)
    #expect(((con["team"] as? [String: Any])?["key"] as? [String: String])?["eq"] == "CON")
    #expect(((con["number"] as? [String: Any])?["in"] as? [Int]) == [108, 171])
  }

  @Test func linearTokenExchangeUsesPKCEWithoutSecret() async throws {
    let oauth = LinearOAuth(
      clientID: "lin_client",
      session: session([
        try Reply(["access_token": "a1", "refresh_token": "r1", "expires_in": 86399, "token_type": "Bearer"])
      ]))
    let token = try await oauth.exchange(code: "the code", verifier: "v")
    #expect(token.accessToken == "a1")
    #expect(token.refreshToken == "r1")
    #expect(!token.needsRefresh())
    let request = try #require(StubProtocol.state.requests.first)
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("code=the%20code"))
    #expect(body.contains("code_verifier=v"))
    #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A47389%2Flinear%2Fcallback"))
    #expect(!body.contains("client_secret"))
  }

  @Test func linearUnauthorizedIsReported() async throws {
    let client = LinearClient(token: "expired", session: session([try Reply([:], status: 401)]))
    await #expect(throws: LinearError.self) { _ = try await client.issues(["CON-1"]) }
  }
}

private final class SearchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    defer { count += 1 }
    return count
  }
}
