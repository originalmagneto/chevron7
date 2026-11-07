import Foundation
import Darwin

public enum IntegrationJobState: String, Codable, Sendable {
    case awaitingConfirmation, signing, completed, cancelled, failed, outcomeUnknown
    public var isTerminal: Bool {
        switch self {
        case .awaitingConfirmation, .signing: false
        case .completed, .cancelled, .failed, .outcomeUnknown: true
        }
    }
}

public struct IntegrationJob: Sendable, Equatable {
    public let id: String
    public fileprivate(set) var state: IntegrationJobState
    public fileprivate(set) var result: JSONValue?
    public fileprivate(set) var error: IntegrationError?
    public let createdAt: Date
    public fileprivate(set) var finishedAt: Date?

    /// Session capabilities and idempotency fingerprints never leave the store.
    public var json: JSONValue {
        var fields: [String: JSONValue] = ["jobId": .string(id), "state": .string(state.rawValue),
            "createdAt": .string(createdAt.ISO8601Format()), "done": .bool(state.isTerminal)]
        if let finishedAt { fields["finishedAt"] = .string(finishedAt.ISO8601Format()) }
        if let result { fields["result"] = result }
        if let error { fields["error"] = error.json }
        return .object(fields)
    }
}

/// App-owned metadata and bounded reservations. Document bytes stay in private files.
/// All mutations are synchronous under one lock, so cancellation and a late engine
/// completion cannot both claim to be the terminal result.
public final class IntegrationJobStore: @unchecked Sendable {
    private struct Entry {
        let owner: String
        let key: String?
        let fingerprint: String
        var reservedBytes: Int
        var job: IntegrationJob
    }

    private struct Expired {
        let id: String
        let owner: String
    }

    private let root: URL
    private let maxJobs: Int
    private let maxBytes: Int
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var expired: [Expired] = []

    public init(directory: URL, maxJobs: Int = IntegrationLimits.maximumJobs,
                maxBytes: Int = IntegrationLimits.maximumRetainedBytes,
                ttl: TimeInterval = IntegrationLimits.jobLifetime,
                clock: @escaping @Sendable () -> Date = Date.init) throws {
        guard maxJobs > 0, maxBytes > 0, ttl >= 0 else {
            throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Invalid integration retention limits.")
        }
        root = directory.standardizedFileURL
        self.maxJobs = maxJobs
        self.maxBytes = maxBytes
        self.ttl = ttl
        self.clock = clock
        var info = stat()
        if lstat(root.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw IntegrationError(code: "FILE_ACCESS", message: "Integration storage is not a private owned directory.")
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        guard chmod(root.path, 0o700) == 0 else {
            throw IntegrationError(code: "FILE_ACCESS", message: "Cannot secure integration storage.")
        }
        // App calls this once at startup before accepting requests. Prior metadata
        // cannot be recovered after restart; old bytes must not imply any outcome.
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard url.lastPathComponent.hasPrefix("job-"),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(4))) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    public func begin(owner: String, key: String? = nil, fingerprint: String,
                      reservedBytes: Int = IntegrationLimits.maximumOutputBytes) throws -> (job: IntegrationJob, isNew: Bool) {
        try lock.withLock {
            purgeLocked()
            guard !owner.isEmpty, owner.utf8.count <= 256, !fingerprint.isEmpty,
                  key == nil || (!(key?.isEmpty ?? true) && (key?.utf8.count ?? 0) <= 256),
                  reservedBytes >= 0, reservedBytes <= maxBytes else {
                throw IntegrationError(code: "INVALID_ARGUMENTS", message: "Invalid job identity or byte reservation.")
            }
            if let key, let previous = entries.values.first(where: { $0.owner == owner && $0.key == key }) {
                guard previous.fingerprint == fingerprint else {
                    throw IntegrationError(code: "IDEMPOTENCY_CONFLICT", message: "This request key already describes different signing inputs.")
                }
                return (previous.job, false)
            }
            let used = entries.values.reduce(0) { $0 + $1.reservedBytes }
            guard entries.count < maxJobs, reservedBytes <= maxBytes - used else {
                throw IntegrationError(code: "CAPACITY_EXCEEDED", message: "Integration result storage is full. Retained jobs expire after 30 minutes.", retryable: true)
            }
            let id = UUID().uuidString
            let directory = directoryURL(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let job = IntegrationJob(id: id, state: .awaitingConfirmation, result: nil, error: nil,
                                     createdAt: clock(), finishedAt: nil)
            entries[id] = Entry(owner: owner, key: key, fingerprint: fingerprint, reservedBytes: reservedBytes, job: job)
            return (job, true)
        }
    }

    public func get(id: String, owner: String) throws -> IntegrationJob {
        try lock.withLock {
            purgeLocked()
            return try entry(id: id, owner: owner).job
        }
    }

    /// Terminal transitions win once. Delivery-only recovery uses recordDelivery,
    /// so a duplicate engine completion cannot rewrite an existing result.
    @discardableResult
    public func update(id: String, owner: String, state: IntegrationJobState,
                       result: JSONValue? = nil, error: IntegrationError? = nil) throws -> IntegrationJob {
        try lock.withLock {
            purgeLocked()
            var value = try entry(id: id, owner: owner)
            if value.job.state.isTerminal { return value.job }
            if value.job.state == .signing, state == .awaitingConfirmation { return value.job }
            if state.isTerminal {
                // The active job reserves its worst-case output. On completion
                // only retained bytes count, otherwise two tiny signatures would
                // hold almost the entire 256 MiB allowance for thirty minutes.
                let retained = try retainedBytes(in: directoryURL(id), limit: value.reservedBytes)
                value.reservedBytes = retained
            }
            value.job.state = state
            value.job.result = result
            value.job.error = error
            if state.isTerminal, value.job.finishedAt == nil { value.job.finishedAt = clock() }
            entries[id] = value
            return value.job
        }
    }

    public func directory(for id: String, owner: String) throws -> URL {
        try lock.withLock {
            purgeLocked()
            _ = try entry(id: id, owner: owner)
            return directoryURL(id)
        }
    }

    /// Deliver retained signed bytes after a failed output save, never after a
    /// cancelled/unknown signature. The original terminal timestamp still wins.
    @discardableResult
    public func recordDelivery(id: String, owner: String, result: JSONValue) throws -> IntegrationJob {
        try lock.withLock {
            purgeLocked()
            var value = try entry(id: id, owner: owner)
            guard value.job.state == .completed ||
                    (value.job.state == .failed && value.job.error?.code == "OUTPUT_DELIVERY_FAILED") else {
                throw IntegrationError(code: "INVALID_REQUEST", message: "This job has no completed signature available for delivery.")
            }
            value.job.state = .completed
            value.job.result = result
            value.job.error = nil
            entries[id] = value
            return value.job
        }
    }

    /// Explicitly release a job, after its app task and output reservation ended.
    public func remove(id: String, owner: String) throws {
        try lock.withLock {
            _ = try entry(id: id, owner: owner)
            try FileManager.default.removeItem(at: directoryURL(id))
            entries[id] = nil
        }
    }

    /// For explicit MCP teardown only. Returns active IDs for the service to
    /// cancel; it must await those tasks before removing their files. CLI command
    /// exit must never call this, because later commands recover retained results.
    @discardableResult
    public func closeSession(owner: String) -> [String] {
        lock.withLock {
            var active: [String] = []
            for (id, value) in Array(entries) where value.owner == owner {
                if value.job.state.isTerminal {
                    if (try? FileManager.default.removeItem(at: directoryURL(id))) != nil { entries[id] = nil }
                } else { active.append(id) }
            }
            return active
        }
    }

    public func purgeExpired() { lock.withLock { purgeLocked() } }

    public var retainedCount: Int { lock.withLock { purgeLocked(); return entries.count } }
    public var reservedByteCount: Int { lock.withLock { purgeLocked(); return entries.values.reduce(0) { $0 + $1.reservedBytes } } }

    private func directoryURL(_ id: String) -> URL { root.appendingPathComponent("job-" + id, isDirectory: true) }

    private func retainedBytes(in directory: URL, limit: Int) throws -> Int {
        var total = 0
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw IntegrationError(code: "FILE_ACCESS", message: "Cannot account for retained integration files.")
        }
        for case let url as URL in files {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw IntegrationError(code: "FILE_ACCESS", message: "Cannot inspect retained integration files.")
            }
            if (info.st_mode & S_IFMT) == S_IFDIR { continue }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
                throw IntegrationError(code: "FILE_ACCESS", message: "Retained integration data must be regular files.")
            }
            guard info.st_size <= limit - total else {
                throw IntegrationError(code: "CAPACITY_EXCEEDED", message: "Retained output exceeds this job's reserved capacity.")
            }
            total += Int(info.st_size)
        }
        return total
    }

    private func entry(id: String, owner: String) throws -> Entry {
        guard let value = entries[id], value.owner == owner else {
            let wasExpired = expired.contains { $0.id == id && $0.owner == owner }
            throw IntegrationError(code: wasExpired ? "JOB_EXPIRED" : "JOB_UNKNOWN",
                                   message: wasExpired ? "This job's recovery window has expired." : "Job is unavailable in this integration session.")
        }
        return value
    }

    private func purgeLocked() {
        let now = clock()
        for (id, value) in Array(entries) {
            guard let finished = value.job.finishedAt, now.timeIntervalSince(finished) >= ttl else { continue }
            // Do not release accounted capacity while files remain on disk.
            do { try FileManager.default.removeItem(at: directoryURL(id)) }
            catch { continue }
            entries[id] = nil
            expired.append(Expired(id: id, owner: value.owner))
        }
        if expired.count > maxJobs * 2 { expired.removeFirst(expired.count - maxJobs * 2) }
    }
}
