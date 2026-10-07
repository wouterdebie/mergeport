import Foundation
import Testing

@testable import MergeportCore

struct LinearTests {
  @Test func pkceChallengeMatchesRFC7636() {
    #expect(
      LinearOAuth.challenge(for: "dBjftJeZ4CVP-mJ92IqhTbbg6Cf2N1EZ7A5ZwRHMfas")
        == "DOLm_T-qSoMwXCOtXb0Mrtn35b3whsc0KMyI95tC3Kk")
  }

  @Test func verifiersAreRandomAndURLSafe() {
    let one = LinearOAuth.verifier(), two = LinearOAuth.verifier()
    #expect(one != two)
    #expect(one.count >= 43)
    #expect(one.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
  }

  @Test func authorizeURLRequestsReadScopeWithS256() throws {
    let url = LinearOAuth(clientID: "client").authorizeURL(state: "s", verifier: "v")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let value = { (name: String) in items.first { $0.name == name }?.value }
    #expect(url.host == "linear.app")
    #expect(value("scope") == "read")
    #expect(value("code_challenge_method") == "S256")
    #expect(value("code_challenge") == LinearOAuth.challenge(for: "v"))
    #expect(value("redirect_uri") == "http://127.0.0.1:47389/linear/callback")
    #expect(value("state") == "s")
  }

  @Test func tokensRefreshShortlyBeforeExpiry() {
    let now = Date()
    #expect(LinearToken(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(60)).needsRefresh(now: now))
    #expect(!LinearToken(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600)).needsRefresh(now: now))
    #expect(!LinearToken(accessToken: "a", refreshToken: nil, expiresAt: now).needsRefresh(now: now))
  }

  @Test func identifiersParseTeamAndNumber() {
    #expect(LinearClient.parse("CON-108")! == ("CON", 108))
    #expect(LinearClient.parse("MY-TEAM-7")! == ("MY-TEAM", 7))
    #expect(LinearClient.parse("CON-") == nil)
    #expect(LinearClient.parse("-5") == nil)
  }
}
