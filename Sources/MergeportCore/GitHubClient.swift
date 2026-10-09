import Foundation

public struct GitHubClient: Sendable {
  private let token: String
  private let session: URLSession

  public init(token: String, session: URLSession = .shared) {
    self.token = token
    self.session = session
  }

  public func viewer() async throws -> Viewer {
    struct Result: Decodable { let viewer: Viewer }
    let result: Result = try await query("query { viewer { login } }")
    return result.viewer
  }

  public func snapshot(
    repositories: [String],
    onListed: (@Sendable (InboxSnapshot, _ loaded: Set<String>) async -> Void)? = nil
  ) async throws -> InboxSnapshot {
    let viewer = try await viewer()
    var nodes: [String: PRNode] = [:]
    let mine = try await searchNodes("is:pr is:open author:\(viewer.login) sort:updated-desc")
    let requested = try await searchNodes(
      "is:pr is:open review-requested:\(viewer.login) sort:updated-desc")
    let requestedIDs = Set(requested.map(\.id))
    for node in mine + requested { nodes[node.id] = node }
    for repository in repositories {
      for node in try await repositoryNodes(repository) { nodes[node.id] = node }
    }
    func pullRequests(from hydrated: [String: PullRequest]) -> [PullRequest] {
      var merged = hydrated
      for node in nodes.values where merged[node.id] == nil {
        merged[node.id] = node.listed(viewer: viewer.login)
      }
      for id in requestedIDs { merged[id]?.reviewRequested = true }
      return merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    let followed = Set(repositories.map { $0.lowercased() })
    var hydrated: [String: PullRequest] = [:]
    if let onListed {
      await onListed(InboxSnapshot(viewer: viewer, pullRequests: pullRequests(from: hydrated)), [])
    }
    let priority = nodes.values.filter {
      requestedIDs.contains($0.id) || followed.contains($0.repository.nameWithOwner.lowercased())
    }
    hydrated = try await hydrateAll(priority, viewer: viewer.login)
    if let onListed, !priority.isEmpty {
      await onListed(
        InboxSnapshot(viewer: viewer, pullRequests: pullRequests(from: hydrated)),
        Set(hydrated.keys))
    }
    let rest = nodes.values.filter { hydrated[$0.id] == nil }
    hydrated.merge(try await hydrateAll(rest, viewer: viewer.login)) { $1 }
    return InboxSnapshot(viewer: viewer, pullRequests: pullRequests(from: hydrated))
  }

  /// One PR at a time per request keeps GitHub's gateway happy; a few in flight keeps large inboxes fast.
  private func hydrateAll(_ nodes: [PRNode], viewer: String, width: Int = 4) async throws
    -> [String: PullRequest]
  {
    try await withThrowingTaskGroup(of: PullRequest.self) { group in
      var pending = nodes.makeIterator()
      for _ in 0..<width {
        guard let node = pending.next() else { break }
        group.addTask { try await hydrate(node, viewer: viewer) }
      }
      var result: [String: PullRequest] = [:]
      while let pr = try await group.next() {
        result[pr.id] = pr
        if let node = pending.next() { group.addTask { try await hydrate(node, viewer: viewer) } }
      }
      return result
    }
  }

  public func pullRequest(repository: String, number: Int, viewer: String) async throws
    -> PullRequest
  {
    struct Repository: Decodable { let pullRequest: PRNode? }
    struct Result: Decodable { let repository: Repository? }
    let parts = try RepositoryName.validate(repository).split(separator: "/")
    guard number > 0 else { throw MergeportError.message("Invalid pull request number.") }
    let result: Result = try await query(
      """
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) { pullRequest(number: $number) { \(Self.fields) } }
      }
      """,
      variables: [
        "owner": .string(String(parts[0])), "name": .string(String(parts[1])),
        "number": .integer(number),
      ])
    guard let node = result.repository?.pullRequest else {
      throw MergeportError.message(
        "Cannot access \(repository)#\(number). Check repository and SSO access.")
    }
    return try await hydrate(node, viewer: viewer)
  }

  private func searchNodes(_ text: String) async throws -> [PRNode] {
    struct Result: Decodable { let search: SearchConnection }
    var cursor: String?
    var result: [PRNode] = []
    repeat {
      let page: Result = try await query(
        """
        query($query: String!, $cursor: String) {
          search(query: $query, type: ISSUE, first: 25, after: $cursor) {
            issueCount pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { \(Self.summaryFields) } }
          }
        }
        """, variables: ["query": .string(text), "cursor": cursor.map(JSONValue.string) ?? .null])
      guard page.search.issueCount <= 1000 else {
        throw MergeportError.message(
          "GitHub search has more than 1,000 results and would be incomplete. Narrow the open PR queue before syncing."
        )
      }
      result.append(contentsOf: page.search.nodes.compactMap { $0 })
      cursor = try page.search.pageInfo.nextCursor()
    } while cursor != nil
    return result
  }

  private func repositoryNodes(_ name: String) async throws -> [PRNode] {
    let validated = try RepositoryName.validate(name)
    let parts = validated.split(separator: "/")
    struct Repository: Decodable { let pullRequests: PRConnection }
    struct Result: Decodable { let repository: Repository? }
    var cursor: String?
    var result: [PRNode] = []
    repeat {
      let page: Result = try await query(
        """
        query($owner: String!, $name: String!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 25, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes { \(Self.summaryFields) }
            }
          }
        }
        """,
        variables: [
          "owner": .string(String(parts[0])), "name": .string(String(parts[1])),
          "cursor": cursor.map(JSONValue.string) ?? .null,
        ])
      guard let repository = page.repository else {
        throw MergeportError.message(
          "Cannot access \(name). Check its name, repository permissions and organization SSO authorization."
        )
      }
      result.append(contentsOf: repository.pullRequests.nodes.compactMap { $0 })
      cursor = try repository.pullRequests.pageInfo.nextCursor()
    } while cursor != nil
    return result
  }

  /// Review threads, reviews, requests, mergeability and checks for one PR.
  /// Computing mergeability for a page of search results makes GitHub's gateway time out and return HTTP 502.
  private struct InboxConnections {
    let reviewRequests: PRNode.ReviewRequests
    let reviews: PRNode.Reviews
    let reviewThreads: ThreadConnection
    let mergeable: String
    let mergeState: String
    let checks: String?
    let stack: PRStack?
  }

  private func loadConnections(_ node: PRNode) async throws -> InboxConnections {
    if let reviewRequests = node.reviewRequests, let reviews = node.reviews,
      let reviewThreads = node.reviewThreads,
      let mergeable = node.mergeable, let mergeState = node.mergeStateStatus
    {
      return InboxConnections(
        reviewRequests: reviewRequests, reviews: reviews, reviewThreads: reviewThreads,
        mergeable: mergeable, mergeState: mergeState, checks: node.rollupState,
        stack: node.stackModel)
    }
    struct Loaded: Decodable {
      let reviewRequests: PRNode.ReviewRequests
      let reviews: PRNode.Reviews
      let reviewThreads: ThreadConnection
      let mergeable: String?
      let mergeStateStatus: String?
      let commits: PRNode.Commits?
      let stackEntry: PRNode.StackPosition?
      let stack: PRNode.StackNode?
    }
    struct Result: Decodable { let node: Loaded? }
    let page: Result = try await query(
      """
      query($id: ID!) {
        node(id: $id) { ... on PullRequest { \(Self.connectionFields) } }
      }
      """, variables: ["id": .string(node.id)])
    guard let loaded = page.node else {
      throw MergeportError.message(
        "A PR disappeared while loading its review status. Refresh to try again.")
    }
    return InboxConnections(
      reviewRequests: loaded.reviewRequests, reviews: loaded.reviews,
      reviewThreads: loaded.reviewThreads,
      mergeable: loaded.mergeable ?? node.mergeable ?? "UNKNOWN",
      mergeState: loaded.mergeStateStatus ?? node.mergeStateStatus ?? "UNKNOWN",
      checks: loaded.commits?.rollupState ?? node.rollupState,
      stack: PRNode.makeStack(entry: loaded.stackEntry, stack: loaded.stack) ?? node.stackModel)
  }

  private func hydrate(_ node: PRNode, viewer: String) async throws -> PullRequest {
    let connections = try await loadConnections(node)
    struct ThreadNode: Decodable { let reviewThreads: ThreadConnection }
    struct ThreadResult: Decodable { let node: ThreadNode? }
    struct RequestNode: Decodable { let reviewRequests: PRNode.ReviewRequests }
    struct RequestResult: Decodable { let node: RequestNode? }
    var unresolved = connections.reviewThreads.unresolved.count
    var copilotUnresolved = connections.reviewThreads.unresolved.filter(\.isCopilot).count
    var cursor = try connections.reviewThreads.pageInfo.nextCursor()
    while let after = cursor {
      let page: ThreadResult = try await query(
        """
        query($id: ID!, $cursor: String!) {
          node(id: $id) { ... on PullRequest {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor } nodes { isResolved comments(first: 1) { nodes { author { login } } } }
            }
          } }
        }
        """, variables: ["id": .string(node.id), "cursor": .string(after)])
      guard let threads = page.node?.reviewThreads else {
        throw MergeportError.message(
          "A PR disappeared while loading its review threads. Refresh to try again.")
      }
      unresolved += threads.unresolved.count
      copilotUnresolved += threads.unresolved.filter(\.isCopilot).count
      cursor = try threads.pageInfo.nextCursor()
    }
    var requested = connections.reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login }
    cursor = try connections.reviewRequests.pageInfo.nextCursor()
    while let after = cursor {
      let page: RequestResult = try await query(
        """
        query($id: ID!, $cursor: String!) {
          node(id: $id) { ... on PullRequest {
            reviewRequests(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes { requestedReviewer { ... on User { login } ... on Bot { login } } }
            }
          } }
        }
        """, variables: ["id": .string(node.id), "cursor": .string(after)])
      guard let requests = page.node?.reviewRequests else {
        throw MergeportError.message(
          "A PR disappeared while loading its requested reviewers. Refresh to try again.")
      }
      requested += requests.nodes.compactMap { $0?.requestedReviewer?.login }
      cursor = try requests.pageInfo.nextCursor()
    }
    return node.model(
      viewer: viewer, reviews: connections.reviews, unresolved: unresolved,
      copilotUnresolved: copilotUnresolved, requested: requested,
      mergeable: connections.mergeable, mergeState: connections.mergeState,
      checks: connections.checks, stack: connections.stack)
  }

  private enum JSONValue: Encodable {
    case string(String)
    case integer(Int)
    case strings([String])
    case null
    func encode(to encoder: Encoder) throws {
      var value = encoder.singleValueContainer()
      switch self {
      case .string(let string): try value.encode(string)
      case .integer(let integer): try value.encode(integer)
      case .strings(let strings): try value.encode(strings)
      case .null: try value.encodeNil()
      }
    }
  }

  private struct Payload: Encodable {
    let query: String
    let variables: [String: JSONValue]
  }

  /// GitHub's gateway sometimes answers a valid read with 502/503/504. Retry those.
  /// Mutations are not retried: a 502 can arrive after the write already landed.
  private struct GatewayFailure: Error { let error: MergeportError }

  private func query<T: Decodable>(_ query: String, variables: [String: JSONValue] = [:])
    async throws -> T
  {
    let reads = query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("query")
    var attempt = 0
    while true {
      do { return try await performQuery(query, variables: variables) }
      catch let failure as GatewayFailure {
        attempt += 1
        guard reads, attempt < 3 else { throw failure.error }
        try await Task.sleep(for: .milliseconds(200 * attempt))
      }
    }
  }

  private func performQuery<T: Decodable>(_ query: String, variables: [String: JSONValue])
    async throws -> T
  {
    var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Mergeport/0.1", forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONEncoder().encode(Payload(query: query, variables: variables))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MergeportError.message("GitHub returned an invalid HTTP response.")
    }
    if http.statusCode == 401 { throw MergeportError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 403 || http.statusCode == 429 {
        throw MergeportError.message(
          "GitHub denied this request or its rate limit was reached. Check OAuth/SSO access, or wait before refreshing."
        )
      }
      let message: String
      if http.statusCode == 502 || http.statusCode == 503 || http.statusCode == 504 {
        message = "GitHub request failed (HTTP \(http.statusCode)). GitHub had a server error; try again shortly."
      } else {
        message = "GitHub request failed (HTTP \(http.statusCode))."
      }
      let error = MergeportError.message(message)
      if http.statusCode == 502 || http.statusCode == 503 || http.statusCode == 504 {
        throw GatewayFailure(error: error)
      }
      throw error
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(GraphQLResponse<T>.self, from: data)
    if let errors = envelope.errors, !errors.isEmpty {
      throw MergeportError.message(errors.map(\.message).joined(separator: "\n"))
    }
    guard let result = envelope.data else { throw MergeportError.message("GitHub returned no data.") }
    return result
  }

  /// Scalars only. `mergeable` and check rollups are computed per pull request: a page of them
  /// under search exceeds GitHub's gateway limit and returns HTTP 502.
  private static let summaryFields = """
    id number title url isDraft state updatedAt additions deletions
    author { login avatarUrl } repository { nameWithOwner } headRefName baseRefName
    headRepository { nameWithOwner } headRefOid reviewDecision
    """

  private static let connectionFields = """
    mergeable mergeStateStatus
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    reviewRequests(first: 100) {
      pageInfo { hasNextPage endCursor }
      nodes { requestedReviewer { ... on User { login } ... on Bot { login } ... on Team { name } } }
    }
    reviews(last: 100) {
      pageInfo { hasPreviousPage }
      nodes { author { login } state commit { oid } }
    }
    reviewThreads(first: 100) {
      pageInfo { hasNextPage endCursor } nodes { isResolved comments(first: 1) { nodes { author { login } } } }
    }
    stackEntry { position }
    stack {
      number baseRefName size
      entries(first: 50) {
        nodes {
          position
          pullRequest {
            id number title url state isDraft headRefName baseRefName reviewDecision mergeStateStatus
            author { login }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            reviewRequests(first: 1) { totalCount }
            latestReviews(first: 1) { totalCount }
          }
        }
      }
    }
    """

  private static let fields = """
    \(summaryFields)
    \(connectionFields)
    """
}

private struct GraphQLResponse<T: Decodable>: Decodable {
  struct APIError: Decodable { let message: String }
  let data: T?
  let errors: [APIError]?
}

struct PageInfo: Decodable {
  let hasNextPage: Bool
  let endCursor: String?

  func nextCursor() throws -> String? {
    guard hasNextPage else { return nil }
    guard let endCursor, !endCursor.isEmpty else {
      throw MergeportError.message(
        "GitHub pagination returned a missing cursor; the inbox was not updated.")
    }
    return endCursor
  }
}

private struct SearchConnection: Decodable {
  let issueCount: Int
  let pageInfo: PageInfo
  let nodes: [PRNode?]
}

private struct PRConnection: Decodable {
  let pageInfo: PageInfo
  let nodes: [PRNode?]
}

private struct ThreadConnection: Decodable {
  struct Thread: Decodable {
    struct Comments: Decodable {
      struct Comment: Decodable {
        struct Author: Decodable { let login: String }
        let author: Author?
      }
      let nodes: [Comment?]
    }
    let isResolved: Bool
    let comments: Comments?
    var isCopilot: Bool {
      CopilotState.isCopilot(comments?.nodes.first??.author?.login ?? "")
    }
  }
  let pageInfo: PageInfo
  let nodes: [Thread?]

  var unresolved: [Thread] { nodes.compactMap { $0 }.filter { !$0.isResolved } }
}

private struct PRNode: Decodable {
  struct Actor: Decodable {
    let login: String
    let avatarUrl: URL?
  }
  struct Repository: Decodable { let nameWithOwner: String }
  struct ReviewRequests: Decodable {
    struct Request: Decodable {
      struct Reviewer: Decodable { let login: String? }
      let requestedReviewer: Reviewer?
    }
    let nodes: [Request?]
    let pageInfo: PageInfo
  }
  struct Reviews: Decodable {
    struct Info: Decodable { let hasPreviousPage: Bool }
    struct Review: Decodable {
      struct Commit: Decodable { let oid: String }
      let author: Actor?
      let state: String
      let commit: Commit?
    }
    let pageInfo: Info
    let nodes: [Review?]
  }
  struct Commits: Decodable {
    struct Node: Decodable {
      struct Commit: Decodable {
        struct Rollup: Decodable { let state: String }
        let statusCheckRollup: Rollup?
      }
      let commit: Commit
    }
    let nodes: [Node?]
    var rollupState: String? {
      nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
    }
  }
  let id: String
  let number: Int
  let title: String
  let url: URL
  let isDraft: Bool
  let state: String
  let updatedAt: Date
  let additions: Int
  let deletions: Int
  let author: Actor?
  let repository: Repository
  let headRepository: Repository?
  let headRefName: String
  let baseRefName: String
  let headRefOid: String
  let reviewDecision: String?
  /// Absent on inbox list queries. Mergeability for a page of results makes GitHub return HTTP 502.
  let mergeable: String?
  let mergeStateStatus: String?
  let commits: Commits?
  /// Absent on inbox list queries. Those load connections one PR at a time so search does not 502.
  let reviewRequests: ReviewRequests?
  let reviews: Reviews?
  let reviewThreads: ThreadConnection?
  let stackEntry: StackPosition?
  let stack: StackNode?

  struct StackPosition: Decodable { let position: Int }
  struct StackNode: Decodable {
    struct Entries: Decodable {
      struct Entry: Decodable {
        struct Member: Decodable {
          let id: String
          let number: Int
          let title: String
          let url: URL
          let state: String
          let isDraft: Bool
          let headRefName: String
          let baseRefName: String
          let reviewDecision: String?
          let mergeStateStatus: String
          let author: Actor?
          let commits: Commits?
          let reviewRequests: Count?
          let latestReviews: Count?
        }
        struct Count: Decodable { let totalCount: Int }
        let position: Int
        let pullRequest: Member?
      }
      let nodes: [Entry?]
    }
    let number: Int
    let baseRefName: String
    let size: Int
    let entries: Entries
  }

  var stackModel: PRStack? { Self.makeStack(entry: stackEntry, stack: stack) }

  static func makeStack(entry: StackPosition?, stack: StackNode?) -> PRStack? {
    guard let stack, let position = entry?.position else { return nil }
    let entries = stack.entries.nodes.compactMap { $0 }.compactMap { entry -> PRStack.Entry? in
      guard let pr = entry.pullRequest else { return nil }
      return PRStack.Entry(
        id: pr.id, position: entry.position, number: pr.number, title: pr.title, url: pr.url,
        state: pr.state, isDraft: pr.isDraft, head: pr.headRefName, base: pr.baseRefName,
        author: pr.author?.login ?? "ghost", reviewDecision: pr.reviewDecision,
        mergeState: pr.mergeStateStatus,
        checks: CheckState(graphQL: pr.commits?.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state),
        reviewRequests: pr.reviewRequests?.totalCount ?? 0, reviews: pr.latestReviews?.totalCount ?? 0)
    }
    return PRStack(
      number: stack.number, base: stack.baseRefName, size: stack.size, position: position,
      entries: entries)
  }

  var rollupState: String? { commits?.rollupState }

  func listed(viewer: String) -> PullRequest {
    PullRequest(
      id: id, number: number, title: title, repository: repository.nameWithOwner, url: url,
      author: author?.login ?? "ghost", head: headRefName,
      headRepository: headRepository?.nameWithOwner, base: baseRefName,
      updatedAt: updatedAt, isDraft: isDraft, state: state, reviewDecision: reviewDecision,
      mergeable: mergeable ?? "UNKNOWN", mergeState: mergeStateStatus ?? "UNKNOWN",
      checks: CheckState(graphQL: rollupState), additions: additions, deletions: deletions,
      authorAvatarURL: author?.avatarUrl, stack: stackModel)
  }

  func model(
    viewer: String, reviews: Reviews, unresolved: Int, copilotUnresolved: Int, requested: [String],
    mergeable: String, mergeState: String, checks: String?, stack: PRStack?
  ) -> PullRequest {
    let latestCopilot = reviews.nodes.compactMap { $0 }.last {
      CopilotState.isCopilot($0.author?.login ?? "") && $0.state != "PENDING"
        && $0.state != "DISMISSED"
    }
    let copilot: CopilotState
    if requested.contains(where: CopilotState.isCopilot) {
      copilot = .requested
    } else if let latestCopilot {
      copilot = latestCopilot.commit?.oid == headRefOid ? .reviewed : .outdated
    } else {
      copilot = reviews.pageInfo.hasPreviousPage ? .unknown : .notRequested
    }
    return PullRequest(
      id: id, number: number, title: title, repository: repository.nameWithOwner, url: url,
      author: author?.login ?? "ghost", head: headRefName,
      headRepository: headRepository?.nameWithOwner ?? "deleted:\(id)", base: baseRefName,
      updatedAt: updatedAt, isDraft: isDraft, state: state,
      reviewRequested: requested.contains { $0.caseInsensitiveCompare(viewer) == .orderedSame },
      reviewDecision: reviewDecision, mergeable: mergeable, mergeState: mergeState,
      checks: CheckState(graphQL: checks),
      unresolvedThreads: unresolved, unresolvedCopilotThreads: copilotUnresolved, copilot: copilot, additions: additions, deletions: deletions,
      authorAvatarURL: author?.avatarUrl, stack: stack
    )
  }
}

extension GitHubClient {
  public func fileText(repository: String, path: String, commit: String) async throws -> String {
    let name = try RepositoryName.validate(repository)
    guard !path.isEmpty, !commit.isEmpty else {
      throw MergeportError.message("A file path and commit are required to load context.")
    }

    struct Blob: Decodable, Sendable { let text: String?; let isBinary: Bool }
    struct Repo: Decodable, Sendable { let object: Blob? }
    struct Result: Decodable, Sendable { let repository: Repo? }
    let parts = name.split(separator: "/")
    let result: Result = try await query(
      """
      query($owner: String!, $name: String!, $expression: String!) {
        repository(owner: $owner, name: $name) {
          object(expression: $expression) { ... on Blob { text isBinary } }
        }
      }
      """, variables: [
        "owner": .string(String(parts[0])), "name": .string(String(parts[1])),
        "expression": .string("\(commit):\(path)")
      ])
    guard let blob = result.repository?.object else {
      throw MergeportError.message("GitHub could not find this file at the reviewed commit.")
    }
    guard !blob.isBinary, let text = blob.text else {
      throw MergeportError.message("GitHub cannot return text context for this binary or oversized file. Open the file on GitHub.")
    }
    return text
  }

  public func conflictingFiles(repository: String, base: String, head: String) async throws -> [String] {
    try await MergeConflictAnalyzer.shared.files(repository: repository, base: base, head: head, token: token)
  }

  public func reviewDetails(repository: String, number: Int) async throws -> ReviewDetails {
    let name = try RepositoryName.validate(repository)
    guard number > 0 else { throw MergeportError.message("Invalid PR number.") }
    let parts = name.split(separator: "/")
    let meta: NativeMetadata = try await query(
      """
      query($owner: String!, $name: String!, $number: Int!) {
        viewer { login }
        repository(owner: $owner, name: $name) {
          viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
          pullRequest(number: $number) {
            \(Self.fields) baseRefOid body bodyHTML createdAt changedFiles viewerCanUpdate
            commitCount: commits(last: 1) { totalCount }
            sidebarRequests: reviewRequests(first: 50) {
              nodes { requestedReviewer {
                ... on User { login avatarUrl } ... on Bot { login avatarUrl } ... on Team { name combinedSlug }
              } }
            }
            assignees(first: 20) { nodes { login avatarUrl } }
            labels(first: 50) { nodes { name color } }
            milestone { title number }
            participants(first: 50) { nodes { login avatarUrl } }
            viewerSubscription locked
          }
        }
      }
      """,
      variables: [
        "owner": .string(String(parts[0])), "name": .string(String(parts[1])),
        "number": .integer(number),
      ])
    guard let repo = meta.repository, let info = repo.pullRequest else {
      throw MergeportError.message(
        "Cannot access \(name)#\(number). Check GitHub and organization access.")
    }
    let path = "/repos/\(name)/pulls/\(number)"
    async let files: [PullRequestFile] = restPages(path + "/files", limit: 3000)
    async let comments: [RESTComment] = restPages("/repos/\(name)/issues/\(number)/comments")
    async let reviews: [RESTReview] = restPages(path + "/reviews")
    async let timeline: [RESTTimelineEvent] = restPages("/repos/\(name)/issues/\(number)/timeline")
    async let commits: [RESTCommit] = restPages(path + "/commits", limit: 250)
    let prID = info.node.id
    let headOid = info.node.headRefOid
    var sidebar = info.sidebar
    sidebar.canTriage = ["TRIAGE", "WRITE", "MAINTAIN", "ADMIN"].contains(repo.viewerPermission ?? "")
    let sidebarUsers = info.people.compactMap { person in
      person.login.map { RESTUser(login: $0, avatarUrl: person.avatarUrl) }
    }
    async let threads = nativeThreads(prID: prID)
    async let checks = checksResult(repository: name, sha: headOid)
    async let commitInfo = (try? await commitChecks(prID: prID)) ?? [:]
    let node = info.node
    let viewerLogin = meta.viewer.login
    async let pr = hydrate(node, viewer: viewerLogin)
    let (allFiles, allComments, allReviews, allCommits, allThreads, allChecks, status, allEvents) =
      try await (files, comments, reviews, commits, threads, checks, pr, timeline)
    let perCommit = await commitInfo
    let current = try await currentHead(repository: name, number: number)
    guard current == info.node.headRefOid else {
      throw MergeportError.message(
        "The PR changed while its review was loading. Refresh to load a consistent diff.")
    }
    var notices: [String] = []
    let checkList: [PullRequestCheck]
    switch allChecks {
    case .success(let value): checkList = value
    case .failure(let error):
      checkList = []
      notices.append(
        "GitHub could not return checks for this commit (\(error.localizedDescription)). The rest of the PR loaded normally."
      )
    }
    if allFiles.count != info.changedFiles {
      notices.append(
        "GitHub returned \(allFiles.count) of \(info.changedFiles) files (the API limit is 3,000). Open GitHub for the full diff."
      )
    }
    if allCommits.count != info.commitCount.totalCount {
      notices.append(
        "Showing \(allCommits.count) of \(info.commitCount.totalCount) commits. GitHub limits this endpoint to 250."
      )
    }
    let methods: [MergeMethod] = [.squash, .merge, .rebase].filter {
      switch $0 {
      case .squash: repo.squashMergeAllowed
      case .merge: repo.mergeCommitAllowed
      case .rebase: repo.rebaseMergeAllowed
      }
    }
    return ReviewDetails(
      pr: status, viewer: meta.viewer, body: info.body, headSHA: current,
      files: allFiles, comments: allComments.map(\.model), reviews: allReviews.map(\.model),
      threads: allThreads, checks: checkList,
      commits: allCommits.map { commit in
        var model = commit.model
        if let info = perCommit[commit.sha] {
          model.verified = info.verified ?? model.verified
          model.checks = info.checks
        }
        return model
      },
      mergeMethods: methods,
      canUpdate: info.viewerCanUpdate,
      canWrite: ["WRITE", "MAINTAIN", "ADMIN"].contains(repo.viewerPermission ?? ""),
      notices: notices, bodyHTML: info.bodyHTML, createdAt: info.createdAt,
      events: allEvents.compactMap(\.model),
      avatars: Self.avatars(
        restUsers: allComments.map(\.user) + allReviews.map(\.user) + allCommits.map(\.author)
          + allEvents.flatMap { [$0.actor, $0.requestedReviewer] }
          + sidebarUsers,
        comments: allThreads.flatMap(\.comments), pr: status),
      sidebar: sidebar, baseSHA: info.baseRefOid)
  }

  private static func avatars(restUsers: [RESTUser?], comments: [DiscussionComment], pr: PullRequest)
    -> [String: URL]
  {
    var result: [String: URL] = [:]
    if let url = pr.authorAvatarURL { result[ReviewDetails.avatarKey(pr.author)] = url }
    for user in restUsers.compactMap({ $0 }) {
      if let url = user.avatarUrl { result[ReviewDetails.avatarKey(user.login)] = url }
    }
    for comment in comments {
      if let url = comment.authorAvatarURL { result[ReviewDetails.avatarKey(comment.author)] = url }
    }
    return result
  }

  public func submitReview(repository: String, number: Int, draft: ReviewDraft) async throws {
    guard let captured = draft.headSHA, !captured.isEmpty else {
      throw MergeportError.message("Load the PR before submitting a review.")
    }
    try draft.validate(currentHead: captured)
    let head = try await currentHead(repository: repository, number: number)
    try draft.validate(currentHead: head)
    struct Inline: Encodable {
      let path: String
      let body: String
      let line: Int
      let side: String
    }
    struct Input: Encodable {
      let commit_id: String
      let event: String
      let body: String
      let comments: [Inline]
    }
    let payload = Input(
      commit_id: head, event: draft.event.rawValue, body: draft.body,
      comments: draft.comments.map {
        Inline(
          path: $0.anchor.path, body: $0.body,
          line: $0.anchor.line, side: $0.anchor.side.rawValue)
      })
    let _: RESTID = try await rest(
      try prPath(repository, number) + "/reviews", method: "POST",
      body: JSONEncoder().encode(payload))
  }

  public func postComment(repository: String, number: Int, body: String, replyTo: Int? = nil)
    async throws
  {
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MergeportError.message("Write a comment first.")
    }
    let name = try RepositoryName.validate(repository)
    guard number > 0 else { throw MergeportError.message("Invalid PR number.") }
    let path: String
    if let replyTo {
      guard replyTo > 0 else {
        throw MergeportError.message("This review comment cannot be replied to.")
      }
      path = "/repos/\(name)/pulls/\(number)/comments/\(replyTo)/replies"
    } else {
      path = "/repos/\(name)/issues/\(number)/comments"
    }
    let _: RESTID = try await rest(path, method: "POST", body: JSONEncoder().encode(["body": body]))
  }

  public func setThreadResolved(_ id: String, resolved: Bool) async throws {
    guard !id.isEmpty else { throw MergeportError.message("Invalid review thread.") }
    struct Thread: Decodable {
      let id: String
      let isResolved: Bool
    }
    struct Mutation: Decodable { let thread: Thread }
    struct Result: Decodable { let result: Mutation }
    let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
    let result: Result = try await query(
      """
      mutation($id: ID!) { result: \(mutation)(input: {threadId: $id}) { thread { id isResolved } } }
      """, variables: ["id": .string(id)])
    guard result.result.thread.id == id, result.result.thread.isResolved == resolved else {
      throw MergeportError.message("GitHub did not update the thread.")
    }
  }

  public func setDraft(_ prID: String, draft: Bool) async throws {
    guard !prID.isEmpty else { throw MergeportError.message("Invalid PR ID.") }
    struct PR: Decodable { let isDraft: Bool }
    struct Mutation: Decodable { let pullRequest: PR }
    struct Result: Decodable { let result: Mutation }
    let mutation = draft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
    let result: Result = try await query(
      """
      mutation($id: ID!) { result: \(mutation)(input: {pullRequestId: $id}) { pullRequest { isDraft } } }
      """, variables: ["id": .string(prID)])
    guard result.result.pullRequest.isDraft == draft else {
      throw MergeportError.message("GitHub did not update the draft status.")
    }
  }

  /// GitHub's login for requesting a Copilot code review through `botLogins`.
  public static let copilotReviewerLogin = "copilot-pull-request-reviewer"

  /// Requests (or re-requests) reviews without removing existing reviewers.
  public func requestReviews(_ prID: String, logins: [String], teams: [String] = []) async throws {
    guard !prID.isEmpty else { throw MergeportError.message("Invalid PR ID.") }
    let valid = logins.filter {
      $0.range(of: "^[A-Za-z0-9-]+(\\[bot\\])?$", options: .regularExpression) != nil
    }
    let validTeams = teams.filter {
      $0.range(of: "^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    guard !valid.isEmpty || !validTeams.isEmpty, valid.count == logins.count,
      validTeams.count == teams.count
    else {
      throw MergeportError.message("Invalid reviewer login.")
    }
    let bots = valid.filter(ReviewDetails.isBot).map {
      CopilotState.isCopilot($0) ? Self.copilotReviewerLogin : ReviewDetails.avatarKey($0)
    }
    let users = valid.filter { !ReviewDetails.isBot($0) }
    struct Mutation: Decodable { let clientMutationId: String? }
    struct Result: Decodable { let result: Mutation? }
    let _: Result = try await query(
      """
      mutation($id: ID!, $users: [String!], $bots: [String!], $teams: [String!]) {
        result: requestReviewsByLogin(
          input: {pullRequestId: $id, userLogins: $users, botLogins: $bots, teamSlugs: $teams, union: true}
        ) { clientMutationId }
      }
      """,
      variables: [
        "id": .string(prID), "users": .strings(users), "bots": .strings(bots),
        "teams": .strings(validTeams),
      ])
  }

  /// Suggested reviewers first, then everyone who can be assigned in the repository.
  public func reviewerCandidates(repository: String, number: Int) async throws -> [String] {
    let name = try RepositoryName.validate(repository)
    let parts = name.split(separator: "/").map(String.init)
    struct Login: Decodable { let login: String }
    struct Suggestion: Decodable { let reviewer: Login }
    struct PR: Decodable { let suggestedReviewers: [Suggestion?] }
    struct Users: Decodable { let nodes: [Login?] }
    struct Repo: Decodable {
      let pullRequest: PR?
      let assignableUsers: Users
    }
    struct Result: Decodable { let repository: Repo? }
    let result: Result = try await query(
      """
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) { suggestedReviewers { reviewer { login } } }
          assignableUsers(first: 100) { nodes { login } }
        }
      }
      """,
      variables: [
        "owner": .string(parts[0]), "name": .string(parts[1]), "number": .integer(number),
      ])
    let suggested = result.repository?.pullRequest?.suggestedReviewers.compactMap { $0?.reviewer.login } ?? []
    let assignable = result.repository?.assignableUsers.nodes.compactMap { $0?.login } ?? []
    var seen = Set<String>()
    return (suggested + assignable).filter { seen.insert($0.lowercased()).inserted }
  }

  /// Replaces the PR's assignees, labels and/or milestone (`.some(nil)` clears the milestone).
  public func updateIssue(
    repository: String, number: Int, assignees: [String]? = nil, labels: [String]? = nil,
    milestone: Int?? = nil
  ) async throws {
    guard number > 0 else { throw MergeportError.message("Invalid PR number.") }
    let name = try RepositoryName.validate(repository)
    var body: [String: Any] = [:]
    if let assignees { body["assignees"] = assignees }
    if let labels { body["labels"] = labels }
    if let milestone { body["milestone"] = milestone.map { $0 as Any } ?? NSNull() }
    guard !body.isEmpty else { return }
    let _: RESTID = try await rest(
      "/repos/\(name)/issues/\(number)", method: "PATCH",
      body: try JSONSerialization.data(withJSONObject: body))
  }

  public func setSubscribed(_ id: String, subscribed: Bool) async throws {
    guard !id.isEmpty else { throw MergeportError.message("Invalid PR ID.") }
    struct Subscribable: Decodable { let viewerSubscription: String? }
    struct Mutation: Decodable { let subscribable: Subscribable? }
    struct Result: Decodable { let result: Mutation }
    do {
    let _: Result = try await query(
      """
      mutation($id: ID!) {
        result: updateSubscription(input: {subscribableId: $id, state: \(subscribed ? "SUBSCRIBED" : "UNSUBSCRIBED")}) {
          subscribable { viewerSubscription }
        }
      }
      """, variables: ["id": .string(id)])
    } catch let error as MergeportError where error.localizedDescription.contains("notifications") {
      throw MergeportError.message(
        "Mergeport needs notification access for this. Sign out and connect GitHub again to grant it.")
    }
  }

  public func setLocked(_ id: String, locked: Bool) async throws {
    guard !id.isEmpty else { throw MergeportError.message("Invalid PR ID.") }
    struct Lockable: Decodable { let locked: Bool }
    struct Mutation: Decodable { let lockedRecord: Lockable?; let unlockedRecord: Lockable? }
    struct Result: Decodable { let result: Mutation }
    let mutation = locked ? "lockLockable" : "unlockLockable"
    let field = locked ? "lockedRecord" : "unlockedRecord"
    let result: Result = try await query(
      """
      mutation($id: ID!) { result: \(mutation)(input: {lockableId: $id}) { \(field) { locked } } }
      """, variables: ["id": .string(id)])
    guard (result.result.lockedRecord ?? result.result.unlockedRecord)?.locked == locked else {
      throw MergeportError.message("GitHub did not update the conversation lock.")
    }
  }

  public enum SidebarOptionKind: Sendable { case assignees, labels, milestones }

  public func sidebarOptions(repository: String, kind: SidebarOptionKind) async throws
    -> [SidebarOption]
  {
    let parts = try RepositoryName.validate(repository).split(separator: "/").map(String.init)
    struct Login: Decodable { let login: String; let name: String? }
    struct Label: Decodable { let name: String; let color: String; let description: String? }
    struct Milestone: Decodable { let title: String; let number: Int; let description: String? }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T?] }
    struct Repo: Decodable {
      let assignableUsers: Nodes<Login>?
      let labels: Nodes<Label>?
      let milestones: Nodes<Milestone>?
    }
    struct Result: Decodable { let repository: Repo? }
    let field =
      switch kind {
      case .assignees: "assignableUsers(first: 100) { nodes { login name } }"
      case .labels: "labels(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { name color description } }"
      case .milestones: "milestones(first: 100, states: OPEN, orderBy: {field: DUE_DATE, direction: ASC}) { nodes { title number description } }"
      }
    let result: Result = try await query(
      """
      query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(field) } }
      """, variables: ["owner": .string(parts[0]), "name": .string(parts[1])])
    let repo = result.repository
    switch kind {
    case .assignees:
      return repo?.assignableUsers?.nodes.compactMap {
        $0.map { SidebarOption(id: $0.login, title: $0.login, detail: $0.name) }
      } ?? []
    case .labels:
      return repo?.labels?.nodes.compactMap {
        $0.map { SidebarOption(id: $0.name, title: $0.name, detail: $0.description, color: $0.color) }
      } ?? []
    case .milestones:
      return repo?.milestones?.nodes.compactMap {
        $0.map { SidebarOption(id: String($0.number), title: $0.title, detail: $0.description, number: $0.number) }
      } ?? []
    }
  }

  public func merge(repository: String, number: Int, sha: String, method: MergeMethod) async throws
  {
    guard !sha.isEmpty else {
      throw MergeportError.message("Load the PR's current commit before merging.")
    }
    struct Result: Decodable, Sendable {
      let merged: Bool
      let message: String
    }
    let result: Result = try await rest(
      try prPath(repository, number) + "/merge", method: "PUT",
      body: JSONEncoder().encode(["sha": sha, "merge_method": method.rawValue]))
    guard result.merged else {
      throw MergeportError.message("GitHub did not merge the PR: \(result.message)")
    }
  }

  /// Stacked PRs must merge through GitHub's asynchronous merge, which also merges the open PRs below.
  /// Polls until GitHub reports merged, enqueued or failed.
  public func mergeAsync(
    repository: String, number: Int, sha: String, method: MergeMethod,
    pollInterval: Duration = .seconds(2), timeout: Duration = .seconds(300)
  ) async throws -> AsyncMergeOutcome {
    guard !sha.isEmpty else {
      throw MergeportError.message("Load the PR's current commit before merging.")
    }
    let path = try prPath(repository, number) + "/merge-async"
    let (data, status) = try await restResponse(
      path, method: "PUT",
      body: JSONEncoder().encode(["sha": sha, "merge_method": method.rawValue]))
    guard [200, 202, 400, 409].contains(status) else { throw restProblem(status, data) }
    var result = try JSONDecoder().decode(AsyncMergeResult.self, from: data)
    let deadline = ContinuousClock.now + timeout
    while result.status == "pending" {
      guard let uuid = result.details?.uuid, uuid.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
      else { throw MergeportError.message("GitHub accepted the merge but returned no request ID.") }
      guard ContinuousClock.now < deadline else {
        throw MergeportError.message("GitHub is still merging in the background. Refresh in a moment to see the result.")
      }
      try await Task.sleep(for: pollInterval)
      result = try await rest(path + "/" + uuid)
    }
    return try result.outcome()
  }

  private func prPath(_ repository: String, _ number: Int) throws -> String {
    guard number > 0 else { throw MergeportError.message("Invalid PR number.") }
    return "/repos/\(try RepositoryName.validate(repository))/pulls/\(number)"
  }

  private func currentHead(repository: String, number: Int) async throws -> String {
    struct Head: Decodable, Sendable { let sha: String }
    struct PR: Decodable, Sendable { let head: Head }
    let result: PR = try await rest(try prPath(repository, number))
    return result.head.sha
  }

  /// Raw response for endpoints whose non-2xx bodies carry results (async merge).
  private func restResponse(_ path: String, method: String = "GET", body: Data? = nil) async throws
    -> (Data, Int)
  {
    guard let url = URL(string: "https://api.github.com\(path)"), url.host == "api.github.com"
    else {
      throw MergeportError.message("Invalid GitHub API path.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 60
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github.full+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Mergeport/0.1", forHTTPHeaderField: "User-Agent")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MergeportError.message("GitHub returned an invalid response.")
    }
    if http.statusCode == 401 { throw MergeportError.unauthorized }
    return (data, http.statusCode)
  }

  private func restProblem(_ status: Int, _ data: Data) -> MergeportError {
    let problem = try? JSONDecoder().decode(RESTProblem.self, from: data)
    let hint =
      status >= 500
      ? "GitHub had a server error; try again shortly."
      : "Check repository permissions and SSO access."
    return MergeportError.message(
      "GitHub (HTTP \(status)): \(problem?.message ?? "Request failed"). \(hint)")
  }

  private func rest<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil
  ) async throws
    -> T
  {
    let (data, status) = try await restResponse(path, method: method, body: body)
    guard (200..<300).contains(status) else { throw restProblem(status, data) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }

  private func restPages<T: Decodable & Sendable>(_ path: String, limit: Int = .max) async throws
    -> [T]
  {
    var page = 1
    var result: [T] = []
    while result.count < limit {
      let values: [T] = try await rest("\(path)?per_page=100&page=\(page)")
      result += values.prefix(limit - result.count)
      if values.count < 100 { break }
      page += 1
    }
    return result
  }

  private func nativeThreads(prID: String) async throws -> [ReviewThread] {
    struct Node: Decodable { let reviewThreads: NativeThreadConnection }
    struct Result: Decodable { let node: Node? }
    struct CommentsNode: Decodable { let comments: NativeCommentConnection }
    struct CommentsResult: Decodable { let node: CommentsNode? }
    var cursor: String?
    var threads: [ReviewThread] = []
    repeat {
      let page: Result = try await query(
        """
        query($id: ID!, $cursor: String) { node(id: $id) { ... on PullRequest {
          reviewThreads(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes { id path line originalLine startLine originalStartLine diffSide isResolved isOutdated
              viewerCanReply viewerCanResolve viewerCanUnresolve
              opening: comments(first: 1) { nodes { diffHunk pullRequestReview { databaseId } } }
              comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { \(Self.threadCommentFields) } }
            }
          }
        } } }
        """, variables: ["id": .string(prID), "cursor": cursor.map(JSONValue.string) ?? .null])
      guard let connection = page.node?.reviewThreads else {
        throw MergeportError.message("Cannot load PR review threads.")
      }
      for thread in connection.nodes {
        var comments = thread.comments.nodes
        var after = try thread.comments.pageInfo.nextCursor()
        while let next = after {
          let more: CommentsResult = try await query(
            """
            query($id: ID!, $cursor: String!) { node(id: $id) { ... on PullRequestReviewThread {
              comments(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { \(Self.threadCommentFields) } }
            } } }
            """, variables: ["id": .string(thread.id), "cursor": .string(next)])
          guard let list = more.node?.comments else {
            throw MergeportError.message("Cannot load the remaining thread replies.")
          }
          comments += list.nodes
          after = try list.pageInfo.nextCursor()
        }
        threads.append(
          ReviewThread(
            id: thread.id, path: thread.path, line: thread.line ?? thread.originalLine,
            isResolved: thread.isResolved, isOutdated: thread.isOutdated,
            canReply: thread.viewerCanReply,
            canResolve: thread.viewerCanResolve, canUnresolve: thread.viewerCanUnresolve,
            comments: comments.map(\.model),
            startLine: thread.line == nil ? thread.originalStartLine : thread.startLine,
            isLeftSide: thread.diffSide == "LEFT",
            diffHunk: thread.opening?.nodes.first?.diffHunk,
            reviewID: thread.opening?.nodes.first?.pullRequestReview?.databaseId))
      }
      cursor = try connection.pageInfo.nextCursor()
    } while cursor != nil
    return threads
  }

  private static let threadCommentFields =
    "id databaseId body bodyHTML createdAt url author { login avatarUrl }"

  private func checksResult(repository: String, sha: String) async -> Result<
    [PullRequestCheck], Error
  > {
    do { return .success(try await nativeChecks(repository: repository, sha: sha)) } catch {
      return .failure(error)
    }
  }

  /// Uses GraphQL's status check rollup: REST check-runs/status endpoints can return HTTP 500
  /// for commits that GraphQL serves fine.
  public func checks(repository: String, sha: String) async throws -> [PullRequestCheck] {
    try await nativeChecks(repository: repository, sha: sha)
  }

  private func nativeChecks(repository: String, sha: String) async throws -> [PullRequestCheck] {
    struct Contexts: Decodable {
      let pageInfo: PageInfo
      let nodes: [CheckContext?]
    }
    struct Rollup: Decodable { let contexts: Contexts }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Repository: Decodable { let object: Commit? }
    struct Result: Decodable { let repository: Repository? }
    let parts = repository.split(separator: "/")
    var contexts_: [CheckContext] = []
    var cursor: String?
    repeat {
      var variables: [String: JSONValue] = [
        "owner": .string(String(parts[0])), "name": .string(String(parts[1])), "oid": .string(sha),
      ]
      if let cursor { variables["cursor"] = .string(cursor) }
      let result: Result = try await query(
        """
        query($owner: String!, $name: String!, $oid: GitObjectID!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            object(oid: $oid) { ... on Commit { statusCheckRollup {
              contexts(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes { \(CheckContext.fields) }
              }
            } } }
          }
        }
        """, variables: variables)
      guard let contexts = result.repository?.object?.statusCheckRollup?.contexts else { break }
      contexts_ += contexts.nodes.compactMap { $0 }
      cursor = try contexts.pageInfo.nextCursor()
    } while cursor != nil
    return CheckContext.latest(contexts_)
  }

  /// Signature verification and the checks of every commit, for the commit rows' badges and popovers.
  private func commitChecks(prID: String) async throws -> [String: (verified: Bool?, checks: [PullRequestCheck])] {
    struct Signature: Decodable { let isValid: Bool }
    struct Contexts: Decodable { let nodes: [CheckContext?] }
    struct Rollup: Decodable { let contexts: Contexts }
    struct Commit: Decodable {
      let oid: String
      let signature: Signature?
      let statusCheckRollup: Rollup?
    }
    struct Node: Decodable { let commit: Commit }
    struct Commits: Decodable { let nodes: [Node?] }
    struct PR: Decodable { let commits: Commits? }
    struct Result: Decodable { let node: PR? }
    let result: Result = try await query(
      """
      query($id: ID!) {
        node(id: $id) { ... on PullRequest { commits(last: 100) { nodes { commit {
          oid signature { isValid }
          statusCheckRollup { contexts(first: 50) { nodes { \(CheckContext.fields) } } }
        } } } } }
      }
      """, variables: ["id": .string(prID)])
    var map: [String: (verified: Bool?, checks: [PullRequestCheck])] = [:]
    for node in result.node?.commits?.nodes.compactMap({ $0 }) ?? [] {
      map[node.commit.oid] = (
        node.commit.signature?.isValid,
        CheckContext.latest(node.commit.statusCheckRollup?.contexts.nodes.compactMap { $0 } ?? [])
      )
    }
    return map
  }
}

private struct CheckContext: Decodable {
  static let fields = """
    ... on CheckRun { databaseId name status conclusion detailsUrl startedAt completedAt title
      checkSuite { workflowRun { event workflow { name } } } }
    ... on StatusContext { id context state targetUrl description createdAt }
    """
  struct Workflow: Decodable { let name: String }
  struct Run: Decodable {
    let event: String?
    let workflow: Workflow?
  }
  struct Suite: Decodable { let workflowRun: Run? }
  let databaseId: Int?
  let name: String?
  let status: String?
  let conclusion: String?
  let detailsUrl: URL?
  let startedAt: Date?
  let completedAt: Date?
  let title: String?
  let checkSuite: Suite?
  let id: String?
  let context: String?
  let state: String?
  let targetUrl: URL?
  let description: String?
  let createdAt: Date?

  /// A commit keeps every workflow run: each push, ready-for-review or review event adds another.
  /// Like GitHub's merge box, show only the newest run of each job per workflow and event.
  static func latest(_ contexts: [CheckContext]) -> [PullRequestCheck] {
    var newest: [String: CheckContext] = [:]
    var order: [String] = []
    for context in contexts {
      guard let name = context.name else {
        let key = "status-\(context.context ?? context.id ?? "")"
        if newest[key] == nil { order.append(key) }
        newest[key] = context
        continue
      }
      let run = context.checkSuite?.workflowRun
      let key = "check-\(run?.workflow?.name ?? "")\u{1F}\(name)\u{1F}\(run?.event ?? "")"
      if let existing = newest[key] {
        if (context.databaseId ?? 0) > (existing.databaseId ?? 0) { newest[key] = context }
      } else {
        order.append(key)
        newest[key] = context
      }
    }
    return order.compactMap { newest[$0]?.model }
  }

  var model: PullRequestCheck? {
    if let name {
      let run = checkSuite?.workflowRun
      // GraphQL reports a running job's status, not a conclusion; only completed jobs have one.
      let state = (status?.uppercased() == "COMPLETED" ? conclusion : status) ?? conclusion ?? "pending"
      return PullRequestCheck(
        id: "check-\(databaseId.map(String.init) ?? name)", name: name, state: state.lowercased(),
        url: detailsUrl, workflow: run?.workflow?.name, event: run?.event,
        startedAt: startedAt, completedAt: status?.uppercased() == "COMPLETED" ? completedAt : nil,
        summary: title)
    }
    guard let context else { return nil }
    return PullRequestCheck(
      id: "status-\(id ?? context)", name: context, state: (state ?? "pending").lowercased(),
      url: targetUrl, completedAt: createdAt, summary: description)
  }
}

private struct NativeMetadata: Decodable {
  struct Repository: Decodable {
    let viewerPermission: String?
    let mergeCommitAllowed: Bool
    let squashMergeAllowed: Bool
    let rebaseMergeAllowed: Bool
    let pullRequest: Info?
  }
  struct Info: Decodable {
    struct Count: Decodable { let totalCount: Int }
    let node: PRNode
    let body: String
    let baseRefOid: String?
    let changedFiles: Int
    let viewerCanUpdate: Bool
    let commitCount: Count
    let bodyHTML: String?
    let createdAt: Date?
    struct Person: Decodable {
      let login: String?
      let avatarUrl: URL?
      let name: String?
      let combinedSlug: String?
    }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T?] }
    struct Request: Decodable { let requestedReviewer: Person? }
    struct Label: Decodable {
      let name: String
      let color: String
    }
    struct Milestone: Decodable {
      let title: String
      let number: Int?
    }
    let viewerSubscription: String?
    let locked: Bool?
    let sidebarRequests: Nodes<Request>?
    let assignees: Nodes<Person>?
    let labels: Nodes<Label>?
    let milestone: Milestone?
    let participants: Nodes<Person>?
    enum CodingKeys: String, CodingKey {
      case body, baseRefOid, bodyHTML, createdAt, changedFiles, viewerCanUpdate, commitCount
      case sidebarRequests, assignees, labels, milestone, participants
      case viewerSubscription, locked
    }
    var people: [Person] {
      (sidebarRequests?.nodes.compactMap { $0?.requestedReviewer } ?? [])
        + (assignees?.nodes.compactMap { $0 } ?? []) + (participants?.nodes.compactMap { $0 } ?? [])
    }
    var sidebar: PullRequestSidebar {
      let reviewers = sidebarRequests?.nodes.compactMap { $0?.requestedReviewer } ?? []
      return PullRequestSidebar(
        requestedReviewers: reviewers.compactMap(\.login),
        requestedTeams: reviewers.filter { $0.login == nil }.compactMap(\.name),
        requestedTeamSlugs: reviewers.filter { $0.login == nil }.compactMap(\.combinedSlug),
        assignees: assignees?.nodes.compactMap { $0?.login } ?? [],
        labels: labels?.nodes.compactMap { $0.map { PullRequestLabel(name: $0.name, color: $0.color) } }
          ?? [],
        milestone: milestone?.title, milestoneNumber: milestone?.number,
        participants: participants?.nodes.compactMap { $0?.login } ?? [],
        subscription: viewerSubscription, locked: locked ?? false)
    }
    init(from decoder: Decoder) throws {
      node = try PRNode(from: decoder)
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      body = try fields.decode(String.self, forKey: .body)
      baseRefOid = try fields.decodeIfPresent(String.self, forKey: .baseRefOid)
      bodyHTML = try fields.decodeIfPresent(String.self, forKey: .bodyHTML)
      createdAt = try fields.decodeIfPresent(Date.self, forKey: .createdAt)
      changedFiles = try fields.decode(Int.self, forKey: .changedFiles)
      viewerCanUpdate = try fields.decode(Bool.self, forKey: .viewerCanUpdate)
      commitCount = try fields.decode(Count.self, forKey: .commitCount)
      sidebarRequests = try fields.decodeIfPresent(Nodes<Request>.self, forKey: .sidebarRequests)
      assignees = try fields.decodeIfPresent(Nodes<Person>.self, forKey: .assignees)
      labels = try fields.decodeIfPresent(Nodes<Label>.self, forKey: .labels)
      milestone = try fields.decodeIfPresent(Milestone.self, forKey: .milestone)
      participants = try fields.decodeIfPresent(Nodes<Person>.self, forKey: .participants)
      viewerSubscription = try fields.decodeIfPresent(String.self, forKey: .viewerSubscription)
      locked = try fields.decodeIfPresent(Bool.self, forKey: .locked)
    }
  }
  let viewer: Viewer
  let repository: Repository?
}
private struct NativeThreadConnection: Decodable {
  let pageInfo: PageInfo
  let nodes: [NativeThread]
}
private struct NativeThread: Decodable {
  let id: String
  let path: String
  let line: Int?
  let originalLine: Int?
  let isResolved: Bool
  let isOutdated: Bool
  let viewerCanReply: Bool
  let viewerCanResolve: Bool
  let viewerCanUnresolve: Bool
  let startLine: Int?
  let originalStartLine: Int?
  let diffSide: String?
  let comments: NativeCommentConnection
  let opening: Opening?

  struct Opening: Decodable {
    struct Node: Decodable {
      struct Review: Decodable { let databaseId: Int? }
      let diffHunk: String?
      let pullRequestReview: Review?
    }
    let nodes: [Node]
  }
}
private struct NativeCommentConnection: Decodable {
  let pageInfo: PageInfo
  let nodes: [NativeComment]
}
private struct NativeComment: Decodable {
  struct Author: Decodable {
    let login: String
    let avatarUrl: URL?
  }
  let id: String
  let databaseId: Int?
  let body: String
  let createdAt: Date
  let url: URL
  let author: Author?
  let bodyHTML: String?
  var model: DiscussionComment {
    DiscussionComment(
      id: id, databaseID: databaseId, author: author?.login ?? "ghost", body: body, date: createdAt,
      url: url,
      bodyHTML: bodyHTML, authorAvatarURL: author?.avatarUrl)
  }
}
private struct RESTID: Decodable, Sendable { let id: Int }
private struct RESTProblem: Decodable { let message: String }
private struct RESTUser: Decodable, Sendable {
  let login: String
  let avatarUrl: URL?
}
private struct RESTComment: Decodable, Sendable {
  let id: Int
  let body: String
  let createdAt: Date
  let htmlUrl: URL
  let user: RESTUser?
  let bodyHtml: String?
  var model: DiscussionComment {
    DiscussionComment(
      id: "issue-\(id)", databaseID: id, author: user?.login ?? "ghost", body: body,
      date: createdAt, url: htmlUrl,
      bodyHTML: bodyHtml
    )
  }
}
private struct RESTReview: Decodable, Sendable {
  let id: Int
  let body: String
  let state: String
  let submittedAt: Date?
  let user: RESTUser?
  let bodyHtml: String?
  var model: SubmittedReview {
    SubmittedReview(
      id: id, author: user?.login ?? "ghost", body: body, state: state, date: submittedAt,
      bodyHTML: bodyHtml)
  }
}
private struct RESTTimelineEvent: Decodable, Sendable {
  struct Label: Decodable, Sendable { let name: String }
  struct Rename: Decodable, Sendable {
    let from: String
    let to: String
  }
  struct Source: Decodable, Sendable {
    struct Issue: Decodable, Sendable {
      struct PullRequest: Decodable, Sendable { let mergedAt: Date? }
      struct Repository: Decodable, Sendable { let fullName: String }
      let title: String
      let number: Int
      let htmlUrl: URL
      let state: String
      let draft: Bool?
      let pullRequest: PullRequest?
      let repository: Repository?

      var reference: ConversationEvent.Reference {
        let referenceState: ConversationEvent.Reference.State =
          pullRequest?.mergedAt != nil
          ? .merged
          : state == "closed" ? .closed : draft == true ? .draft : .open
        return .init(
          title: title, number: number, repository: repository?.fullName, url: htmlUrl,
          state: referenceState, isPullRequest: pullRequest != nil)
      }
    }
    let issue: Issue?
  }
  let id: Int?
  let event: String
  let actor: RESTUser?
  let createdAt: Date?
  let requestedReviewer: RESTUser?
  let requestedTeam: Label?
  let label: Label?
  let rename: Rename?
  let source: Source?
  let commitId: String?
  let commitUrl: URL?

  var model: ConversationEvent? {
    guard let createdAt else { return nil }
    let action: String
    let symbol: String
    switch event {
    case "commented", "reviewed", "committed": return nil
    case "review_requested":
      action =
        "requested review from \(requestedReviewer.map { ReviewDetails.displayName($0.login) } ?? requestedTeam?.name ?? "a reviewer")"
      symbol = "eye"
    case "review_request_removed":
      action =
        "removed a review request for \(requestedReviewer.map { ReviewDetails.displayName($0.login) } ?? requestedTeam?.name ?? "a reviewer")"
      symbol = "eye.slash"
    case "ready_for_review":
      action = "marked this PR ready for review"
      symbol = "eye"
    case "convert_to_draft":
      action = "converted this PR to draft"
      symbol = "pencil"
    case "merged":
      action = "merged this PR"
      symbol = "arrow.triangle.merge"
    case "closed":
      action = "closed this PR"
      symbol = "xmark.circle"
    case "reopened":
      action = "reopened this PR"
      symbol = "arrow.counterclockwise"
    case "labeled":
      action = "added the \(label?.name ?? "") label"
      symbol = "tag"
    case "unlabeled":
      action = "removed the \(label?.name ?? "") label"
      symbol = "tag"
    case "renamed":
      action = "renamed this PR from “\(rename?.from ?? "")” to “\(rename?.to ?? "")”"
      symbol = "pencil"
    case "cross-referenced":
      action = "referenced this PR"
      symbol = "link"
    case "head_ref_force_pushed":
      action = "force-pushed the source branch"
      symbol = "arrow.up"
    case "head_ref_deleted":
      action = "deleted the source branch"
      symbol = "trash"
    case "head_ref_restored":
      action = "restored the source branch"
      symbol = "arrow.counterclockwise"
    default:
      action = event.replacingOccurrences(of: "_", with: " ")
      symbol = "circle"
    }
    return ConversationEvent(
      id: id.map(String.init) ?? "\(event)-\(createdAt.timeIntervalSince1970)-\(commitId ?? "")",
      actor: actor?.login ?? "GitHub", action: action, date: createdAt, symbol: symbol,
      url: source?.issue?.htmlUrl,
      title: source?.issue.map { "\($0.title) #\($0.number) · \($0.state)" },
      reference: event == "cross-referenced" ? source?.issue?.reference : nil)
  }
}
private struct RESTCommit: Decodable, Sendable {
  struct Commit: Decodable, Sendable {
    struct Author: Decodable, Sendable {
      let name: String
      let date: Date
    }
    struct Verification: Decodable, Sendable { let verified: Bool }
    let message: String
    let author: Author
    let verification: Verification?
  }
  let sha: String
  let htmlUrl: URL
  let commit: Commit
  let author: RESTUser?
  var model: PullRequestCommit {
    PullRequestCommit(
      id: sha, message: commit.message, author: author?.login ?? commit.author.name,
      date: commit.author.date, url: htmlUrl, verified: commit.verification?.verified)
  }
}

struct AsyncMergeResult: Decodable, Sendable {
  struct Details: Decodable, Sendable {
    let uuid: String?
    let message: String?
  }
  let status: String
  let details: Details?

  func outcome() throws -> AsyncMergeOutcome {
    switch status {
    case "merged": return .merged
    case "enqueued": return .enqueued
    case "failed":
      throw MergeportError.message("GitHub did not merge the PR: \(details?.message ?? "the merge failed").")
    default:
      throw MergeportError.message("GitHub returned an unexpected merge status: \(status).")
    }
  }
}
