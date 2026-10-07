import CryptoKit
import Foundation

/// The Linear issue behind a ticket identifier such as `CON-108`.
public struct LinearIssue: Codable, Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let url: URL
  public let state: String
  /// Linear's workflow category: triage, backlog, unstarted, started, completed or canceled.
  public let stateType: String
  public let stateColor: String?

  public init(
    identifier: String, title: String, url: URL, state: String, stateType: String,
    stateColor: String? = nil
  ) {
    self.identifier = identifier
    self.title = title
    self.url = url
    self.state = state
    self.stateType = stateType
    self.stateColor = stateColor
  }
}

public struct LinearToken: Codable, Equatable, Sendable {
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date

  public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }

  public func needsRefresh(now: Date = .now) -> Bool {
    refreshToken != nil && expiresAt.timeIntervalSince(now) < 300
  }
}

public struct LinearViewer: Codable, Equatable, Sendable {
  public let name: String
  public let workspace: String
}

/// Linear OAuth with PKCE, so the app ships only a public client ID.
public struct LinearOAuth: Sendable {
  public static let bundleInfoKey = "MergeportLinearClientID"
  public static let callbackPort: UInt16 = 47_389
  public static let callbackPath = "/linear/callback"
  public static var redirectURI: String { "http://127.0.0.1:\(callbackPort)\(callbackPath)" }

  public let clientID: String
  private let session: URLSession
  private let tokenURL = URL(string: "https://api.linear.app/oauth/token")!

  public init(clientID: String, session: URLSession = .shared) {
    self.clientID = clientID
    self.session = session
  }

  public static func verifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
  }

  public static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  public func authorizeURL(state: String, verifier: String) -> URL {
    var components = URLComponents(string: "https://linear.app/oauth/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "read"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.url!
  }

  public func exchange(code: String, verifier: String) async throws -> LinearToken {
    try await token([
      "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
      "client_id": clientID, "code_verifier": verifier,
    ])
  }

  public func refresh(_ current: LinearToken) async throws -> LinearToken {
    guard let refreshToken = current.refreshToken else { return current }
    return try await token([
      "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
    ])
  }

  public func revoke(_ token: LinearToken) async {
    var request = URLRequest(url: URL(string: "https://api.linear.app/oauth/revoke")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.form(["token": token.refreshToken ?? token.accessToken])
    _ = try? await session.data(for: request)
  }

  private func token(_ fields: [String: String]) async throws -> LinearToken {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Self.form(fields)
    let (data, response) = try await session.data(for: request)
    struct Response: Decodable {
      let access_token: String?
      let refresh_token: String?
      let expires_in: Double?
      let error: String?
      let error_description: String?
    }
    let decoded = try? JSONDecoder().decode(Response.self, from: data)
    guard (response as? HTTPURLResponse)?.statusCode == 200, let access = decoded?.access_token
    else {
      let reason = decoded?.error_description ?? decoded?.error ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
      throw MergeportError.message("Linear sign-in failed: \(reason)")
    }
    return LinearToken(
      accessToken: access, refreshToken: decoded?.refresh_token,
      expiresAt: .now.addingTimeInterval(decoded?.expires_in ?? 86_399))
  }

  static func form(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(
      fields.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .joined(separator: "&").utf8)
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

public struct LinearClient: Sendable {
  private let token: String
  private let session: URLSession
  private let endpoint = URL(string: "https://api.linear.app/graphql")!

  public init(token: String, session: URLSession = .shared) {
    self.token = token
    self.session = session
  }

  public func viewer() async throws -> LinearViewer {
    struct Data: Decodable {
      struct Viewer: Decodable {
        let name: String
        let organization: Organization
      }
      struct Organization: Decodable { let name: String }
      let viewer: Viewer
    }
    let data: Data = try await query("query { viewer { name organization { name } } }")
    return LinearViewer(name: data.viewer.name, workspace: data.viewer.organization.name)
  }

  /// Looks up identifiers like `CON-108` in one request per 100 tickets. Unknown identifiers are omitted.
  public func issues(_ identifiers: Set<String>) async throws -> [String: LinearIssue] {
    let parsed = Set(identifiers.map { $0.uppercased() }).compactMap(Self.parse).sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
    var result: [String: LinearIssue] = [:]
    var start = 0
    while start < parsed.count {
      let chunk = parsed[start..<min(start + 100, parsed.count)]
      start += 100
      let byTeam = Dictionary(grouping: chunk, by: \.0)
      let filter: [String: Any] = [
        "or": byTeam.keys.sorted().map { team in
          ["team": ["key": ["eq": team]], "number": ["in": byTeam[team]!.map(\.1)]] as [String: Any]
        }
      ]
      let data: IssuesData = try await query(
        "query Issues($filter: IssueFilter!) { issues(filter: $filter, first: 250) { nodes { identifier title url state { name type color } } } }",
        variables: ["filter": filter])
      for node in data.issues.nodes {
        result[node.identifier.uppercased()] = LinearIssue(
          identifier: node.identifier, title: node.title, url: node.url,
          state: node.state?.name ?? "", stateType: node.state?.type ?? "", stateColor: node.state?.color)
      }
    }
    return result
  }

  static func parse(_ identifier: String) -> (String, Int)? {
    guard let dash = identifier.lastIndex(of: "-"), let number = Int(identifier[identifier.index(after: dash)...]),
      dash > identifier.startIndex
    else { return nil }
    return (String(identifier[..<dash]), number)
  }

  private func query<T: Decodable>(_ query: String, variables: [String: Any] = [:]) async throws -> T {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw LinearError.unauthorized }
    let envelope = try JSONDecoder().decode(LinearEnvelope<T>.self, from: data)
    if let errors = envelope.errors, !errors.isEmpty {
      if errors.contains(where: { $0.message.localizedCaseInsensitiveContains("authenticat") }) {
        throw LinearError.unauthorized
      }
      throw MergeportError.message("Linear: " + errors.map(\.message).joined(separator: "\n"))
    }
    guard let value = envelope.data else { throw MergeportError.message("Linear returned no data (HTTP \(status)).") }
    return value
  }
}

private struct LinearEnvelope<T: Decodable>: Decodable {
  struct APIError: Decodable { let message: String }
  let data: T?
  let errors: [APIError]?
}

private struct IssuesData: Decodable {
  struct Issues: Decodable { let nodes: [Node] }
  struct Node: Decodable {
    struct State: Decodable { let name: String; let type: String; let color: String? }
    let identifier: String
    let title: String
    let url: URL
    let state: State?
  }
  let issues: Issues
}

public enum LinearError: LocalizedError, Sendable {
  case unauthorized
  public var errorDescription: String? { "Linear authorization expired or was revoked. Connect Linear again in Settings." }
}

public enum DemoLinear {
  public static let issues: [String: LinearIssue] = {
    func issue(_ id: String, _ title: String, _ state: String, _ type: String, _ color: String) -> LinearIssue {
      LinearIssue(
        identifier: id, title: title, url: URL(string: "https://linear.app/acme/issue/\(id.lowercased())")!,
        state: state, stateType: type, stateColor: color)
    }
    let list = [
      issue("CON-108", "Email delivery via the Rust service", "In Progress", "started", "#f2c94c"),
      issue("CON-171", "Streaming Pub/Sub ingestion", "In Review", "started", "#0f783c"),
      issue("CON-200", "Deployment history is lost after rollback", "In Progress", "started", "#f2c94c"),
      issue("CON-205", "Tenant routing and audit trail", "Todo", "unstarted", "#e2e2e2"),
      issue("CON-215", "Workload identity for scheduled jobs", "Done", "completed", "#5e6ad2"),
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.identifier, $0) })
  }()
}
