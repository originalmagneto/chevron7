// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Signing jobs the browser extension polls.
///
/// Safari ends a web extension's background after about 30 seconds and then
/// answers `runtime.sendMessage` with `undefined`. A signature waits for a PIN or
/// a phone far longer, so one native message that waits for the result loses it.
/// The page starts a job instead and asks for the result with short messages.
public final class WebSignJobStore: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case pending
        case finished(response: Data?, error: String?)
        case unknown
    }

    private struct Job {
        var state: State
        var finishedAt: Date?
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let lifetime: TimeInterval
    private let clock: @Sendable () -> Date

    /// - Parameter lifetime: how long a finished result nobody collected is kept.
    public init(lifetime: TimeInterval = 15 * 60, clock: @escaping @Sendable () -> Date = Date.init) {
        self.lifetime = lifetime
        self.clock = clock
    }

    /// Registers a new pending job and returns its identifier.
    public func begin() -> String {
        let id = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        purgeExpired()
        jobs[id] = Job(state: .pending, finishedAt: nil)
        return id
    }

    public func finish(_ id: String, response: Data?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard jobs[id] != nil else { return }
        jobs[id] = Job(state: .finished(response: response, error: error), finishedAt: clock())
    }

    /// The job's state. A finished job is removed as it is read, so the result
    /// reaches the page once.
    public func take(_ id: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { return .unknown }
        if case .finished = job.state {
            jobs[id] = nil
        }
        return job.state
    }

    private func purgeExpired() {
        let now = clock()
        jobs = jobs.filter { _, job in
            guard let finishedAt = job.finishedAt else { return true }
            return now.timeIntervalSince(finishedAt) <= lifetime
        }
    }
}
