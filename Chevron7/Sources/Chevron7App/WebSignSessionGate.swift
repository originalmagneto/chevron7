// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// The one web signing request the panel serves, and the only one its result may reach.
///
/// A signature outlives the panel: closing it cancels the page's request at once,
/// while the engine (or the phone) keeps working on it. The page can then send a
/// new request, and the old signature finishing late must not answer that one.
/// The page's own request IDs cannot tell them apart (schranka.slovensko.sk sends
/// "Signature-1" every time), so each opened request gets its own token, and every
/// step that awaits checks it is still the current one before it writes anything.
@MainActor
final class WebSignSessionGate<Response: Sendable> {
    private var current: (token: UUID, continuation: CheckedContinuation<Response, Error>)?

    var isOpen: Bool { current != nil }

    /// The token of the open request, captured by a step before it awaits.
    var currentToken: UUID? { current?.token }

    /// Opens a request. Returns nil when one is already open.
    func open(_ continuation: CheckedContinuation<Response, Error>) -> UUID? {
        guard current == nil else { return nil }
        let token = UUID()
        current = (token, continuation)
        return token
    }

    func isCurrent(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return current?.token == token
    }

    /// Answers the request `token` opened, and only that one.
    /// - Returns: false when it was already answered or another request is open.
    @discardableResult
    func close(_ token: UUID?, with result: Result<Response, Error>) -> Bool {
        guard let current, isCurrent(token) else { return false }
        self.current = nil
        current.continuation.resume(with: result)
        return true
    }
}
