import AppKit
import MergeportCore

extension AppModel {
    var isLinearConnected: Bool { linearToken != nil }

    func linearIssue(for pr: PullRequest) -> LinearIssue? {
        ticket(for: pr).flatMap { linearIssues[$0] }
    }

    func loadLinear() {
        do {
            guard let stored = try TokenVault.read(account: TokenVault.linear) else { linearToken = nil; return }
            linearToken = try JSONDecoder().decode(LinearToken.self, from: Data(stored.utf8))
            if let data = UserDefaults.standard.data(forKey: "linearCache") {
                let cache = try JSONDecoder().decode(LinearCache.self, from: data)
                linearIssues = cache.issues
                linearViewer = cache.viewer
            }
        } catch {
            linearError = error.localizedDescription
        }
    }

    func connectLinear() {
        guard !isConnectingLinear else { return }
        guard let clientID = linearClientID else {
            linearError = "Linear sign-in is not configured in this build."
            return
        }
        isConnectingLinear = true
        linearError = nil
        linearAuthTask = Task {
            defer { isConnectingLinear = false; linearAuthTask = nil }
            do {
                let oauth = LinearOAuth(clientID: clientID, session: networkSession)
                let state = LinearOAuth.verifier(), verifier = LinearOAuth.verifier()
                let server = try LinearCallbackServer(state: state)
                async let code = server.code()
                openExternal(oauth.authorizeURL(state: state, verifier: verifier))
                let token = try await oauth.exchange(code: try await code, verifier: verifier)
                let viewer = try await LinearClient(token: token.accessToken, session: networkSession).viewer()
                try Task.checkCancellation()
                try storeLinear(token)
                linearViewer = viewer
                NSApp.activate()
                refreshLinear()
            } catch is CancellationError {
                return
            } catch {
                linearError = error.localizedDescription
            }
        }
    }

    func cancelLinearConnect() {
        linearAuthTask?.cancel()
    }

    func disconnectLinear() {
        linearAuthTask?.cancel()
        linearRefreshTask?.cancel()
        if let token = linearToken, let clientID = linearClientID {
            let oauth = LinearOAuth(clientID: clientID, session: networkSession)
            Task { await oauth.revoke(token) }
        }
        try? TokenVault.delete(account: TokenVault.linear)
        UserDefaults.standard.removeObject(forKey: "linearCache")
        linearToken = nil
        linearViewer = nil
        linearIssues = [:]
        linearError = nil
    }

    /// Fetches Linear issues for every ticket identifier in the inbox and open tabs.
    func refreshLinear() {
        guard !isDemo, linearToken != nil else { return }
        let tickets = Set((pullRequests + tabs.map(\.pr)).compactMap { ticket(for: $0) })
        guard !tickets.isEmpty else { return }
        linearRefreshTask?.cancel()
        linearRefreshTask = Task {
            do {
                let token = try await validLinearToken()
                let client = LinearClient(token: token, session: networkSession)
                let issues = try await client.issues(tickets)
                let viewer = linearViewer == nil ? try? await client.viewer() : linearViewer
                try Task.checkCancellation()
                guard linearToken != nil else { return }
                linearIssues = issues
                linearViewer = viewer
                linearError = nil
                if let data = try? JSONEncoder().encode(LinearCache(issues: issues, viewer: viewer)) {
                    UserDefaults.standard.set(data, forKey: "linearCache")
                }
            } catch is CancellationError {
                return
            } catch let error as LinearError {
                linearError = error.localizedDescription
            } catch {
                guard !(error is URLError) else { return }
                linearError = error.localizedDescription
            }
        }
    }

    private func validLinearToken() async throws -> String {
        guard let token = linearToken else { throw LinearError.unauthorized }
        guard token.needsRefresh(), let clientID = linearClientID else { return token.accessToken }
        do {
            let fresh = try await LinearOAuth(clientID: clientID, session: networkSession).refresh(token)
            try storeLinear(fresh)
            return fresh.accessToken
        } catch let error as MergeportError {
            NSLog("Mergeport Linear refresh: %@", error.localizedDescription)
            throw LinearError.unauthorized
        }
    }

    private func storeLinear(_ token: LinearToken) throws {
        let data = try JSONEncoder().encode(token)
        try TokenVault.save(String(decoding: data, as: UTF8.self), account: TokenVault.linear)
        linearToken = token
    }
}

private struct LinearCache: Codable {
    let issues: [String: LinearIssue]
    let viewer: LinearViewer?
}
