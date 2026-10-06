// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7WebBridge

#if canImport(SafariServices)
import SafariServices
#endif

/// Safari web extension handler.
///
/// Safari runs this sandboxed, so it can neither spawn the signing engine nor
/// reach the card. It is a relay and nothing else: it forwards the extension's
/// native message to the app over the Mach service the app publishes, and hands
/// the answer back.
@objc(Chevron7WebExtensionHandler)
final class Chevron7WebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]

        forward(message: message) { reply in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func forward(message: Any?, completion: @escaping ([String: Any]) -> Void) {
        guard let message = message as? [String: Any],
              let kind = message["kind"] as? String else {
            completion(["ok": false, "error": "Neplatná správa z rozšírenia."])
            return
        }

        // The sandbox forbids looking up an arbitrary Mach service, but the
        // temporary-exception entitlement covers this one name. What comes back
        // is an anonymous endpoint, and connecting to that involves no name
        // lookup at all.
        let agent = NSXPCConnection(machServiceName: WebSigningBridge.machServiceName, options: [])
        agent.remoteObjectInterface = NSXPCInterface(with: WebBridgeRendezvousProtocol.self)
        // Documents go only to Chevron7: the name must be held by our agent and
        // the endpoint it hands back must belong to the app, or the connection
        // is invalidated and the page hears that Chevron7 is unavailable.
        agent.setCodeSigningRequirement(WebBridgeCodeRequirement.requirement(for: [.agent]))
        agent.resume()

        // Only one reply may ever be delivered: the sandbox turns a missing app
        // into an interruption rather than an error, so both paths land here.
        let replied = Replied()
        let unavailable = ["ok": false, "error": "Chevron7 nebeží alebo nie je dostupný."] as [String: Any]
        var appConnection: NSXPCConnection?
        let finish: ([String: Any]) -> Void = { payload in
            guard replied.claim() else { return }
            appConnection?.invalidate()
            agent.invalidate()
            completion(payload)
        }

        agent.interruptionHandler = { finish(unavailable) }
        agent.invalidationHandler = { finish(unavailable) }

        guard let rendezvous = agent.remoteObjectProxyWithErrorHandler({ error in
            finish(["ok": false, "error": "Služba aplikácie Chevron7 nie je dostupná: \(error.localizedDescription)"])
        }) as? WebBridgeRendezvousProtocol else {
            finish(unavailable)
            return
        }

        rendezvous.appEndpoint { endpoint in
            guard let endpoint else {
                finish(unavailable)
                return
            }
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: WebSigningBridgeProtocol.self)
            connection.setCodeSigningRequirement(WebBridgeCodeRequirement.requirement(for: [.app]))
            connection.resume()
            appConnection = connection
            connection.interruptionHandler = { finish(unavailable) }
            connection.invalidationHandler = { finish(unavailable) }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(["ok": false, "error": "Spojenie s aplikáciou Chevron7 zlyhalo: \(error.localizedDescription)"])
            }) as? WebSigningBridgeProtocol else {
                finish(unavailable)
                return
            }
            Self.dispatch(kind: kind, message: message, proxy: proxy, finish: finish)
        }
    }

    private static func dispatch(kind: String, message: [String: Any],
                                 proxy: WebSigningBridgeProtocol,
                                 finish: @escaping ([String: Any]) -> Void) {
        switch kind {
        case "status":
            proxy.status { ready, version in
                finish(["ok": true, "ready": ready, "version": version])
            }
        case "sign":
            guard let requestJSON = message["request"] as? String,
                  let data = requestJSON.data(using: .utf8) else {
                finish(["ok": false, "error": "Požiadavka na podpis je poškodená."])
                return
            }
            proxy.sign(request: data) { response, error in
                if let error {
                    finish(WebSigningBridge.failureReply(error: error))
                    return
                }
                guard let response, let text = String(data: response, encoding: .utf8) else {
                    finish(["ok": false, "error": "Chevron7 vrátil prázdnu odpoveď."])
                    return
                }
                finish(["ok": true, "response": text])
            }
        case "sign-begin":
            guard let requestJSON = message["request"] as? String,
                  let data = requestJSON.data(using: .utf8) else {
                finish(["ok": false, "error": "Požiadavka na podpis je poškodená."])
                return
            }
            proxy.beginSign(request: data) { jobID, error in
                guard let jobID else {
                    finish(["ok": false, "error": error ?? "Chevron7 požiadavku na podpis neprijal."])
                    return
                }
                finish(["ok": true, "jobID": jobID])
            }
        case "sign-result":
            guard let jobID = message["request"] as? String, !jobID.isEmpty else {
                finish(["ok": false, "error": "Chýba identifikátor podpisovania."])
                return
            }
            proxy.signResult(jobID: jobID) { done, response, error in
                guard done else {
                    finish(["ok": true, "done": false])
                    return
                }
                if let error {
                    finish(WebSigningBridge.failureReply(error: error, done: true))
                    return
                }
                guard let response, let text = String(data: response, encoding: .utf8) else {
                    finish(["ok": false, "done": true, "error": "Chevron7 vrátil prázdnu odpoveď."])
                    return
                }
                finish(["ok": true, "done": true, "response": text])
            }
        default:
            finish(["ok": false, "error": "Neznámy typ správy: \(kind)"])
        }
    }
}

/// Guards the single-reply rule across the XPC handlers, which can fire on
/// different queues.
private final class Replied: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// The appex entry point lives in Foundation but is not surfaced to Swift, so it
// is declared directly. Xcode templates get this from the NSExtensionMain
// linker flag; a SwiftPM-built extension has to ask for it by name.
@_silgen_name("NSExtensionMain")
func NSExtensionMain() -> Int32

exit(NSExtensionMain())
