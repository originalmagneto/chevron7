// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Identity
import Chevron7Kit
import Chevron7WebBridge
import os

/// Publishes the Mach service the Safari web extension handler connects to.
///
/// The handler is sandboxed and can do nothing useful on its own, so everything
/// it receives from a state portal arrives here. The anonymous endpoint is handed
/// out only by the agent, but any process of the same user could otherwise reach
/// it, so the listener admits only the extension (and `webbridge-probe`) by code
/// signing requirement, and talks only to the agent it expects
/// (`WebBridgeCodeRequirement`).
final class WebBridgeListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = WebBridgeListener()

    private let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "web-bridge")
    private var listener: NSXPCListener?
    private var rendezvous: NSXPCConnection?
    private let lock = NSLock()
    private var signHandler: (@Sendable (WebSignRequest) async throws -> WebSignResponse)?
    private let jobs = WebSignJobStore()

    /// Installs the handler that turns a portal request into a real signature.
    /// Kept injectable so the transport can be exercised without the signing UI.
    func setSignHandler(_ handler: @escaping @Sendable (WebSignRequest) async throws -> WebSignResponse) {
        lock.lock()
        defer { lock.unlock() }
        signHandler = handler
    }

    /// Publishes an anonymous listener and registers it with the launchd agent.
    ///
    /// launchd owns the Mach service name and only hands it to the process it
    /// launches, so the app cannot claim it directly. It publishes an anonymous
    /// endpoint instead and leaves the name to the agent.
    func start() {
        guard listener == nil else { return }
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(
            WebBridgeCodeRequirement.requirement(for: WebBridgeCallerRole.endpointClient.peers))
        listener.delegate = self
        listener.resume()
        self.listener = listener

        let connection = NSXPCConnection(machServiceName: WebSigningBridge.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: WebBridgeRendezvousProtocol.self)
        // Whoever holds the name gets our endpoint, so it must be our agent.
        connection.setCodeSigningRequirement(WebBridgeCodeRequirement.requirement(for: [.agent]))
        connection.resume()
        self.rendezvous = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [log] error in
            log.error("Web bridge agent unreachable: \(error.localizedDescription, privacy: .public)")
        }) as? WebBridgeRendezvousProtocol else {
            log.error("Web bridge agent proxy unavailable")
            return
        }
        proxy.registerApp(endpoint: listener.endpoint)
        log.info("Web bridge registered with \(WebSigningBridge.machServiceName, privacy: .public)")
    }

    func stop() {
        rendezvous?.invalidate()
        rendezvous = nil
        listener?.invalidate()
        listener = nil
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WebSigningBridgeProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

/// Carries the XPC reply closure into the signing task. NSXPC guarantees the
/// reply is invoked at most once, which this type does not itself enforce.
private final class ReplyBox: @unchecked Sendable {
    let value: (Data?, String?) -> Void

    init(_ value: @escaping (Data?, String?) -> Void) {
        self.value = value
    }
}

extension WebBridgeListener: WebSigningBridgeProtocol {
    func status(reply: @escaping (Bool, String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "dev"
        lock.lock()
        let ready = signHandler != nil
        lock.unlock()
        reply(ready, version)
    }

    func sign(request: Data, reply: @escaping (Data?, String?) -> Void) {
        let decoded: (handler: @Sendable (WebSignRequest) async throws -> WebSignResponse, request: WebSignRequest)
        switch accept(request) {
        case .success(let accepted): decoded = accepted
        case .failure(let message):
            reply(nil, message.text)
            return
        }

        // NSXPC hands back a plain closure; the signing work is async, so it is
        // carried across the task boundary explicitly.
        let sendableReply = ReplyBox(reply)
        Task {
            do {
                let response = try await decoded.handler(decoded.request)
                sendableReply.value(try JSONEncoder().encode(response), nil)
            } catch {
                sendableReply.value(nil, error.localizedDescription)
            }
        }
    }

    func beginSign(request: Data, reply: @escaping (String?, String?) -> Void) {
        let decoded: (handler: @Sendable (WebSignRequest) async throws -> WebSignResponse, request: WebSignRequest)
        switch accept(request) {
        case .success(let accepted): decoded = accepted
        case .failure(let message):
            reply(nil, message.text)
            return
        }

        let jobID = jobs.begin()
        let jobs = self.jobs
        Task {
            do {
                let response = try await decoded.handler(decoded.request)
                jobs.finish(jobID, response: try JSONEncoder().encode(response), error: nil)
            } catch {
                jobs.finish(jobID, response: nil, error: error.localizedDescription,
                            cancelled: WebSigningCoordinator.isCancellation(error))
            }
        }
        reply(jobID, nil)
    }

    func signResult(jobID: String, reply: @escaping (Bool, Data?, String?, Bool) -> Void) {
        switch jobs.take(jobID) {
        case .pending:
            reply(false, nil, nil, false)
        case .finished(let response, let error, let cancelled):
            reply(true, response, error, cancelled)
        case .unknown:
            reply(true, nil, "Požiadavka na podpis sa v aplikácii Chevron7 nenašla. Skúste podpísať znova.", false)
        }
    }

    private struct RejectedRequest: Error {
        let text: String
    }

    /// Decodes a request from the extension and pairs it with the installed handler.
    private func accept(_ request: Data)
        -> Result<(handler: @Sendable (WebSignRequest) async throws -> WebSignResponse, request: WebSignRequest), RejectedRequest> {
        lock.lock()
        let handler = signHandler
        lock.unlock()

        guard let handler else {
            return .failure(RejectedRequest(text: "Podpisovanie z prehliadača zatiaľ nie je v tejto zostave zapojené."))
        }

        do {
            return .success((handler, try JSONDecoder().decode(WebSignRequest.self, from: request)))
        } catch {
            // The detail goes back to the page on purpose: without it a wire
            // format mismatch looks the same as a corrupt document, and the
            // console is the only place this is ever debugged.
            let detail: String
            if let decoding = error as? DecodingError, case let .keyNotFound(key, _) = decoding {
                detail = "chýba pole \(key.stringValue)"
            } else if let decoding = error as? DecodingError, case let .typeMismatch(_, context) = decoding {
                detail = "nesprávny typ poľa \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } else {
                detail = String(describing: error)
            }
            log.error("Rejected a malformed web sign request: \(String(describing: error), privacy: .public)")
            return .failure(RejectedRequest(text: "Požiadavka na podpis je poškodená: \(detail)"))
        }
    }
}
