// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Lets one request at a time reach the on-device model, first come first served.
///
/// The model answers requests one after another anyway: with four pages asking at
/// once every crop took 7 to 9 s instead of 2.5 s in a row (Mac Studio, 2026-10-12),
/// so crops waiting behind others ran into the per-crop limit although the total
/// time did not improve. Queueing here lets each crop's limit start only once the
/// model is free for it.
public actor FoundationModelGate {
    /// The model is one resource for the whole process.
    public static let shared = FoundationModelGate()

    /// A model that has not answered for this long may have been unloaded and
    /// pay its start-up cost again (8.7 s for the first crop of a run).
    static let coldAfterSeconds: Double = 120

    public struct Lease: Sendable {
        let id: UInt64
        /// True when the model has not answered recently, so it may still be loading.
        public let isCold: Bool
    }

    private var holder: UInt64?
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var lastAnswer: Date?

    public init() {}

    /// Waits until the model is free and holds it until `release`.
    public func acquire() async -> Lease {
        nextID += 1
        let id = nextID
        if holder == nil {
            holder = id
        } else {
            // `release` hands the model over by making this waiter the holder.
            await withCheckedContinuation { waiters.append((id, $0)) }
        }
        let isCold = lastAnswer.map { Date().timeIntervalSince($0) > Self.coldAfterSeconds } ?? true
        return Lease(id: id, isCold: isCold)
    }

    /// Hands the model to the next waiter. Releasing a lease that no longer holds
    /// the model does nothing, so the judge finishing and the cap expiring may both
    /// release the same lease. `answered` records that the model is warm.
    public func release(_ lease: Lease, answered: Bool) {
        guard holder == lease.id else { return }
        if answered { lastAnswer = Date() }
        if waiters.isEmpty {
            holder = nil
        } else {
            let next = waiters.removeFirst()
            holder = next.id
            next.continuation.resume()
        }
    }
}
