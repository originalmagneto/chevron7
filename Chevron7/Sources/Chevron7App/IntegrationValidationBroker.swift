// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit
import Chevron7Integration

/// All app users of the engine's single validation session share this queue. A cancelled
/// caller waits for its own operation to finish before another operation can use the session.
@MainActor
final class IntegrationValidationBroker {
    static let shared = IntegrationValidationBroker()
    private var active = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let maximumWaiting: Int

    init(maximumWaiting: Int = 8) { self.maximumWaiting = maximumWaiting }

    func run<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let task = Task { try await operation() }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    func validate(provider: any QualifiedSigningProviding, in url: URL) async -> SignatureTreeResult {
        do { return try await run { await provider.validateSignatureTree(in: url) } }
        catch { return .failed(error.localizedDescription) }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard active else { active = true; return }
        guard waiting.count < maximumWaiting else {
            throw IntegrationError(code: "BUSY", message: "Overovanie podpisov je zaneprázdnené. Skúste to neskôr.", retryable: true)
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiting.firstIndex(where: { $0.0 == id }) else { return }
                self.waiting.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }

    private func release() {
        if waiting.isEmpty { active = false }
        else { waiting.removeFirst().1.resume() }
    }
}
