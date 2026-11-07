// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7WebBridge

/// Each call owns its connections and completion latch. A transport failure never retries a mutation.
public struct IntegrationClient: Sendable {
    public init() {}

    public func execute(_ request: IntegrationRequest, timeout: TimeInterval = 120) async throws -> IntegrationResponse {
        try request.validate()
        let data = try JSONEncoder().encode(request)
        guard data.count <= IntegrationLimits.maximumRequestBytes else { throw IntegrationError(code: "PAYLOAD_TOO_LARGE", message: "The request exceeds the integration limit.") }
        let call = IntegrationCall(request: request, data: data)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.start(continuation, timeout: timeout)
            }
        } onCancel: {
            call.finish(.failure(IntegrationError(code: "OUTCOME_UNKNOWN", message: "The request was interrupted. Check its job before retrying.", retryable: false)))
        }
    }
}

/// NSXPC callbacks may race timeout, cancellation and each other. The lock guards only ownership;
/// continuations and XPC invalidation run outside it, including cancellation before start.
private final class IntegrationCall: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IntegrationResponse, any Error>?
    private var outcome: Result<IntegrationResponse, any Error>?
    private var connections: [NSXPCConnection] = []
    private var dispatched = false
    private let request: IntegrationRequest
    private let data: Data

    init(request: IntegrationRequest, data: Data) { self.request = request; self.data = data }

    func start(_ continuation: CheckedContinuation<IntegrationResponse, any Error>, timeout: TimeInterval) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
        self.continuation = continuation
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.fail(code: "TIMEOUT", message: "Chevron7 did not answer before the deadline. No signing request was retried.")
        }
        let agent = NSXPCConnection(machServiceName: WebSigningBridge.machServiceName, options: [])
        agent.remoteObjectInterface = NSXPCInterface(with: WebBridgeRendezvousProtocol.self)
        agent.setCodeSigningRequirement(WebBridgeCodeRequirement.requirement(for: [.agent]))
        guard retain(agent) else { return }
        agent.resume()
        guard let proxy = agent.remoteObjectProxyWithErrorHandler({ [self] _ in
            fail(code: "BRIDGE_UNAVAILABLE", message: "The Chevron7 background connection is unavailable. Open Chevron7 and enable its connection in Settings.")
        }) as? WebBridgeRendezvousProtocol else {
            fail(code: "BRIDGE_UNAVAILABLE", message: "Cannot connect to the Chevron7 background service."); return
        }
        proxy.appEndpoint { [self] endpoint in
            guard let endpoint else { fail(code: "APP_UNAVAILABLE", message: "Chevron7 could not be started. Open the installed application and try again."); return }
            connect(endpoint)
        }
    }

    private func retain(_ connection: NSXPCConnection) -> Bool {
        lock.lock()
        guard outcome == nil else { lock.unlock(); connection.invalidate(); return false }
        connections.append(connection)
        lock.unlock()
        return true
    }

    private func connect(_ endpoint: NSXPCListenerEndpoint) {
        let app = NSXPCConnection(listenerEndpoint: endpoint)
        app.remoteObjectInterface = NSXPCInterface(with: IntegrationBridgeProtocol.self)
        app.setCodeSigningRequirement(WebBridgeCodeRequirement.requirement(for: [.app]))
        guard retain(app) else { return }
        app.resume()
        guard let proxy = app.remoteObjectProxyWithErrorHandler({ [self] _ in
            fail(code: "APP_UNAVAILABLE", message: "The integration connection ended. Check that the installed Chevron7 supports API version 1; do not repeat an uncertain signature.")
        }) as? IntegrationBridgeProtocol else {
            fail(code: "INCOMPATIBLE_VERSION", message: "This Chevron7 installation does not offer the integration interface."); return
        }
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        dispatched = true
        lock.unlock()
        proxy.execute(request: data) { [self] data in
            do {
                let response = try JSONDecoder().decode(IntegrationResponse.self, from: data)
                guard response.apiVersion == 1, response.requestId == request.requestId else {
                    fail(code: "INCOMPATIBLE_VERSION", message: "The app returned an incompatible response."); return
                }
                guard response.ok ? (response.result != nil && response.error == nil) : (response.result == nil && response.error != nil) else {
                    fail(code: "INVALID_RESPONSE", message: "The app returned an inconsistent response envelope."); return
                }
                finish(.success(response))
            } catch { fail(code: "INVALID_RESPONSE", message: "The app returned an unreadable response. No signing request was retried.") }
        }
    }

    private func fail(code: String, message: String) {
        lock.lock()
        let uncertain = dispatched && ["sign", "jobs.save", "jobs.cancel"].contains(request.method)
        lock.unlock()
        finish(.failure(IntegrationError(code: uncertain ? "OUTCOME_UNKNOWN" : code, message: message)))
    }

    func finish(_ result: Result<IntegrationResponse, any Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let connections = connections
        self.connections = []
        lock.unlock()
        continuation?.resume(with: result)
        connections.forEach { $0.invalidate() }
    }
}
