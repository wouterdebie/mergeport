import Foundation

public struct GitHubOAuthConfiguration: Sendable {
    public static let bundleInfoKey = "MergeportGitHubClientID"
    public let clientID: String?
    public let usesCustomApp: Bool

    public init(bundledClientID: String?, customClientID: String? = nil) {
        let custom = Self.nonEmpty(customClientID)
        clientID = custom ?? Self.nonEmpty(bundledClientID)
        usesCustomApp = custom != nil
    }

    public func requireClientID() throws -> String {
        guard let clientID else {
            throw MergeportError.message("GitHub sign-in is not configured in this build. Use a configured Mergeport build, or set a custom OAuth app in Settings > Advanced.")
        }
        return clientID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct DeviceCode: Decodable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case expiresIn = "expires_in", interval
    }
}

public struct OAuthTokenResponse: Decodable, Sendable {
    public let accessToken: String?
    public let error: String?
    public let errorDescription: String?
    public let interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", error, errorDescription = "error_description", interval
    }

    public enum Outcome: Equatable, Sendable {
        case authorized(String), pending(Int)
    }

    public func outcome(currentInterval: Int) throws -> Outcome {
        if let accessToken, !accessToken.isEmpty { return .authorized(accessToken) }
        switch error {
        case "authorization_pending": return .pending(currentInterval)
        case "slow_down": return .pending(max(currentInterval + 5, interval ?? 0))
        case "access_denied": throw MergeportError.message("GitHub authorization was declined.")
        case "expired_token": throw MergeportError.message("The sign-in code expired. Start sign-in again.")
        case "incorrect_client_credentials":
            throw MergeportError.message("GitHub rejected this app's sign-in configuration. Try an updated build, or check a custom OAuth app in Settings > Advanced.")
        case "device_flow_disabled":
            throw MergeportError.message("GitHub sign-in is unavailable for this OAuth app. The app owner must enable device flow in its GitHub settings.")
        default: throw MergeportError.message(errorDescription ?? "GitHub returned an invalid OAuth response.")
        }
    }
}

public struct GitHubOAuth: Sendable {
    private let session: URLSession

    private enum CodeResponse: Decodable {
        case code(DeviceCode), failure(OAuthTokenResponse)
        private enum CodingKeys: String, CodingKey { case error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.error) { self = .failure(try OAuthTokenResponse(from: decoder)) }
            else { self = .code(try DeviceCode(from: decoder)) }
        }
    }

    public init(session: URLSession = .shared) { self.session = session }

    public static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    public func requestCode(clientID: String) async throws -> DeviceCode {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MergeportError.message("GitHub sign-in is not configured for this build.")
        }
        let response: CodeResponse = try await post(path: "device/code", values: [
            "client_id": clientID, "scope": "repo read:org notifications"
        ])
        guard case .code(let code) = response else {
            if case .failure(let problem) = response { _ = try problem.outcome(currentInterval: 5) }
            throw MergeportError.message("GitHub did not return a sign-in code. Check the OAuth app's device flow settings.")
        }
        guard GitHubNavigation.isGitHubPage(code.verificationURI), code.expiresIn > 0, code.interval > 0 else {
            throw MergeportError.message("GitHub returned invalid device authorization details.")
        }
        return code
    }

    public func waitForToken(clientID: String, code: DeviceCode) async throws -> String {
        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = code.interval
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            guard Date.now < deadline else { break }
            let response: OAuthTokenResponse = try await post(path: "oauth/access_token", values: [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            switch try response.outcome(currentInterval: interval) {
            case .authorized(let token): return token
            case .pending(let seconds): interval = seconds
            }
        }
        throw MergeportError.message("The sign-in code expired. Start sign-in again.")
    }

    private func post<T: Decodable>(path: String, values: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com/login/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(values)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MergeportError.message("GitHub sign-in could not be reached. Check your connection and try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
