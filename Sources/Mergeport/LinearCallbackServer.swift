import Foundation
import MergeportCore
import Network

/// Receives Linear's OAuth redirect on 127.0.0.1 (RFC 8252 loopback redirect).
final class LinearCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.wouter.mergeport.linear-callback")
    private var continuation: CheckedContinuation<String, Error>?
    private let expectedState: String

    init(state: String) throws {
        expectedState = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LinearOAuth.callbackPort)!)
        parameters.allowLocalEndpointReuse = true
        do { listener = try NWListener(using: parameters) } catch {
            throw MergeportError.message("Could not listen for the Linear sign-in callback on port \(LinearOAuth.callbackPort): \(error.localizedDescription)")
        }
    }

    /// Waits for the browser redirect and returns the authorization code.
    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.listener.newConnectionHandler = { self.handle($0) }
                    self.listener.stateUpdateHandler = { state in
                        if case .failed(let error) = state {
                            self.finish(.failure(MergeportError.message("Linear sign-in callback failed: \(error.localizedDescription)")))
                        }
                    }
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            guard components?.path == LinearOAuth.callbackPath else {
                self.respond(connection, status: "404 Not Found", message: "Not found.")
                return
            }
            let items = components?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let result: Result<String, Error>
            if value("state") != self.expectedState {
                result = .failure(MergeportError.message("Linear sign-in returned an unexpected state. Try again."))
            } else if let code = value("code"), !code.isEmpty {
                result = .success(code)
            } else {
                result = .failure(MergeportError.message("Linear authorization was declined\(value("error").map { " (\($0))" } ?? "")."))
            }
            switch result {
            case .success:
                self.respond(connection, status: "200 OK", message: "Linear is connected to Mergeport. You can close this tab.")
            case .failure(let error):
                self.respond(connection, status: "400 Bad Request", message: error.localizedDescription)
            }
            self.finish(result)
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let body = """
        <!doctype html><meta charset="utf-8"><title>Mergeport</title>
        <body style="font: 16px -apple-system, sans-serif; display: grid; place-items: center; height: 90vh; color: #333">
        <p>\(escaped)</p></body>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        // Clearing the handlers breaks the listener → handler → self cycle.
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        continuation.resume(with: result)
    }
}
