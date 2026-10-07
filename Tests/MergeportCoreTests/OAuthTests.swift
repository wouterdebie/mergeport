import Foundation
@testable import MergeportCore
import Testing

struct OAuthTests {
    private func response(_ json: String) throws -> OAuthTokenResponse {
        try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(json.utf8))
    }

    @Test func normalUsersUseBundledOAuthApp() throws {
        let configuration = GitHubOAuthConfiguration(bundledClientID: " bundled-client \n")
        #expect(try configuration.requireClientID() == "bundled-client")
        #expect(!configuration.usesCustomApp)
    }

    @Test func customAppOverridesBundledApp() throws {
        let configuration = GitHubOAuthConfiguration(bundledClientID: "bundled-client", customClientID: " custom-client ")
        #expect(try configuration.requireClientID() == "custom-client")
        #expect(configuration.usesCustomApp)
    }

    @Test func clearingCustomAppRestoresBundledIntegration() throws {
        let configuration = GitHubOAuthConfiguration(bundledClientID: "bundled-client", customClientID: " \n")
        #expect(try configuration.requireClientID() == "bundled-client")
        #expect(!configuration.usesCustomApp)
    }

    @Test func developerOverrideWorksWithoutBundledClientID() throws {
        let configuration = GitHubOAuthConfiguration(bundledClientID: nil, customClientID: "custom-client")
        #expect(try configuration.requireClientID() == "custom-client")
    }

    @Test(arguments: [nil, "", " \n"] as [String?])
    func missingIntegrationFailsExplicitly(_ clientID: String?) {
        let configuration = GitHubOAuthConfiguration(bundledClientID: clientID)
        #expect(configuration.clientID == nil)
        #expect(throws: MergeportError.self) { try configuration.requireClientID() }
    }

    @Test func pollingHonorsPendingAndSlowDown() throws {
        #expect(try response(#"{"error":"authorization_pending"}"#).outcome(currentInterval: 5) == .pending(5))
        #expect(try response(#"{"error":"slow_down"}"#).outcome(currentInterval: 5) == .pending(10))
        #expect(try response(#"{"error":"slow_down","interval":20}"#).outcome(currentInterval: 5) == .pending(20))
        #expect(try response(#"{"access_token":"fixture-token"}"#).outcome(currentInterval: 5) == .authorized("fixture-token"))
    }

    @Test(arguments: ["access_denied", "expired_token", "incorrect_client_credentials", "device_flow_disabled", "unknown"])
    func oauthFailuresAreExplicit(_ error: String) throws {
        let result = try response("{\"error\":\"\(error)\"}")
        #expect(throws: (any Error).self) { try result.outcome(currentInterval: 5) }
    }

    @Test func emptyTokenIsNotSuccessful() throws {
        let result = try response(#"{"access_token":""}"#)
        #expect(throws: (any Error).self) { try result.outcome(currentInterval: 5) }
    }

    @Test func formEncodingDoesNotAllowInjectedParameters() {
        let encoded = String(decoding: GitHubOAuth.formBody(["scope": "repo read:org", "client_id": "x&scope=admin"]), as: UTF8.self)
        #expect(encoded == "client_id=x%26scope%3Dadmin&scope=repo%20read%3Aorg")
    }

    @Test func malformedPaginationFailsInsteadOfTruncating() throws {
        let info = try JSONDecoder().decode(PageInfo.self, from: Data(#"{"hasNextPage":true,"endCursor":null}"#.utf8))
        #expect(throws: (any Error).self) { try info.nextCursor() }
    }
}
